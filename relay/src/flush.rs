//! The single supervised deliverer for the managed work-item path.
//!
//! `flush_tick` is the pure(-ish) unit of work: scan the durable queue, deliver
//! what's ready, fold results back into the registry. It is called on a loop by
//! exactly one OS thread (main.rs) — HTTP workers only ever enqueue, never call
//! [`crate::discord::DiscordApi`] directly (the single-deliverer invariant).
//!
//! The state [`Mutex`] is never held across a `DiscordApi` call: op data is
//! extracted from the durable queue file (which already carries everything a
//! delivery needs — target ids, the rendered embed), the I/O happens with no
//! lock held, and the lock is only briefly re-taken afterward to fold the
//! result back into the registry.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

use crate::config::ManagedRate;
use crate::discord::{DiscordApi, DiscordErr};
use crate::log::log_meta;
use crate::queue::{self, Committed, Op, OpClass, QueueEntry};
use crate::registry::State;

/// Injectable time source so flush logic (debounce, backoff, max-age) is
/// deterministically unit-testable.
pub(crate) trait Clock: Send + Sync {
    fn now_ms(&self) -> i64;
}

pub(crate) struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }
}

/// Debounce/pacing configuration for one flush tick.
pub(crate) struct FlushCfg {
    pub(crate) debounce_secs: u64,
    pub(crate) debounce_max_secs: u64,
    pub(crate) delivery_max_age_secs: u64,
    pub(crate) state_dir: String,
    /// Diagnostic (default empty = inert): channel ids for which
    /// `deliver_new_message` hard-aborts the process right after a
    /// successful Discord POST but before `.committed` is written. See
    /// `Config::fault_after_post`'s doc comment for the full rationale.
    /// UNSET/EMPTY ⇒ this check never fires — byte-identical to today.
    pub(crate) fault_after_post: Vec<String>,
}

/// What happened during a tick — returned so tests can assert on behavior
/// without poking at the filesystem, and so the caller (main.rs, via
/// [`log_events`]) emits the plan's mandated greppable delivery labels
/// (`[post][edit][thread][dedup-drop][drop][dead-letter][recreate][recover]
/// [flush-panic]`).
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum FlushEvent {
    /// A fresh delivery: NewMessage -> `[post]`, EditSummary -> `[edit]`,
    /// ThreadCreate/ThreadPost -> `[thread]`.
    Delivered {
        opclass: OpClass,
        item_key: String,
        id: String,
    },
    /// Read-back reconciliation adopted an already-POSTed message instead of
    /// re-posting (A2a step 3a) -> `[recover]`. This is the event that proves
    /// zero-duplicate delivery across the C1 crash-window drill.
    Recovered {
        opclass: OpClass,
        item_key: String,
        id: String,
    },
    /// A 404 on an anchored edit/thread forced a fresh re-post -> `[recreate]`.
    Recreated {
        opclass: OpClass,
        item_key: String,
        new_id: String,
    },
    RateLimited {
        retry_after_ms: i64,
    },
    Backoff {
        attempts: u32,
    },
    /// Already journaled with the `[dead-letter]` label by `queue::bury` at
    /// the point of occurrence — carried here only so tests can assert on it.
    Buried {
        reason: String,
    },
    ThreadDisabled {
        item_key: String,
    },
    Parked,
}

/// Emit exactly one `log_meta` line per delivery-outcome event, using the
/// plan's canonical greppable labels. Metadata only — labels, work-item keys,
/// and message/thread ids. NEVER the token, NEVER request/response bodies,
/// NEVER embed content (mirrors v1's `[transform]` logging discipline).
///
/// `Buried`/`ThreadDisabled`/`RateLimited`/`Backoff`/`Parked` are NOT logged
/// here: burial is already journaled with `[dead-letter]` at the point of
/// occurrence (`queue::bury`), and the others are internal retry/pacing
/// bookkeeping with no label in the plan's mandated set.
pub(crate) fn log_events(events: &[FlushEvent]) {
    for event in events {
        if let Some((label, msg)) = label_and_message(event) {
            log_meta(label, &msg);
        }
    }
}

/// The canonical `(label, message)` for an event, or `None` for variants that
/// are either logged elsewhere (`Buried` -> `[dead-letter]` at the point of
/// occurrence in `queue::bury`) or have no label in the plan's mandated set
/// (`ThreadDisabled`/`RateLimited`/`Backoff`/`Parked`). Split out from
/// [`log_events`] so the label mapping is directly unit-testable without
/// capturing stdout.
fn label_and_message(event: &FlushEvent) -> Option<(&'static str, String)> {
    match event {
        FlushEvent::Delivered {
            opclass,
            item_key,
            id,
        } => {
            let label = match opclass {
                OpClass::NewMessage => "post",
                OpClass::EditSummary => "edit",
                OpClass::ThreadCreate | OpClass::ThreadPost => "thread",
            };
            Some((label, format!("{item_key} -> {id}")))
        }
        FlushEvent::Recovered { item_key, id, .. } => Some((
            "recover",
            format!("{item_key} -> {id} (read-back match, no re-post)"),
        )),
        FlushEvent::Recreated {
            item_key, new_id, ..
        } => Some(("recreate", format!("{item_key} -> {new_id}"))),
        FlushEvent::RateLimited { .. }
        | FlushEvent::Backoff { .. }
        | FlushEvent::Buried { .. }
        | FlushEvent::ThreadDisabled { .. }
        | FlushEvent::Parked => None,
    }
}

/// Per-channel shared token accounting spanning BOTH the managed DiscordApi
/// deliveries (this module) and the unmanaged verbatim-forward path
/// (http.rs). Managed traffic may only draw up to `rate.managed_tokens` per
/// window; the unmanaged/critical path draws with priority — it always
/// succeeds locally (never blocked behind queued managed edits) and simply
/// records its own usage for visibility.
pub(crate) struct ChannelBucket {
    inner: Mutex<HashMap<String, BucketState>>,
    rate: ManagedRate,
}

struct BucketState {
    window_start_ms: i64,
    managed_used: u32,
}

impl ChannelBucket {
    pub(crate) fn new(rate: ManagedRate) -> ChannelBucket {
        ChannelBucket {
            inner: Mutex::new(HashMap::new()),
            rate,
        }
    }

    fn window_ms(&self) -> i64 {
        (self.rate.window_secs as i64) * 1000
    }

