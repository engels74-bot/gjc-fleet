//! gjc-relay — loopback transform relay between clawhip and the Discord REST API.
//!
//! Behavior (see docs/35-gjc-relay.md in the gjc-fleet repo):
//!   * Transparent reverse proxy to https://discord.com (HOST ONLY): the incoming
//!     request path is forwarded verbatim (it already carries /api/v10/...).
//!   * GET /healthz is answered locally (liveness), never proxied.
//!   * POST /channels/{id}/messages applies three-way split-passthrough on `content`:
//!       1. no `GJCEMBED1 ` prefix   -> forward the body byte-for-byte
//!       2. valid GJCEMBED1 envelope -> build {"embeds":[...]} from design-system.json
//!       3. prefix present but head malformed -> CLEAN plain-text degrade (no artifacts)
//!   * Discord's exact status code and JSON body are mirrored for every response,
//!     including 429 (clawhip's backoff needs the real 429 + retry_after body).
//!   * SECURITY: the Authorization header and request/response bodies are NEVER logged.

mod config;
mod envelope;
mod http;
mod log;
mod render;

// v2 work-item core (Phase A-1b/A-1c). discord/policy/registry/store/queue/flush
// are now wired into the HTTP path below (Round 2); the managed absorb branch in
// http.rs only ever activates for a channel listed in RELAY_WORKITEM_CHANNELS.
mod discord;
mod flush;
mod policy;
mod queue;
mod registry;
mod store;

use std::panic::AssertUnwindSafe;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tiny_http::Server;

use crate::config::Config;
use crate::discord::UreqDiscord;
use crate::flush::{ChannelBucket, Clock, FlushCfg, SystemClock};
use crate::http::{handle, ManagedCtx, TokenCache};
use crate::log::log_meta;
use crate::queue::QueueEntry;
use crate::store::Persister;

fn main() {
    let cfg = Arc::new(Config::from_env());

    let agent = Arc::new(
        ureq::AgentBuilder::new()
            .redirects(0)
            .timeout_connect(std::time::Duration::from_secs(10))
            .timeout(std::time::Duration::from_secs(30))
            .build(),
    );

    // --- v2 work-item core: load + reconcile the durable snapshot against the
    // queue directory before serving any traffic. Inert when workitem_channels
    // is empty (state.items/dedup simply stay empty forever).
    let mut initial_state = store::load(&cfg.state_dir);
    for entry in queue::scan(&cfg.state_dir) {
        if let QueueEntry::Committed {
            op_path,
            committed_path,
            committed,
            op,
        } = entry
        {
            flush::apply_delivery_result(&mut initial_state, &op, &committed);
            let _ = queue::cleanup_recovered(&op_path, &committed_path);
        }
    }
    let state = Arc::new(Mutex::new(initial_state));
    let bucket = Arc::new(ChannelBucket::new(cfg.managed_rate));
    let token_cache = TokenCache::new();

    let server = Arc::new(
        Server::http(&cfg.bind)
            .unwrap_or_else(|e| panic!("gjc-relay: cannot bind {}: {e}", cfg.bind)),
    );
    log_meta(
        "startup",
        &format!("listening on {} -> {}", cfg.bind, cfg.upstream),
    );

    // --- single supervised flush thread (the only writer of Discord deliveries).
    {
        let state = state.clone();
        let bucket = bucket.clone();
        let token_cache = token_cache.clone();
        let cfg = cfg.clone();
        let flush_agent = ureq::AgentBuilder::new()
            .redirects(0)
            .timeout_connect(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build();
        std::thread::spawn(move || {
            let api = UreqDiscord::new(flush_agent, (*cfg.upstream).clone());
            let clock = SystemClock;
            let flush_cfg = FlushCfg {
                debounce_secs: cfg.debounce_secs,
                debounce_max_secs: cfg.debounce_max_secs,
                delivery_max_age_secs: cfg.delivery_max_age_secs,
                state_dir: cfg.state_dir.clone(),
                fault_after_post: (*cfg.fault_after_post).clone(),
            };
            loop {
                let token = token_cache.get();
                let result = std::panic::catch_unwind(AssertUnwindSafe(|| {
                    flush::flush_tick(&state, &api, &clock, &bucket, token, &flush_cfg)
                }));
                match result {
                    // Consume every delivery event so the plan's mandated
                    // greppable labels ([post][edit][thread][recover]
                    // [recreate][dedup-drop][drop][dead-letter][flush-panic])
                    // actually reach the journal — a silently-dropped Vec here
                    // was exactly the deploy-observability gap Round 5 closes.
                    Ok(events) => flush::log_events(&events),
                    Err(_) => {
                        log_meta(
                            "flush-panic",
                            "flush tick panicked; recovering and restarting the loop",
                        );
                    }
                }
                flush::touch_alive(&flush_cfg.state_dir);
                std::thread::sleep(Duration::from_millis(500));
            }
        });
    }

    // --- best-effort dirty-flag persister (≤1 write/sec). SIGTERM-triggered
    // flush_now() is deferred: no signal-handling crate is a dependency of
    // relay/ today (see report), so data loss is bounded by this loop's own
    // period instead of an immediate shutdown flush.
    {
        let state = state.clone();
        let cfg = cfg.clone();
        std::thread::spawn(move || {
            let mut persister = Persister::new();
            let mut prune_counter: u32 = 0;
            loop {
                let snapshot = {
                    let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                    // Prune stale items/dedup roughly once an hour (every 3600th
                    // second tick) rather than on every save.
                    prune_counter = prune_counter.wrapping_add(1);
                    if prune_counter.is_multiple_of(3600) {
                        let now = store::now_ts();
                        st.prune(now);
                        st.prune_dedup(now);
                    }
                    st.clone()
                };
                persister.mark_dirty();
                let _ = persister.maybe_flush(&cfg.state_dir, &snapshot);
                std::thread::sleep(Duration::from_secs(1));
            }
        });
    }

    let mut handles = Vec::new();
    for _ in 0..8 {
        let server = server.clone();
        let ds = cfg.ds.clone();
        let agent = agent.clone();
        let upstream = cfg.upstream.clone();
        let force_429 = cfg.force_429.clone();
        let managed = ManagedCtx {
            cfg: cfg.clone(),
            state: state.clone(),
            bucket: bucket.clone(),
            token_cache: token_cache.clone(),
        };
        handles.push(std::thread::spawn(move || loop {
            match server.recv() {
                Ok(req) => handle(req, &ds, &agent, &upstream, &force_429, &managed),
                Err(_) => break,
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
}