    /// Try to take one managed-class token for `cid`. False = no token
    /// available this tick (caller must retry on a later tick).
    pub(crate) fn try_take_managed(&self, cid: &str, now_ms: i64) -> bool {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let window_ms = self.window_ms();
        let st = map.entry(cid.to_string()).or_insert(BucketState {
            window_start_ms: now_ms,
            managed_used: 0,
        });
        if now_ms - st.window_start_ms >= window_ms {
            st.window_start_ms = now_ms;
            st.managed_used = 0;
        }
        if st.managed_used < self.rate.managed_tokens {
            st.managed_used += 1;
            true
        } else {
            false
        }
    }

    /// Critical/unmanaged draw: priority path, always succeeds locally
    /// (accounting only — the real Discord rate limit is still mirrored
    /// faithfully by http.rs's verbatim proxy regardless of this bucket).
    pub(crate) fn take_critical(&self, cid: &str, now_ms: i64) {
        let mut map = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let window_ms = self.window_ms();
        let st = map.entry(cid.to_string()).or_insert(BucketState {
            window_start_ms: now_ms,
            managed_used: 0,
        });
        if now_ms - st.window_start_ms >= window_ms {
            st.window_start_ms = now_ms;
            st.managed_used = 0;
        }
        // Accounting only; critical traffic is never gated by this bucket.
    }
}

/// Exponential backoff for generic (5xx/transport) failures: 1s, 2s, 4s, ...
/// capped at 60s.
fn exp_backoff_ms(attempts: u32) -> i64 {
    let capped_exp = attempts.saturating_sub(1).min(6);
    let secs = (1u64 << capped_exp).min(60);
    (secs as i64) * 1000
}

/// Touch `<state_dir>/flush.alive`'s mtime so an external health-watch can
/// detect a hung/dead flush loop. Best-effort.
pub(crate) fn touch_alive(state_dir: &str) {
    let path = std::path::Path::new(state_dir).join("flush.alive");
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(&path, b"");
}

/// Fold a delivery result back into the registry. `result_id` is the id the
/// op produced: a message id for NewMessage/EditSummary/ThreadPost, or the
/// newly created thread id for ThreadCreate.
pub(crate) fn apply_delivery_result(state: &mut State, op: &Op, committed: &Committed) {
    match op.opclass {
        OpClass::NewMessage => {
            if let Some(item) = state.items.get_mut(&op.item_key) {
                item.summary_message_id = Some(committed.message_id.clone());
            }
        }
        OpClass::ThreadCreate => {
            if let Some(item) = state.items.get_mut(&op.item_key) {
                item.thread_id = Some(committed.message_id.clone());
            }
        }
        OpClass::EditSummary | OpClass::ThreadPost => {
            // ids don't change registry state; nothing to fold beyond dedup below.
        }
    }
    // Restart-recovery safety net: ensure the dedup fingerprint made it into
    // the snapshot even if the in-memory update that originally set it (at
    // http.rs absorb time) never got persisted before a crash. `state.dedup`
    // values are SECONDS (registry::DEDUP_TTL_SECS, store::now_ts()) while
    // `op.created_at` is MILLISECONDS (see queue::Op's doc comment) — convert.
    state
        .dedup
        .entry(op.fingerprint.clone())
        .or_insert(op.created_at / 1000);
}

/// One flush tick: scan the queue, fold back any already-committed leftovers
/// from a previous crash, then attempt delivery of pending ops (debounced
/// EditSummary groups + FIFO everything else), respecting the shared bucket,
/// retry backoff, and max-age burial.
pub(crate) fn flush_tick(
    state: &Mutex<State>,
    api: &dyn DiscordApi,
    clock: &dyn Clock,
    bucket: &ChannelBucket,
    token: Option<String>,
    cfg: &FlushCfg,
) -> Vec<FlushEvent> {
    let mut events = Vec::new();
    let Some(token) = token else {
        return vec![FlushEvent::Parked];
    };

    let entries = queue::scan(&cfg.state_dir);
    let mut edit_groups: HashMap<String, Vec<(std::path::PathBuf, Op)>> = HashMap::new();
    let mut fifo: Vec<(std::path::PathBuf, Op)> = Vec::new();

    for entry in entries {
        match entry {
            QueueEntry::Committed {
                op_path,
                committed_path,
                committed,
                op,
            } => {
                {
                    let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                    apply_delivery_result(&mut st, &op, &committed);
                }
                let _ = queue::cleanup_recovered(&op_path, &committed_path);
            }
            QueueEntry::Pending { op_path, op } => {
                if op.opclass == OpClass::EditSummary {
                    edit_groups
                        .entry(op.item_key.clone())
                        .or_default()
                        .push((op_path, op));
                } else {
                    fifo.push((op_path, op));
                }
            }
        }
    }

    let now = clock.now_ms();
    let max_age_ms = (cfg.delivery_max_age_secs as i64) * 1000;
    let debounce_ms = (cfg.debounce_secs as i64) * 1000;
    let debounce_max_ms = (cfg.debounce_max_secs as i64) * 1000;

    // --- debounced EditSummary groups ---
    for (_item_key, mut group) in edit_groups {
        group.sort_by_key(|(_, op)| op.created_at);
        let first_ts = group.first().unwrap().1.created_at;
        let last_ts = group.last().unwrap().1.created_at;

        if now - first_ts >= max_age_ms {
            for (path, _) in &group {
                if let Err(e) = queue::bury(&cfg.state_dir, path, "delivery_max_age_secs exceeded")
                {
                    log_meta("flush-error", &format!("bury failed: {e}"));
                }
            }
            events.push(FlushEvent::Buried {
                reason: "delivery_max_age_secs exceeded".to_string(),
            });
            continue;
        }

        let ready = now - last_ts >= debounce_ms || now - first_ts >= debounce_max_ms;
        if !ready {
            continue;
        }

        let (winner_path, winner) = group.last().unwrap().clone();
        if let Some(next) = winner.next_attempt_at {
            if now < next {
                continue;
            }
        }
        let Some(mid) = winner.target_message_id.clone() else {
            // Should never happen (EditSummary always carries a target); bury
            // defensively rather than looping forever.
            for (path, _) in &group {
                let _ = queue::bury(
                    &cfg.state_dir,
                    path,
                    "EditSummary missing target_message_id",
                );
            }
            continue;
        };
        if !bucket.try_take_managed(&winner.channel_id, now) {
            continue;
        }

        match api.edit_message(&winner.channel_id, &mid, &token, &winner.embed) {
            Ok(()) => {
                let committed = Committed {
                    message_id: mid.clone(),
                    fingerprint: winner.fingerprint.clone(),
                    delivered_at: now,
                };
                for (path, op) in &group {
                    if let Ok(cpath) = queue::mark_committed(path, &committed) {
                        let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                        apply_delivery_result(&mut st, op, &committed);
                        drop(st);
                        let _ = queue::cleanup_committed(&cpath);
                    }
                }
                events.push(FlushEvent::Delivered {
                    opclass: OpClass::EditSummary,
                    item_key: winner.item_key.clone(),
                    id: mid,
                });
            }
            Err(DiscordErr::Status(404)) => {
                // Summary deleted: re-POST fresh, fold the new id back for the
                // whole group.
                match api.post_message(&winner.channel_id, &token, &winner.embed) {
                    Ok(new_id) => {
                        {
                            let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                            if let Some(item) = st.items.get_mut(&winner.item_key) {
                                item.summary_message_id = Some(new_id.clone());
                            }
                        }
                        let committed = Committed {
                            message_id: new_id.clone(),
                            fingerprint: winner.fingerprint.clone(),
                            delivered_at: now,
                        };
                        for (path, _) in &group {
                            if let Ok(cpath) = queue::mark_committed(path, &committed) {
                                let _ = queue::cleanup_committed(&cpath);
                            }
                        }
                        // Logged centrally via log_events -> `[recreate]`
                        // (see the FlushEvent::Recreated arm) so the label is
                        // emitted exactly once regardless of caller.
                        events.push(FlushEvent::Recreated {
                            opclass: OpClass::EditSummary,
                            item_key: winner.item_key.clone(),
                            new_id,
                        });
                    }
                    Err(_) => {
                        bump_retry(
                            &cfg.state_dir,
                            &winner_path,
                            winner.clone(),
                            now,
                            DiscordErr::Status(404),
                            &mut events,
                        );
                    }
                }
            }
            Err(DiscordErr::Status(403)) => {
                for (path, _) in &group {
                    let _ = queue::bury(&cfg.state_dir, path, "403 forbidden");
                }
                events.push(FlushEvent::Buried {
                    reason: "403 forbidden".to_string(),
                });
            }
            Err(e) => {
                bump_retry(
                    &cfg.state_dir,
                    &winner_path,
                    winner.clone(),
                    now,
                    e,
                    &mut events,
                );
            }
        }
    }

    // --- FIFO: NewMessage / ThreadCreate / ThreadPost ---
    for (path, op) in fifo {
        if now - op.created_at >= max_age_ms {
            let _ = queue::bury(&cfg.state_dir, &path, "delivery_max_age_secs exceeded");
            events.push(FlushEvent::Buried {
                reason: "delivery_max_age_secs exceeded".to_string(),
            });
            continue;
        }
        if let Some(next) = op.next_attempt_at {
            if now < next {
                continue;
            }
        }
        if !bucket.try_take_managed(&op.channel_id, now) {
            continue;
        }

        match op.opclass {
            OpClass::NewMessage => {
                deliver_new_message(&path, &op, api, &token, state, cfg, now, &mut events)
            }
            OpClass::ThreadCreate => {
                deliver_thread_create(&path, &op, api, &token, state, cfg, now, &mut events)
            }
            OpClass::ThreadPost => {
                deliver_thread_post(&path, &op, api, &token, state, cfg, now, &mut events)
            }
            OpClass::EditSummary => unreachable!("EditSummary ops are grouped above"),
        }
    }

    events
}

fn bump_retry(
    state_dir: &str,
    path: &std::path::Path,
    mut op: Op,
    now: i64,
    err: DiscordErr,
    events: &mut Vec<FlushEvent>,
) {
    op.attempts += 1;
    match err {
        DiscordErr::RateLimited { retry_after } => {
            let delay_ms = (retry_after * 1000.0) as i64;
            op.next_attempt_at = Some(now + delay_ms);
            events.push(FlushEvent::RateLimited {
                retry_after_ms: delay_ms,
            });
        }
        _ => {
            let delay_ms = exp_backoff_ms(op.attempts);
            op.next_attempt_at = Some(now + delay_ms);
            events.push(FlushEvent::Backoff {
                attempts: op.attempts,
            });
        }
    }
    if let Err(e) = queue::record_attempt(path, &op) {
        log_meta("flush-error", &format!("record_attempt failed: {e}"));
    }
    let _ = state_dir; // reserved for future per-dir retry telemetry
}

#[allow(clippy::too_many_arguments)]
fn deliver_new_message(
    path: &std::path::Path,
    op: &Op,
    api: &dyn DiscordApi,
    token: &str,
    state: &Mutex<State>,
    cfg: &FlushCfg,
    now: i64,
    events: &mut Vec<FlushEvent>,
) {
    // Read-back reconciliation (A2a step 3a): before re-POSTing, check whether
    // an earlier attempt already landed (crash between POST and .committed).
    // Match on content, NOT exact Value equality (Round 7: Discord normalizes/
    // enriches an echoed embed — adds "type":"rich", proxy_url, video, may
    // reorder keys — so `returned == sent` NEVER holds in production).
    if let Ok(msgs) = api.list_recent_messages(&op.channel_id, token, 50) {
        for m in &msgs {
            let matched = m
                .get("embeds")
                .and_then(|e| e.get(0))
                .map(|returned| embed_content_matches(returned, &op.embed))
                .unwrap_or(false);
            if matched {
                if let Some(id) = m.get("id").and_then(|v| v.as_str()) {
                    finish_delivery(
                        path,
                        op,
                        id.to_string(),
                        state,
                        now,
                        OpClass::NewMessage,
                        true,
                        events,
                    );
                    return;
                }
            }
        }
    }

    match api.post_message(&op.channel_id, token, &op.embed) {
        Ok(id) => {
            // Diagnostic (default empty = inert): DEPLOY-LAB C1 crash-window
            // drill. When RELAY_FAULT_AFTER_POST lists this channel, hard-abort
            // right here — the POST already succeeded (Discord has the
            // message) but the .committed marker has NOT been written/fsynced
            // yet. This is exactly the post-POST/pre-commit crash window the
            // read-back reconciliation (A2a step 3a) exists to recover from:
            // on restart, this same op is still "pending", the flush loop
            // re-derives it, and the read-back GET finds the already-posted
            // message and adopts its id instead of re-posting. Gated to
            // new-message-class only, and to zero blast radius when unset —
            // every other channel's delivery is completely unaffected.
            if cfg.fault_after_post.iter().any(|c| c == &op.channel_id) {
                log_meta(
                    "fault-inject",
                    "aborting after POST (RELAY_FAULT_AFTER_POST diagnostic)",
                );
                std::process::abort();
            }
            finish_delivery(path, op, id, state, now, OpClass::NewMessage, false, events)
        }
        Err(DiscordErr::Status(403)) => {
            let _ = queue::bury(&cfg.state_dir, path, "403 forbidden");
            events.push(FlushEvent::Buried {
                reason: "403 forbidden".to_string(),
            });
        }
        Err(e) => bump_retry(&cfg.state_dir, path, op.clone(), now, e, events),
    }
}

#[allow(clippy::too_many_arguments)]
fn deliver_thread_create(
    path: &std::path::Path,
    op: &Op,
    api: &dyn DiscordApi,
    token: &str,
    state: &Mutex<State>,
    cfg: &FlushCfg,
    now: i64,
    events: &mut Vec<FlushEvent>,
) {
    let Some(anchor) = op.target_message_id.clone() else {
        let _ = queue::bury(
            &cfg.state_dir,
            path,
            "ThreadCreate missing target_message_id",
        );
        events.push(FlushEvent::Buried {
            reason: "ThreadCreate missing target_message_id".to_string(),
        });
        return;
    };
    // Reuse a thread created by an earlier attempt instead of creating a duplicate.
    // If a prior tick's `create_thread_from_message` succeeded but the in-thread
    // `post_to_thread` failed (or the process crashed in between), the op now carries
    // the `target_thread_id`; skip creation and go straight to the post. Without this
    // the whole ThreadCreate op was retried from scratch, orphaning the first thread
    // and creating a second empty one (violates the no-duplicate guarantee).
    let thread_id = match op.target_thread_id.clone() {
        Some(existing) => existing,
        None => {
            match api.create_thread_from_message(
                &op.channel_id,
                &anchor,
                token,
                &thread_name(op),
                1440,
            ) {
                Ok(tid) => {
                    // Persist the created thread onto the op BEFORE the in-thread post,
                    // so a post failure OR a crash mid-post reuses this thread on the
                    // next tick rather than creating a duplicate.
                    let mut with_thread = op.clone();
                    with_thread.target_thread_id = Some(tid.clone());
                    if let Err(e) = queue::record_attempt(path, &with_thread) {
                        log_meta(
                            "flush-error",
                            &format!("record_attempt(thread_id) failed: {e}"),
                        );
                    }
                    tid
                }
                Err(DiscordErr::Status(404)) => {
                    // Source summary message is gone; there is nothing sane to branch
                    // a thread from. Disable threading for this item and bury.
                    {
                        let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                        if let Some(item) = st.items.get_mut(&op.item_key) {
                            item.thread_disabled = true;
                        }
                    }
                    let _ =
                        queue::bury(&cfg.state_dir, path, "source summary message missing (404)");
                    events.push(FlushEvent::ThreadDisabled {
                        item_key: op.item_key.clone(),
                    });
                    return;
                }
                Err(DiscordErr::Status(403)) => {
                    {
                        let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                        if let Some(item) = st.items.get_mut(&op.item_key) {
                            item.thread_disabled = true;
                        }
                    }
                    let _ = queue::bury(&cfg.state_dir, path, "403 forbidden");
                    events.push(FlushEvent::ThreadDisabled {
                        item_key: op.item_key.clone(),
                    });
                    return;
                }
                Err(e) => {
                    bump_retry(&cfg.state_dir, path, op.clone(), now, e, events);
                    return;
                }
            }
        }
    };
    match api.post_to_thread(&thread_id, token, &op.embed) {
        Ok(_msg_id) => finish_delivery(
            path,
            op,
            thread_id,
            state,
            now,
            OpClass::ThreadCreate,
            false,
            events,
        ),
        // Retry the post against the existing thread, never a fresh create.
        Err(e) => {
            let mut retry = op.clone();
            retry.target_thread_id = Some(thread_id);
            bump_retry(&cfg.state_dir, path, retry, now, e, events);
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn deliver_thread_post(
    path: &std::path::Path,
    op: &Op,
    api: &dyn DiscordApi,
    token: &str,
    state: &Mutex<State>,
    cfg: &FlushCfg,
    now: i64,
    events: &mut Vec<FlushEvent>,
) {
    let Some(thread_id) = op.target_thread_id.clone() else {
        // No thread yet: degrade to a ThreadCreate-shaped delivery.
        deliver_thread_create(path, op, api, token, state, cfg, now, events);
        return;
    };
    match api.post_to_thread(&thread_id, token, &op.embed) {
        Ok(msg_id) => finish_delivery(
            path,
            op,
            msg_id,
            state,
            now,
            OpClass::ThreadPost,
            false,
            events,
        ),
        Err(DiscordErr::Status(404)) => {
            // Thread itself was deleted: clear it and recreate from the anchor.
            {
                let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(item) = st.items.get_mut(&op.item_key) {
                    item.thread_id = None;
                }
            }
            deliver_thread_create(path, op, api, token, state, cfg, now, events);
        }
        Err(DiscordErr::Status(403)) => {
            {
                let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(item) = st.items.get_mut(&op.item_key) {
                    item.thread_disabled = true;
                }
            }
            let _ = queue::bury(&cfg.state_dir, path, "403 forbidden");
            events.push(FlushEvent::ThreadDisabled {
                item_key: op.item_key.clone(),
            });
        }
        Err(e) => bump_retry(&cfg.state_dir, path, op.clone(), now, e, events),
    }
}

fn thread_name(op: &Op) -> String {
    let mut n = op.kind.clone();
    n.truncate(90);
    n
}

/// True iff every stable, caller-controlled TEXT field present in `sent` is
/// equal in `returned`. Used by [`deliver_new_message`]'s read-back
/// reconciliation to recognize a message this relay already POSTed, without
/// requiring exact `serde_json::Value` equality — Discord normalizes/enriches
/// an embed on echo (adds `"type":"rich"`, `proxy_url`, `video`, may reorder
/// keys, etc.), so `returned == sent` never holds in production; it alters
/// structure, not the text content we sent, so comparing just that content is
/// distinctive enough for the crash-window use case (the op was POSTed
/// seconds ago and we scan only the last 50 channel messages).
///
/// Compares: `title`, `description`, `author.name`, `footer.text`, `color`
/// (an extra-safety check — Discord preserves the integer color verbatim),
/// and each `fields[i].{name,value}` pair in order. A field absent from both
/// sides counts as a match (missing == missing); deliberately does NOT
/// compare any structural key Discord may add.
fn embed_content_matches(returned: &Value, sent: &Value) -> bool {
    str_field(returned, "title") == str_field(sent, "title")
        && str_field(returned, "description") == str_field(sent, "description")
        && nested_str_field(returned, "author", "name") == nested_str_field(sent, "author", "name")
        && nested_str_field(returned, "footer", "text") == nested_str_field(sent, "footer", "text")
        && returned.get("color").and_then(|c| c.as_i64())
            == sent.get("color").and_then(|c| c.as_i64())
        && embed_fields(returned) == embed_fields(sent)
}

fn str_field<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(|f| f.as_str())
}

fn nested_str_field<'a>(v: &'a Value, obj_key: &str, field_key: &str) -> Option<&'a str> {
    v.get(obj_key)
        .and_then(|o| o.get(field_key))
        .and_then(|f| f.as_str())
}

fn embed_fields(v: &Value) -> Vec<(&str, &str)> {
    v.get("fields")
        .and_then(|f| f.as_array())
        .map(|arr| {
            arr.iter()
                .map(|f| {
                    (
                        f.get("name").and_then(|n| n.as_str()).unwrap_or(""),
                        f.get("value").and_then(|n| n.as_str()).unwrap_or(""),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Record a successful delivery. `recovered` distinguishes a read-back
/// reconciliation adopting an already-POSTed message (-> `[recover]`) from a
/// fresh delivery (-> `[post]`/`[edit]`/`[thread]` depending on `opclass`).
#[allow(clippy::too_many_arguments)]
fn finish_delivery(
    path: &std::path::Path,
    op: &Op,
    id: String,
    state: &Mutex<State>,
    now: i64,
    opclass: OpClass,
    recovered: bool,
    events: &mut Vec<FlushEvent>,
) {
    let committed = Committed {
        message_id: id.clone(),
        fingerprint: op.fingerprint.clone(),
        delivered_at: now,
    };
    if let Ok(cpath) = queue::mark_committed(path, &committed) {
        {
            let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
            apply_delivery_result(&mut st, op, &committed);
        }
        let _ = queue::cleanup_committed(&cpath);
    }
    let item_key = op.item_key.clone();
    events.push(if recovered {
        FlushEvent::Recovered {
            opclass,
            item_key,
            id,
        }
    } else {
        FlushEvent::Delivered {
            opclass,
            item_key,
            id,
        }
    });
}

/// Run `tick` `n` times, recovering from any panic via `catch_unwind` so a bug
/// in one tick never silently kills the loop. Returns the number of panics
/// recovered. This is the pure, directly-unit-testable core of the
/// "supervised restart" property; main.rs's real infinite loop wraps each
/// iteration with the same catch_unwind pattern inline (see its doc comment)
/// rather than calling this helper, so it has no non-test caller.
#[allow(dead_code)]
pub(crate) fn supervised_run_n<F: FnMut()>(n: usize, mut tick: F) -> usize {
    static PANICS: AtomicU32 = AtomicU32::new(0);
    let mut panics = 0usize;
    for _ in 0..n {
        let tick_ref = &mut tick;
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(tick_ref));
        if result.is_err() {
            panics += 1;
            PANICS.fetch_add(1, Ordering::Relaxed);
            log_meta(
                "flush-panic",
                "flush tick panicked; recovering and restarting the loop",
            );
        }
    }
    panics
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::discord::MockDiscord;
    use crate::registry::{item_key, ItemType, WorkItem};
    use serde_json::json;
    use std::sync::atomic::AtomicI64;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TestClock(AtomicI64);
    impl TestClock {
        fn new(t: i64) -> TestClock {
            TestClock(AtomicI64::new(t))
        }
        fn advance(&self, ms: i64) {
            self.0.fetch_add(ms, Ordering::SeqCst);
        }
    }
    impl Clock for TestClock {
        fn now_ms(&self) -> i64 {
            self.0.load(Ordering::SeqCst)
        }
    }

    fn temp_dir(tag: &str) -> String {
        let mut p = std::env::temp_dir();
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        p.push(format!(
            "gjc-relay-flush-test-{tag}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p.to_string_lossy().into_owned()
    }
    fn cleanup(dir: &str) {
        let _ = std::fs::remove_dir_all(dir);
    }

    fn cfg(dir: &str) -> FlushCfg {
        FlushCfg {
            debounce_secs: 5,
            debounce_max_secs: 20,
            delivery_max_age_secs: 600,
            state_dir: dir.to_string(),
            fault_after_post: Vec::new(),
        }
    }

    fn edit_op(cid: &str, key: &str, mid: &str, created_at: i64, embed: serde_json::Value) -> Op {
        Op {
            channel_id: cid.to_string(),
            item_key: key.to_string(),
            kind: "github.ci-passed".to_string(),
            embed,
            fingerprint: format!("fp-{created_at}"),
            opclass: OpClass::EditSummary,
            target_message_id: Some(mid.to_string()),
            target_thread_id: None,
            created_at,
            attempts: 0,
            next_attempt_at: None,
        }
    }

    fn new_msg_op(cid: &str, key: &str, created_at: i64) -> Op {
        Op {
            channel_id: cid.to_string(),
            item_key: key.to_string(),
            kind: "github.issue-opened".to_string(),
            embed: json!({ "title": "hi" }),
            fingerprint: "iss|o/r|1|opened".to_string(),
            opclass: OpClass::NewMessage,
            target_message_id: None,
            target_thread_id: None,
            created_at,
            attempts: 0,
            next_attempt_at: None,
        }
    }

    fn thread_create_op(cid: &str, key: &str, anchor: &str, created_at: i64) -> Op {
        Op {
            channel_id: cid.to_string(),
            item_key: key.to_string(),
            kind: "workitem.dispatched".to_string(),
            embed: json!({ "title": "thread body" }),
            fingerprint: format!("thr-{created_at}"),
            opclass: OpClass::ThreadCreate,
            target_message_id: Some(anchor.to_string()),
            target_thread_id: None,
            created_at,
            attempts: 0,
            next_attempt_at: None,
        }
    }

    fn bucket() -> ChannelBucket {
        ChannelBucket::new(ManagedRate {
            managed_tokens: 3,
            window_secs: 5,
        })
    }

    #[test]
    fn debounce_coalesces_n_edits_into_one_patch() {
        let dir = temp_dir("debounce");
        let key = item_key("o/r", "1");
        {
            let mut st = State::new();
            st.learn(WorkItem::new(
                key.clone(),
                "chan".to_string(),
                ItemType::Pr,
                0,
            ));
            if let Some(it) = st.items.get_mut(&key) {
                it.summary_message_id = Some("mid1".to_string());
            }
            crate::store::save(&dir, &st).unwrap();
        }
        let state = Mutex::new(crate::store::load(&dir));

        let clock = TestClock::new(1_000_000);
        // 3 edit events land within the debounce window.
        queue::enqueue(
            &dir,
            &edit_op("chan", &key, "mid1", clock.now_ms(), json!({"v":1})),
        )
        .unwrap();
        clock.advance(500);
        queue::enqueue(
            &dir,
            &edit_op("chan", &key, "mid1", clock.now_ms(), json!({"v":2})),
        )
        .unwrap();
        clock.advance(500);
        queue::enqueue(
            &dir,
            &edit_op("chan", &key, "mid1", clock.now_ms(), json!({"v":3})),
        )
        .unwrap();

        let api = MockDiscord::new();
        let b = bucket();
        let c = cfg(&dir);

        // Not yet quiet: tick immediately should not deliver.
        let ev = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev
            .iter()
            .all(|e| !matches!(e, FlushEvent::Delivered { .. })));
        assert_eq!(api.calls().len(), 0);

        // Advance past the quiet window (5s) since the LAST event.
        clock.advance(5_100);
        let ev = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev.iter().any(|e| matches!(e, FlushEvent::Delivered { .. })));

        // Exactly one PATCH regardless of 3 queued events, using the latest embed.
        let calls = api.calls();
        assert_eq!(calls.len(), 1);
        match &calls[0] {
            crate::discord::DiscordCall::EditMessage { mid, embed, .. } => {
                assert_eq!(mid, "mid1");
                assert_eq!(embed, &json!({"v":3}));
            }
            other => panic!("expected an EditMessage call, got {other:?}"),
        }
        assert_eq!(queue::queue_len(&dir), 0, "all 3 op files must be cleared");
        cleanup(&dir);
    }

    #[test]
    fn retry_honors_429_retry_after() {
        let dir = temp_dir("retry429");
        let state = Mutex::new(State::new());
        queue::enqueue(&dir, &new_msg_op("chan", "o/r#1", 1000)).unwrap();

        let api = MockDiscord::new();
        api.push_id_result(Err(crate::discord::DiscordErr::RateLimited {
            retry_after: 2.0,
        }));
        let clock = TestClock::new(1000);
        let b = bucket();
        let c = cfg(&dir);

        let ev = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev.iter().any(
            |e| matches!(e, FlushEvent::RateLimited { retry_after_ms } if *retry_after_ms == 2000)
        ));

        // Immediately retrying (same tick timestamp) must NOT re-attempt.
        let ev2 = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev2.iter().all(|e| !matches!(
            e,
            FlushEvent::RateLimited { .. } | FlushEvent::Delivered { .. }
        )));
        // 2 = the first tick's read-back list_recent_messages + post_message;
        // the second tick must add nothing (gated by next_attempt_at).
        assert_eq!(
            api.calls().len(),
            2,
            "no re-attempt before retry_after elapses"
        );

        // After the retry_after window, delivery is attempted again and succeeds.
        clock.advance(2100);
        api.push_id_result(Ok("777".to_string()));
        let ev3 = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev3
            .iter()
            .any(|e| matches!(e, FlushEvent::Delivered { .. })));
        cleanup(&dir);
    }

    #[test]
    fn retry_backoff_on_5xx() {
        let dir = temp_dir("retry5xx");
        let state = Mutex::new(State::new());
        queue::enqueue(&dir, &new_msg_op("chan", "o/r#1", 1000)).unwrap();

        let api = MockDiscord::new();
        api.push_id_result(Err(crate::discord::DiscordErr::Status(500)));
        let clock = TestClock::new(1000);
        let b = bucket();
        let c = cfg(&dir);

        let ev = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev
            .iter()
            .any(|e| matches!(e, FlushEvent::Backoff { attempts: 1 })));

        // Not enough time elapsed -> no retry yet.
        clock.advance(500);
        let ev2 = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev2
            .iter()
            .all(|e| !matches!(e, FlushEvent::Delivered { .. })));
        // 2 = the first tick's read-back list_recent_messages + post_message;
        // the second tick must add nothing (gated by next_attempt_at).
        assert_eq!(api.calls().len(), 2);

        // 1s backoff for attempts=1 has elapsed.
        clock.advance(600);
        api.push_id_result(Ok("888".to_string()));
        let ev3 = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev3
            .iter()
            .any(|e| matches!(e, FlushEvent::Delivered { .. })));
        cleanup(&dir);
    }

    #[test]
    fn edit_404_recreates_and_logs() {
        let dir = temp_dir("recreate");
        let key = item_key("o/r", "1");
        let state = Mutex::new({
            let mut st = State::new();
            st.learn(WorkItem::new(
                key.clone(),
                "chan".to_string(),
                ItemType::Pr,
                0,
            ));
            if let Some(it) = st.items.get_mut(&key) {
                it.summary_message_id = Some("dead-mid".to_string());
            }
            st
        });
        queue::enqueue(
            &dir,
            &edit_op("chan", &key, "dead-mid", 1000, json!({"v":1})),
        )
        .unwrap();

        let api = MockDiscord::new();
        api.push_edit_result(Err(crate::discord::DiscordErr::Status(404)));
        api.push_id_result(Ok("new-mid".to_string()));
        let clock = TestClock::new(1000);
        clock.advance(20_100); // past debounce_max, ready immediately
        let b = bucket();
        let c = cfg(&dir);

        let ev = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev.iter().any(|e| matches!(e, FlushEvent::Recreated { .. })));

        let st = state.lock().unwrap();
        assert_eq!(
            st.items[&key].summary_message_id.as_deref(),
            Some("new-mid")
        );
        cleanup(&dir);
    }

    #[test]
    fn thread_post_403_disables_thread() {
        let dir = temp_dir("403thread");
        let key = item_key("o/r", "1");
        let state = Mutex::new({
            let mut st = State::new();
            st.learn(WorkItem::new(
                key.clone(),
                "chan".to_string(),
                ItemType::Pr,
                0,
            ));
            if let Some(it) = st.items.get_mut(&key) {
                it.thread_id = Some("thread1".to_string());
            }
            st
        });
        let op = Op {
            channel_id: "chan".to_string(),
            item_key: key.clone(),
            kind: "github.issue-commented".to_string(),
            embed: json!({"v":1}),
            fingerprint: "fp1".to_string(),
            opclass: OpClass::ThreadPost,
            target_message_id: Some("mid1".to_string()),
            target_thread_id: Some("thread1".to_string()),
            created_at: 1000,
            attempts: 0,
            next_attempt_at: None,
        };
        queue::enqueue(&dir, &op).unwrap();

        let api = MockDiscord::new();
        api.push_id_result(Err(crate::discord::DiscordErr::Status(403)));
        let clock = TestClock::new(1000);
        let b = bucket();
        let c = cfg(&dir);

        let ev = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev
            .iter()
            .any(|e| matches!(e, FlushEvent::ThreadDisabled { item_key } if item_key == &key)));

        let st = state.lock().unwrap();
        assert!(st.items[&key].thread_disabled);
        cleanup(&dir);
    }

    #[test]
    fn thread_create_post_failure_reuses_thread_no_duplicate() {
        // P1 regression: create_thread_from_message succeeds but the in-thread
        // post_to_thread fails; the retry must reuse the created thread, never
        // create a second (orphaned) one.
        let dir = temp_dir("threaddup");
        let key = item_key("o/r", "1");
        let state = Mutex::new({
            let mut st = State::new();
            st.learn(WorkItem::new(
                key.clone(),
                "chan".to_string(),
                ItemType::Pr,
                0,
            ));
            if let Some(it) = st.items.get_mut(&key) {
                it.summary_message_id = Some("anchor1".to_string());
            }
            st
        });
        let clock = TestClock::new(1_000_000);
        queue::enqueue(
            &dir,
            &thread_create_op("chan", &key, "anchor1", clock.now_ms()),
        )
        .unwrap();

        let api = MockDiscord::new();
        let b = bucket();
        let c = cfg(&dir);

        // Tick 1: create -> Ok("thread-xyz"), post -> rate-limited failure.
        api.push_id_result(Ok("thread-xyz".to_string()));
        api.push_id_result(Err(crate::discord::DiscordErr::RateLimited {
            retry_after: 1.0,
        }));
        let _ = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        let creates_after_1 = api
            .calls()
            .iter()
            .filter(|c| matches!(c, crate::discord::DiscordCall::CreateThread { .. }))
            .count();
        assert_eq!(
            creates_after_1, 1,
            "one thread created on the first attempt"
        );

        // Tick 2 (past the retry backoff): post -> Ok. Must NOT create a second thread.
        api.push_id_result(Ok("posted-1".to_string()));
        clock.advance(6_000);
        let _ = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);

        let calls = api.calls();
        let creates = calls
            .iter()
            .filter(|c| matches!(c, crate::discord::DiscordCall::CreateThread { .. }))
            .count();
        let posts = calls
            .iter()
            .filter(|c| matches!(c, crate::discord::DiscordCall::PostToThread { thread_id, .. } if thread_id == "thread-xyz"))
            .count();
        assert_eq!(
            creates, 1,
            "no duplicate thread: create_thread called exactly once across the retry"
        );
        assert_eq!(
            posts, 2,
            "both post attempts targeted the same existing thread"
        );

        // The item recorded the created thread id (registration survives the retry).
        let st = state.lock().unwrap();
        assert_eq!(st.items[&key].thread_id.as_deref(), Some("thread-xyz"));
        drop(st);
        cleanup(&dir);
    }

    /// A2a step 3a: before re-POSTing an uncommitted NewMessage op, GET the
    /// channel's recent messages and fingerprint-match on embed content. If an
    /// earlier attempt already landed (crash between POST success and writing
    /// `.committed`), adopt that message's id instead of posting a duplicate.
    #[test]
    fn readback_reconciliation_adopts_existing_message_without_reposting() {
        let dir = temp_dir("readback-hit");
        let key = item_key("o/r", "1");
        let state = Mutex::new({
            let mut st = State::new();
            st.learn(WorkItem::new(
                key.clone(),
                "chan".to_string(),
                ItemType::Issue,
                0,
            ));
            st
        });
        let op = {
            let mut o = new_msg_op("chan", &key, 1000);
            o.embed = json!({
                "title": "already posted",
                "description": "issue body text",
                "color": 5793266,
                "author": {"name": "engels74/zondarr"},
                "footer": {"text": "GJC · gjc · 00:00 Berlin"},
                "fields": [
                    {"name": "Repo", "value": "engels74/zondarr", "inline": true}
                ],
            });
            o
        };
        queue::enqueue(&dir, &op).unwrap();

        let api = MockDiscord::new();
        // Round 7 regression: Discord does NOT echo the embed byte-identically
        // — it normalizes/enriches it (adds "type":"rich", proxy_url on
        // images, etc.). Simulate that here instead of returning op.embed
        // verbatim, which is exactly what let the original exact-`==` bug
        // ship (the old test's MockDiscord never reproduced normalization).
        let mut discord_normalized = op.embed.clone();
        let obj = discord_normalized.as_object_mut().unwrap();
        obj.insert("type".to_string(), json!("rich"));
        obj.insert(
            "reference_id".to_string(),
            json!("some-internal-discord-id"),
        );
        obj.insert(
            "thumbnail".to_string(),
            json!({"proxy_url": "https://images-ext.discordapp.net/x", "width": 1, "height": 1}),
        );
        // Sanity: the fixture must genuinely differ from op.embed under exact
        // equality, or this test wouldn't exercise the Round 7 fix at all
        // (that's precisely how the old exact-`==` bug shipped unnoticed).
        assert_ne!(
            discord_normalized, op.embed,
            "fixture must NOT be byte-identical to op.embed to reproduce Discord's normalization"
        );
        api.push_list_result(Ok(vec![json!({
            "id": "already-delivered-42",
            "embeds": [discord_normalized],
        })]));
        let clock = TestClock::new(1000);
        let b = bucket();
        let c = cfg(&dir);

        let ev = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        // A read-back match must produce a distinct Recovered event (-> the
        // `[recover]` label), NOT a plain Delivered (-> `[post]`) — these are
        // semantically different outcomes and the C1 drill greps for `[recover]`
        // specifically to prove zero-duplicate delivery across a crash.
        assert!(ev.iter().any(
            |e| matches!(e, FlushEvent::Recovered { id, .. } if id == "already-delivered-42")
        ));

        let calls = api.calls();
        assert!(
            calls
                .iter()
                .any(|c| matches!(c, crate::discord::DiscordCall::ListMessages { .. })),
            "must perform the read-back GET"
        );
        assert!(
            !calls
                .iter()
                .any(|c| matches!(c, crate::discord::DiscordCall::PostMessage { .. })),
            "a matched read-back must NOT re-POST"
        );

        let st = state.lock().unwrap();
        assert_eq!(
            st.items[&key].summary_message_id.as_deref(),
            Some("already-delivered-42")
        );
        assert_eq!(queue::queue_len(&dir), 0);
        cleanup(&dir);
    }

    /// Negative case: no read-back match -> exactly one POST proceeds normally.
    #[test]
    fn readback_reconciliation_posts_once_when_no_match() {
        let dir = temp_dir("readback-miss");
        let key = item_key("o/r", "2");
        let state = Mutex::new(State::new());
        queue::enqueue(&dir, &new_msg_op("chan", &key, 1000)).unwrap();

        let api = MockDiscord::new();
        api.push_list_result(Ok(vec![json!({
            "id": "unrelated-1",
            "embeds": [json!({"title": "some other message"})],
        })]));
        api.push_id_result(Ok("brand-new-1".to_string()));
        let clock = TestClock::new(1000);
        let b = bucket();
        let c = cfg(&dir);

        let ev = flush_tick(&state, &api, &clock, &b, Some("tok".to_string()), &c);
        assert!(ev
            .iter()
            .any(|e| matches!(e, FlushEvent::Delivered { id, .. } if id == "brand-new-1")));

        let calls = api.calls();
        let list_calls = calls
            .iter()
            .filter(|c| matches!(c, crate::discord::DiscordCall::ListMessages { .. }))
            .count();
        let post_calls = calls
            .iter()
            .filter(|c| matches!(c, crate::discord::DiscordCall::PostMessage { .. }))
            .count();
        assert_eq!(list_calls, 1, "exactly one read-back GET");
        assert_eq!(post_calls, 1, "no match -> exactly one POST");
        cleanup(&dir);
    }

    /// The plan's Verification section mandates distinct greppable labels:
    /// "[post][edit][thread][dedup-drop][drop][dead-letter][recreate]
    /// [recover][flush-panic]". This asserts the flush-owned subset
    /// (post/edit/thread/recreate/recover) maps exactly as specified, and
    /// that the internal-only variants produce no label (they're either
    /// journaled elsewhere or have no mandated label).
    #[test]
    fn log_events_emits_canonical_labels() {
        let key = "o/r#1".to_string();

        let cases: &[(FlushEvent, Option<(&str, &str)>)] = &[
            (
                FlushEvent::Delivered {
                    opclass: OpClass::NewMessage,
                    item_key: key.clone(),
                    id: "mid1".to_string(),
                },
                Some(("post", "o/r#1 -> mid1")),
            ),
            (
                FlushEvent::Delivered {
                    opclass: OpClass::EditSummary,
                    item_key: key.clone(),
                    id: "mid1".to_string(),
                },
                Some(("edit", "o/r#1 -> mid1")),
            ),
            (
                FlushEvent::Delivered {
                    opclass: OpClass::ThreadCreate,
                    item_key: key.clone(),
                    id: "thread1".to_string(),
                },
                Some(("thread", "o/r#1 -> thread1")),
            ),
            (
                FlushEvent::Delivered {
                    opclass: OpClass::ThreadPost,
                    item_key: key.clone(),
                    id: "mid2".to_string(),
                },
                Some(("thread", "o/r#1 -> mid2")),
            ),
            (
                FlushEvent::Recovered {
                    opclass: OpClass::NewMessage,
                    item_key: key.clone(),
                    id: "already-there".to_string(),
                },
                Some((
                    "recover",
                    "o/r#1 -> already-there (read-back match, no re-post)",
                )),
            ),
            (
                FlushEvent::Recreated {
                    opclass: OpClass::EditSummary,
                    item_key: key.clone(),
                    new_id: "fresh-mid".to_string(),
                },
                Some(("recreate", "o/r#1 -> fresh-mid")),
            ),
            // Not in the flush-owned label set: journaled elsewhere or no label.
            (
                FlushEvent::Buried {
                    reason: "x".to_string(),
                },
                None,
            ),
            (
                FlushEvent::ThreadDisabled {
                    item_key: key.clone(),
                },
                None,
            ),
            (FlushEvent::RateLimited { retry_after_ms: 1 }, None),
            (FlushEvent::Backoff { attempts: 1 }, None),
            (FlushEvent::Parked, None),
        ];

        for (event, expected) in cases {
            let got = label_and_message(event);
            match expected {
                Some((label, msg)) => {
                    assert_eq!(
                        got.as_ref().map(|(l, m)| (*l, m.as_str())),
                        Some((*label, *msg)),
                        "event={event:?}"
                    );
                }
                None => assert!(got.is_none(), "event={event:?} must produce no label"),
            }
        }
    }

    /// SECURITY: the message half of every logged event is metadata only
    /// (work-item key + message/thread id) — never a token, header, or embed
    /// field name that could carry request/response content.
    #[test]
    fn log_events_messages_never_carry_forbidden_substrings() {
        let events = vec![
            FlushEvent::Delivered {
                opclass: OpClass::NewMessage,
                item_key: "o/r#1".to_string(),
                id: "mid1".to_string(),
            },
            FlushEvent::Recovered {
                opclass: OpClass::NewMessage,
                item_key: "o/r#1".to_string(),
                id: "mid1".to_string(),
            },
            FlushEvent::Recreated {
                opclass: OpClass::EditSummary,
                item_key: "o/r#1".to_string(),
                new_id: "mid2".to_string(),
            },
        ];
        for event in &events {
            let (_, msg) = label_and_message(event).unwrap();
            let lower = msg.to_ascii_lowercase();
            for forbidden in ["token", "bearer", "authorization", "embed", "content"] {
                assert!(
                    !lower.contains(forbidden),
                    "msg={msg:?} leaked {forbidden:?}"
                );
            }
        }
    }

    #[test]
    fn parked_when_no_token() {
        let dir = temp_dir("parked");
        let state = Mutex::new(State::new());
        let api = MockDiscord::new();
        let clock = TestClock::new(0);
        let b = bucket();
        let c = cfg(&dir);
        let ev = flush_tick(&state, &api, &clock, &b, None, &c);
        assert_eq!(ev, vec![FlushEvent::Parked]);
        assert_eq!(api.calls().len(), 0);
        cleanup(&dir);
    }

    #[test]
    fn supervised_run_recovers_and_continues_after_panic() {
        let calls = std::cell::RefCell::new(0);
        let panics = supervised_run_n(3, || {
            *calls.borrow_mut() += 1;
            if *calls.borrow() == 2 {
                panic!("simulated flush-tick bug");
            }
        });
        assert_eq!(panics, 1);
        assert_eq!(*calls.borrow(), 3, "the loop must continue after the panic");
    }

    #[test]
    fn flush_panic_recovers_poisoned_mutex() {
        use std::sync::Arc;
        let state = Arc::new(Mutex::new(State::new()));
        let s2 = state.clone();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = s2.lock().unwrap();
            panic!("simulated panic while holding the state lock");
        }));
        assert!(result.is_err());
        assert!(state.is_poisoned());

        // Supervised recovery: every state acquisition site uses
        // `unwrap_or_else(|e| e.into_inner())`, so the mutex remains usable.
        let mut guard = state.lock().unwrap_or_else(|e| e.into_inner());
        guard.learn(WorkItem::new(
            "o/r#1".to_string(),
            "c".to_string(),
            ItemType::Pr,
            0,
        ));
        assert!(guard.items.contains_key("o/r#1"));
    }
}
