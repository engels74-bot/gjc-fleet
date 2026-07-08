//! HTTP request handling: reverse-proxy plumbing plus the message-POST transform.
//!
//! Round 2 adds the managed absorb path: for a channel listed in
//! `RELAY_WORKITEM_CHANNELS`, a well-formed GJCEMBED1 message POST that
//! `policy::decide` routes to a managed surface is intercepted here — enqueued
//! durably (queue.rs) and acknowledged with a synthetic 200 — instead of being
//! forwarded to Discord. Everything else (unmanaged channels, unmanaged kinds,
//! malformed content, the flag entirely unset) falls through to the byte-
//! identical v1 path below, unchanged from Phase A-1a.

use std::io::Read;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tiny_http::{Header, Method, Request, Response};

use crate::config::Config;
use crate::envelope::{self, cap, clean_degrade, Envelope, MAGIC};
use crate::flush::ChannelBucket;
use crate::log::log_meta;
use crate::policy::{self, Surface};
use crate::queue::{self, EnqueueOutcome, Op, OpClass};
use crate::registry::{self, CiFacet, ItemType, State, WorkItem, WorkItemUpdate};
use crate::render::{build_embed, build_embed_from_envelope, embed_text_len};

fn channel_of(path: &str) -> Option<&str> {
    // Extract {id} from .../channels/{id}/messages
    let p = path.split('?').next().unwrap_or(path);
    p.split("/channels/").nth(1)?.split('/').next()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// In-memory cache of the most recently observed inbound Authorization bearer,
/// used by the flush thread to authenticate managed deliveries. NEVER logged,
/// NEVER written to disk (see store.rs / queue.rs doc comments for the same
/// invariant on the durable side).
#[derive(Clone, Default)]
pub(crate) struct TokenCache(Arc<Mutex<Option<String>>>);

impl TokenCache {
    pub(crate) fn new() -> TokenCache {
        TokenCache::default()
    }

    pub(crate) fn set(&self, token: String) {
        let mut g = self.0.lock().unwrap_or_else(|e| e.into_inner());
        *g = Some(token);
    }

    pub(crate) fn get(&self) -> Option<String> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

/// Bundles the v2 managed-path runtime handles threaded through `handle()`.
/// Entirely inert (never consulted beyond the token capture, which has no
/// effect on the HTTP response) while `cfg.workitem_channels` is empty.
pub(crate) struct ManagedCtx {
    pub(crate) cfg: Arc<Config>,
    pub(crate) state: Arc<Mutex<State>>,
    pub(crate) bucket: Arc<ChannelBucket>,
    pub(crate) token_cache: TokenCache,
}

pub(crate) fn handle(
    mut req: Request,
    ds: &Value,
    agent: &ureq::Agent,
    upstream: &str,
    force_429: &[String],
    managed: &ManagedCtx,
) {
    let method = req.method().clone();
    let full_path = req.url().to_string();
    let log_path = full_path
        .split('?')
        .next()
        .unwrap_or(&full_path)
        .to_string();

    // Local health endpoint — never proxied upstream.
    if method == Method::Get && (full_path == "/healthz" || full_path.starts_with("/healthz?")) {
        let _ = req.respond(Response::from_string("ok").with_status_code(200));
        return;
    }

    // Read the incoming body.
    let mut body = Vec::new();
    let _ = req.as_reader().read_to_end(&mut body);

    // Collect forwardable request headers (Authorization is forwarded, never logged).
    let mut fwd_headers: Vec<(String, String)> = Vec::new();
    for h in req.headers() {
        let field = h.field.as_str().as_str().to_string();
        let lf = field.to_ascii_lowercase();
        if matches!(
            lf.as_str(),
            "host" | "content-length" | "connection" | "accept-encoding" | "transfer-encoding"
        ) {
            continue;
        }
        fwd_headers.push((field, h.value.as_str().to_string()));
    }

    // Capture the bearer token for the managed delivery path (memory-only,
    // never logged/written to disk). Purely a side effect: it never changes
    // what is returned to the caller, so it cannot break v1 byte-identity.
    if method == Method::Post {
        if let Some((_, v)) = fwd_headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("authorization"))
        {
            managed.token_cache.set(v.clone());
        }
    }

    // Decide whether this is a message POST subject to transform.
    let is_message_post = method == Method::Post
        && log_path.contains("/channels/")
        && log_path.ends_with("/messages");

    // Diagnostic: channel-scoped synthetic 429 (Phase-2 backoff drill). Inert unless
    // RELAY_FORCE_429 lists this channel. Faithfully shaped like Discord's 429 body.
    if is_message_post && !force_429.is_empty() {
        if let Some(cid) = channel_of(&log_path) {
            if force_429.iter().any(|c| c == cid) {
                let b = b"{\"message\":\"forced 429 (RELAY_FORCE_429 diagnostic)\",\"retry_after\":1.0,\"global\":false}";
                let mut r = Response::from_data(b.to_vec()).with_status_code(429);
                if let Ok(h) = Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]) {
                    r = r.with_header(h);
                }
                let _ = req.respond(r);
                log_meta(
                    "force429",
                    &format!("POST {} -> 429 (diagnostic)", log_path),
                );
                return;
            }
        }
    }

    // Managed absorption (Round 2): only reachable when the channel is listed
    // in RELAY_WORKITEM_CHANNELS. With the selector empty, channel_is_managed
    // is false for every cid (Round-1 test-proven), so this whole block is
    // unreachable and the v1 path below is byte-identical to Phase A-1a.
    if is_message_post {
        if let Some(cid) = channel_of(&log_path) {
            if managed.cfg.channel_is_managed(cid) {
                if let Ok(v) = serde_json::from_slice::<Value>(&body) {
                    if let Some(content) = v.get("content").and_then(|c| c.as_str()) {
                        if content.starts_with(MAGIC) {
                            if let Ok(env) = envelope::parse_envelope(content) {
                                if env.kind == "heartbeat" {
                                    // A2c: capture-token-then-drop, never forwarded.
                                    let _ = req.respond(
                                        Response::from_string(
                                            "{\"id\":\"0\",\"gjc_relay\":\"heartbeat\"}",
                                        )
                                        .with_status_code(200),
                                    );
                                    log_meta("heartbeat", &format!("cid={cid}"));
                                    return;
                                }
                                let cid_owned = cid.to_string();
                                let env_owned = env.clone();
                                let outcome =
                                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                                        try_absorb(&cid_owned, &env_owned, managed)
                                    }));
                                match outcome {
                                    Ok(true) => {
                                        let _ = req.respond(
                                            Response::from_string(format!(
                                                "{{\"id\":\"0\",\"channel_id\":\"{cid_owned}\",\"gjc_relay\":\"accepted\"}}"
                                            ))
                                            .with_status_code(200),
                                        );
                                        log_meta(
                                            "managed-accept",
                                            &format!("cid={cid_owned} kind={}", env_owned.kind),
                                        );
                                        return;
                                    }
                                    Ok(false) => { /* not absorbed: fall through to v1 */ }
                                    Err(_) => {
                                        // Pre-ack panic: nothing has been sent yet, so
                                        // falling through to v1 is byte-identical fail-open.
                                        log_meta(
                                            "managed-panic",
                                            &format!(
                                                "cid={cid_owned}: recovered, falling back to v1"
                                            ),
                                        );
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Shared per-channel bucket accounting for the unmanaged/critical
            // verbatim-forward path (priority draw; never blocks or drops).
            managed.bucket.take_critical(cid, now_ms());
        }
    }

    let mut kind_label = String::new();
    let (send_body, override_ct) = if is_message_post {
        let (b, ct, kind) = transform_body(&body, ds);
        kind_label = kind;
        (b, ct)
    } else {
        (body, None)
    };

    // Forward to upstream (host only + verbatim path).
    let url = format!("{upstream}{full_path}");
    let mut rq = agent.request(method.as_str(), &url);
    for (k, v) in &fwd_headers {
        if override_ct.is_some() && k.eq_ignore_ascii_case("content-type") {
            continue;
        }
        rq = rq.set(k, v);
    }
    if let Some(ct) = &override_ct {
        rq = rq.set("Content-Type", ct);
    }

    let result = if send_body.is_empty() {
        rq.call()
    } else {
        rq.send_bytes(&send_body)
    };

    let resp = match result {
        Ok(r) => r,
        Err(ureq::Error::Status(_, r)) => r, // non-2xx (incl. 429): mirror status + body
        Err(ureq::Error::Transport(t)) => {
            log_meta(
                "upstream-error",
                &format!("{} {} transport={:?}", method.as_str(), log_path, t.kind()),
            );
            let mut r = Response::from_string("{\"relay_error\":\"upstream_unreachable\"}")
                .with_status_code(502);
            if let Ok(h) = Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]) {
                r = r.with_header(h);
            }
            let _ = req.respond(r);
            return;
        }
    };

    // Mirror status + selected response headers + body unchanged.
    let status = resp.status();
    let mut out_headers: Vec<Header> = Vec::new();
    for name in resp.headers_names() {
        let ln = name.to_ascii_lowercase();
        if matches!(
            ln.as_str(),
            "content-length" | "transfer-encoding" | "connection" | "content-encoding"
        ) {
            continue;
        }
        if let Some(val) = resp.header(&name) {
            if let Ok(h) = Header::from_bytes(name.as_bytes(), val.as_bytes()) {
                out_headers.push(h);
            }
        }
    }
    let mut rbody = Vec::new();
    let _ = resp.into_reader().read_to_end(&mut rbody);

    let mut response = Response::from_data(rbody).with_status_code(status);
    for h in out_headers {
        response = response.with_header(h);
    }
    let _ = req.respond(response);

    if kind_label.is_empty() {
        log_meta(
            "proxy",
            &format!("{} {} -> {}", method.as_str(), log_path, status),
        );
    } else {
        log_meta(
            "transform",
            &format!(
                "{} {} kind={} -> {}",
                method.as_str(),
                log_path,
                kind_label,
                status
            ),
        );
    }
}

/// Returns (body_to_send, content_type_override, kind_label_for_log).
fn transform_body(body: &[u8], ds: &Value) -> (Vec<u8>, Option<String>, String) {
    let v: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return (body.to_vec(), None, String::new()),
    };
    let content = match v.get("content").and_then(|c| c.as_str()) {
        Some(c) => c.to_string(),
        None => return (body.to_vec(), None, String::new()),
    };
    if !content.starts_with(MAGIC) {
        return (body.to_vec(), None, String::new());
    }

    let mut obj = v.as_object().cloned().unwrap_or_default();
    obj.remove("content");

    // Multi-envelope batch: clawhip's routine batcher joins several rendered
    // GJCEMBED1 lines with '\n' into ONE message, which would otherwise render
    // as a single embed with raw envelope lines inside its description. Build
    // one embed per line instead. Discord caps: 10 embeds per message, 6000
    // chars aggregate across embeds, 2000 chars `content`. Lines that don't
    // fit (or fail to parse) degrade to clean text in `content`.
    let lines: Vec<&str> = content.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.len() > 1 && lines.iter().all(|l| l.starts_with(MAGIC)) {
        let mut embeds: Vec<Value> = Vec::new();
        let mut kinds: Vec<String> = Vec::new();
        let mut degraded: Vec<String> = Vec::new();
        let mut total = 0usize;
        for line in &lines {
            if embeds.len() < 10 {
                if let Ok((embed, kind)) = build_embed(line, ds) {
                    let len = embed_text_len(&embed);
                    if total + len <= 6000 {
                        total += len;
                        embeds.push(embed);
                        kinds.push(kind);
                        continue;
                    }
                }
            }
            degraded.push(clean_degrade(line));
        }
        if !embeds.is_empty() {
            obj.insert("embeds".to_string(), json!(embeds));
            if !degraded.is_empty() {
                obj.insert(
                    "content".to_string(),
                    json!(cap(&degraded.join("\n"), 2000)),
                );
            }
            return (
                serde_json::to_vec(&Value::Object(obj)).unwrap_or_else(|_| body.to_vec()),
                Some("application/json".to_string()),
                format!("batch[{}]:{}", kinds.len(), kinds.join(",")),
            );
        }
        // Every line malformed -> fall through to the single-envelope path,
        // which cleanly degrades the whole content.
    }

    match build_embed(&content, ds) {
        Ok((embed, kind)) => {
            obj.insert("embeds".to_string(), json!([embed]));
            (
                serde_json::to_vec(&Value::Object(obj)).unwrap_or_else(|_| body.to_vec()),
                Some("application/json".to_string()),
                kind,
            )
        }
        Err(()) => {
            let clean = clean_degrade(&content);
            obj.insert("content".to_string(), json!(clean));
            (
                serde_json::to_vec(&Value::Object(obj)).unwrap_or_else(|_| body.to_vec()),
                Some("application/json".to_string()),
                "degrade".to_string(),
            )
        }
    }
}

/// Attempt to absorb a managed inbound message POST. Returns `true` when the
/// event was absorbed (Drop, or a delivered/enqueued surface — the caller
/// sends the synthetic 200 and stops), or `false` when the request should
/// fall through to the normal v1 proxy path (unmanaged surface).
///
/// MUST be called inside `std::panic::catch_unwind` by the caller: everything
/// here runs strictly BEFORE any ack is sent, so a panic recovered by the
/// caller safely falls back to v1 (pre-persist fail-open). Nothing here talks
/// to Discord directly (single-deliverer invariant) — it only enqueues.
fn try_absorb(cid: &str, env: &Envelope, managed: &ManagedCtx) -> bool {
    // Defense in depth: handle() only reaches this function from behind the
    // same guard, but keeping it here too makes try_absorb a correct, safely
    // callable unit on its own (see the unmanaged-channel test below).
    if !managed.cfg.channel_is_managed(cid) {
        return false;
    }

    // Two clocks, two units, on purpose: `now` (seconds) feeds the registry
    // (WorkItem.created_at/last_event_at, item-TTL prune, dedup TTL — all
    // *_SECS constants) and must stay in seconds. `now_ms_val` feeds the
    // durable Op's `created_at`, because flush.rs's debounce window and
    // delivery_max_age check compare it against `Clock::now_ms()` — using the
    // seconds value there made every fresh op look ~1.78e12ms old and get
    // buried within seconds of being enqueued (Round 6 fix).
    let now = crate::store::now_ts();
    let now_ms_val = now_ms();
    let key_opt = envelope_item_key(env);

    let item_known = {
        let st = managed.state.lock().unwrap_or_else(|e| e.into_inner());
        key_opt.as_ref().is_some_and(|k| st.items.contains_key(k))
    };

    let fp = fingerprint_for(env);
    let dedup_hit = {
        let mut st = managed.state.lock().unwrap_or_else(|e| e.into_inner());
        match &fp {
            Some(f) => !st.dedup_check_and_insert(f.clone(), now),
            None => false,
        }
    };

    let surface = policy::decide(&env.kind, env, item_known, dedup_hit, true, &managed.cfg.ds);
    if surface == Surface::Unmanaged {
        return false;
    }
    if surface == Surface::Drop {
        if dedup_hit {
            // A genuine duplicate event (same fingerprint within the dedup
            // TTL) — idempotency suppressed it, not the flood guard below.
            log_meta(
                "dedup-drop",
                &format!(
                    "kind={} cid={cid} key={} fp={}",
                    env.kind,
                    key_opt.as_deref().unwrap_or("-"),
                    fp.as_deref().unwrap_or("-")
                ),
            );
        } else {
            // policy::decide only returns Drop for a dedup hit or the
            // unknown-item CI flood class (#easyhdr reboot-flood killer) —
            // this branch is that flood class.
            log_meta(
                "drop",
                &format!(
                    "kind={} repo={} cid={cid} (unknown-item CI flood)",
                    env.kind, env.repo
                ),
            );
        }
        return true;
    }

    let embed = build_embed_from_envelope(env, &managed.cfg.ds);
    let key = key_opt.unwrap_or_else(|| synthetic_key(env, cid));

    let ops: Vec<Op> = {
        let mut st = managed.state.lock().unwrap_or_else(|e| e.into_inner());
        if !st.items.contains_key(&key) {
            let mut item = WorkItem::new(
                key.clone(),
                cid.to_string(),
                infer_item_type(&env.kind),
                now,
            );
            item.title = env.title.clone();
            st.learn(item);
        }
        apply_envelope_update(&mut st, &key, env, now);

        if env.kind == "github.pr-status-changed"
            && matches!(env.status.as_str(), "merged" | "closed")
        {
            st.mark_terminal(&key, now);
        }

        let item = st.items.get(&key).cloned();
        let summary_mid = item.as_ref().and_then(|i| i.summary_message_id.clone());
        let thread_id = item.as_ref().and_then(|i| i.thread_id.clone());

        let mut ops = Vec::new();
        match surface {
            Surface::NewMessage => {
                ops.push(new_op(
                    cid,
                    &key,
                    &env.kind,
                    embed.clone(),
                    fp.clone(),
                    OpClass::NewMessage,
                    None,
                    None,
                    now_ms_val,
                ));
            }
            Surface::EditSummary => {
                // Defensive invariant: policy only returns EditSummary when the
                // item is known and therefore has an anchor. A violation here is
                // a genuine bug — panicking is intentional so the caller's
                // catch_unwind fail-open recovers safely (see doc comment above).
                let mid = summary_mid.clone().expect(
                    "policy invariant violated: EditSummary surface requires a known summary_message_id",
                );
                ops.push(new_op(
                    cid,
                    &key,
                    &env.kind,
                    embed.clone(),
                    fp.clone(),
                    OpClass::EditSummary,
                    Some(mid),
                    None,
                    now_ms_val,
                ));
            }
            Surface::ThreadPost => {
                ops.push(thread_op(
                    cid,
                    &key,
                    &env.kind,
                    embed.clone(),
                    fp.clone(),
                    summary_mid.clone(),
                    thread_id.clone(),
                    now_ms_val,
                ));
            }
            Surface::EditAndThread => {
                if let Some(mid) = summary_mid.clone() {
                    ops.push(new_op(
                        cid,
                        &key,
                        &env.kind,
                        embed.clone(),
                        fp.clone(),
                        OpClass::EditSummary,
                        Some(mid),
                        None,
                        now_ms_val,
                    ));
                }
                ops.push(thread_op(
                    cid,
                    &key,
                    &env.kind,
                    embed.clone(),
                    fp.clone(),
                    summary_mid,
                    thread_id,
                    now_ms_val,
                ));
            }
            Surface::Unmanaged | Surface::Drop => unreachable!("handled above"),
        }
        ops
    };

    for op in &ops {
        match queue::enqueue_checked(&managed.cfg.state_dir, op, managed.cfg.queue_cap) {
            Ok(EnqueueOutcome::Enqueued) => {}
            Ok(EnqueueOutcome::CapacityExceeded) => {
                log_meta(
                    "queue-full",
                    &format!("dropped op cid={cid} kind={} (capacity)", env.kind),
                );
            }
            Err(e) => {
                log_meta("queue-error", &format!("enqueue failed cid={cid}: {e}"));
            }
        }
    }

    true
}

fn envelope_item_key(env: &Envelope) -> Option<String> {
    if !env.repo.is_empty() && !env.number.is_empty() {
        Some(registry::item_key(&env.repo, &env.number))
    } else {
        None
    }
}

/// A key for events that never carry a work-item number (e.g. branch-push CI):
/// keyed by repo+branch so repeated events on the same branch still correlate,
/// or a per-kind orphan key as a last resort.
fn synthetic_key(env: &Envelope, cid: &str) -> String {
    if !env.repo.is_empty() && !env.branch.is_empty() {
        format!("{}@{}", env.repo, env.branch)
    } else {
        format!("orphan:{cid}:{}", env.kind)
    }
}

fn infer_item_type(kind: &str) -> ItemType {
    if kind.starts_with("github.issue-") {
        ItemType::Issue
    } else {
        ItemType::Pr
    }
}

fn fingerprint_for(env: &Envelope) -> Option<String> {
    match env.kind.as_str() {
        "github.ci-started" | "github.ci-passed" | "github.ci-cancelled" | "github.ci-failed" => {
            let num_or_branch = if !env.number.is_empty() {
                env.number.clone()
            } else {
                env.branch.clone()
            };
            Some(registry::ci_fingerprint(
                &env.repo,
                &num_or_branch,
                &env.sha,
                &env.run,
                &env.status,
            ))
        }
        "github.issue-opened" | "github.issue-commented" => Some(registry::issue_fingerprint(
            &env.repo,
            &env.number,
            &env.kind,
        )),
        "github.pr-status-changed" => Some(registry::pr_fingerprint(
            &env.repo,
            &env.number,
            &env.status,
        )),
        _ => None,
    }
}

fn apply_envelope_update(st: &mut State, key: &str, env: &Envelope, now: i64) {
    let mut upd = WorkItemUpdate::default();
    if env.title.is_some() {
        upd.title = env.title.clone();
    }
    if !env.stage.is_empty() {
        upd.stage = Some(env.stage.clone());
    }
    if matches!(
        env.kind.as_str(),
        "github.ci-started" | "github.ci-passed" | "github.ci-cancelled" | "github.ci-failed"
    ) {
        upd.ci = Some(CiFacet {
            status: non_empty(&env.status),
            passed: env.passed.parse().ok(),
            failed: env.failed.parse().ok(),
            total: env.total.parse().ok(),
            sha: non_empty(&env.sha),
            run_url: non_empty(&env.url),
        });
    }
    st.update(key, upd, now);
}

fn non_empty(s: &str) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

/// `created_at_ms` MUST be a millisecond timestamp (`http::now_ms()`), NOT the
/// seconds `now` used for the registry — flush.rs's debounce window and
/// `delivery_max_age_secs` check both compare `Op.created_at` against
/// `Clock::now_ms()`. Passing seconds here buries every fresh op instantly
/// (Round 6 regression: see queue.rs's and flush.rs's doc comments on
/// `Op.created_at`).
#[allow(clippy::too_many_arguments)]
fn new_op(
    cid: &str,
    key: &str,
    kind: &str,
    embed: Value,
    fp: Option<String>,
    opclass: OpClass,
    target_message_id: Option<String>,
    target_thread_id: Option<String>,
    created_at_ms: i64,
) -> Op {
    Op {
        channel_id: cid.to_string(),
        item_key: key.to_string(),
        kind: kind.to_string(),
        embed,
        fingerprint: fp.unwrap_or_default(),
        opclass,
        target_message_id,
        target_thread_id,
        created_at: created_at_ms,
        attempts: 0,
        next_attempt_at: None,
    }
}

/// See [`new_op`]'s doc comment: `created_at_ms` must be milliseconds.
#[allow(clippy::too_many_arguments)]
fn thread_op(
    cid: &str,
    key: &str,
    kind: &str,
    embed: Value,
    fp: Option<String>,
    summary_mid: Option<String>,
    thread_id: Option<String>,
    created_at_ms: i64,
) -> Op {
    match thread_id {
        Some(tid) => new_op(
            cid,
            key,
            kind,
            embed,
            fp,
            OpClass::ThreadPost,
            summary_mid,
            Some(tid),
            created_at_ms,
        ),
        None => new_op(
            cid,
            key,
            kind,
            embed,
            fp,
            OpClass::ThreadCreate,
            summary_mid,
            None,
            created_at_ms,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::WorkitemChannels;
    use crate::registry::item_key;

    fn ds() -> Value {
        json!({
            "kinds": {
                "agent.started": { "color": 5793266, "title": "🚀 Agent started" },
                "github.pr-status-changed": { "color": 10181046, "title": "🔀 PR update" },
                "default": { "color": 9807270, "title": "💬 {kind}" }
            }
        })
    }

    #[test]
    fn channel_of_extracts_id() {
        assert_eq!(channel_of("/api/v10/channels/123/messages"), Some("123"));
        assert_eq!(
            channel_of("/api/v10/channels/123/messages?wait=true"),
            Some("123")
        );
        assert_eq!(channel_of("/api/v10/gateway"), None);
    }

    #[test]
    fn transform_no_prefix_is_byte_for_byte() {
        let body = br#"{"content":"plain hi"}"#;
        let (out, ct, kind) = transform_body(body, &ds());
        assert_eq!(out, body.to_vec());
        assert!(ct.is_none() && kind.is_empty());
    }

    #[test]
    fn transform_non_json_is_untouched() {
        let body = b"not json at all";
        let (out, ct, _) = transform_body(body, &ds());
        assert_eq!(out, body.to_vec());
        assert!(ct.is_none());
    }

    #[test]
    fn transform_valid_envelope_yields_embeds_and_preserves_other_fields() {
        let body = br#"{"content":"GJCEMBED1 kind=agent.started :: hi","message_reference":{"message_id":"9"}}"#;
        let (out, ct, kind) = transform_body(body, &ds());
        assert_eq!(ct.as_deref(), Some("application/json"));
        assert_eq!(kind, "agent.started");
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert!(v.get("content").is_none(), "content must be replaced");
        assert!(v["embeds"].as_array().is_some());
        assert_eq!(
            v["message_reference"]["message_id"], "9",
            "unknown fields preserved"
        );
    }

    #[test]
    fn transform_multiline_batch_builds_one_embed_per_line() {
        // clawhip's routine batcher joins rendered envelopes with '\n'
        let body = br#"{"content":"GJCEMBED1 kind=agent.started repo=o/r :: one\nGJCEMBED1 kind=agent.finished repo=o/r :: two"}"#;
        let (out, ct, kind) = transform_body(body, &ds());
        assert_eq!(ct.as_deref(), Some("application/json"));
        assert!(kind.starts_with("batch[2]:"), "kind label: {kind}");
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert!(v.get("content").is_none(), "no degraded lines expected");
        let embeds = v["embeds"].as_array().unwrap();
        assert_eq!(embeds.len(), 2);
        assert!(embeds[0]["description"].as_str().unwrap().contains("one"));
        assert!(embeds[1]["description"].as_str().unwrap().contains("two"));
    }

    #[test]
    fn transform_multiline_batch_degrades_bad_lines_to_content() {
        // second line has a malformed head (bare token) -> clean degrade
        let body = br#"{"content":"GJCEMBED1 kind=agent.started :: ok line\nGJCEMBED1 kindbroken :: salvaged text"}"#;
        let (out, _, kind) = transform_body(body, &ds());
        assert!(kind.starts_with("batch[1]:"), "kind label: {kind}");
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert_eq!(v["embeds"].as_array().unwrap().len(), 1);
        let c = v["content"].as_str().unwrap();
        assert!(c.contains("salvaged text"));
        assert!(!c.contains("GJCEMBED1") && !c.contains("::"));
    }

    #[test]
    fn transform_malformed_degrades_to_clean_content() {
        let body = br#"{"content":"GJCEMBED1 kindfoo :: just text"}"#;
        let (out, _, kind) = transform_body(body, &ds());
        assert_eq!(kind, "degrade");
        let v: Value = serde_json::from_slice(&out).unwrap();
        let c = v["content"].as_str().unwrap();
        assert_eq!(c, "just text");
        assert!(!c.contains("GJCEMBED1") && !c.contains("::"));
        assert!(v.get("embeds").is_none());
    }

    // --- Round 2: managed absorb path ---

    fn test_cfg(workitem_channels: WorkitemChannels) -> Config {
        Config {
            bind: String::new(),
            ds: Arc::new(ds()),
            upstream: Arc::new(String::new()),
            force_429: Arc::new(vec![]),
            fault_after_post: Arc::new(vec![]),
            workitem_channels,
            state_dir: std::env::temp_dir()
                .join(format!(
                    "gjc-relay-http-test-{}-{:?}",
                    std::process::id(),
                    std::time::SystemTime::now()
                ))
                .to_string_lossy()
                .into_owned(),
            debounce_secs: 5,
            debounce_max_secs: 20,
            delivery_max_age_secs: 600,
            queue_cap: 500,
            debounce_overrides: std::collections::HashMap::new(),
            managed_rate: crate::config::ManagedRate {
                managed_tokens: 3,
                window_secs: 5,
            },
            heartbeat_enabled: true,
            heartbeat_secs: 120,
        }
    }

    fn test_ctx(workitem_channels: WorkitemChannels) -> ManagedCtx {
        ManagedCtx {
            cfg: Arc::new(test_cfg(workitem_channels)),
            state: Arc::new(Mutex::new(State::new())),
            bucket: Arc::new(ChannelBucket::new(crate::config::ManagedRate {
                managed_tokens: 3,
                window_secs: 5,
            })),
            token_cache: TokenCache::new(),
        }
    }

    #[test]
    fn try_absorb_noop_when_channel_unmanaged() {
        let managed = test_ctx(WorkitemChannels::None);
        let env = Envelope {
            kind: "github.issue-opened".to_string(),
            repo: "o/r".to_string(),
            number: "1".to_string(),
            ..Envelope::default()
        };
        assert!(!try_absorb("1", &env, &managed));
        assert!(
            managed.state.lock().unwrap().items.is_empty(),
            "an unmanaged channel must never mutate the registry"
        );
        let _ = std::fs::remove_dir_all(&managed.cfg.state_dir);
    }

    #[test]
    fn try_absorb_new_message_for_known_channel() {
        let managed = test_ctx(WorkitemChannels::Set(
            ["1".to_string()].into_iter().collect(),
        ));
        let env = Envelope {
            kind: "github.issue-opened".to_string(),
            repo: "o/r".to_string(),
            number: "1".to_string(),
            title: Some("A new issue".to_string()),
            ..Envelope::default()
        };
        assert!(try_absorb("1", &env, &managed));
        let key = item_key("o/r", "1");
        assert!(managed.state.lock().unwrap().items.contains_key(&key));
        assert_eq!(queue::queue_len(&managed.cfg.state_dir), 1);
        let _ = std::fs::remove_dir_all(&managed.cfg.state_dir);
    }

    #[test]
    fn try_absorb_drops_duplicate_events() {
        let managed = test_ctx(WorkitemChannels::Set(
            ["1".to_string()].into_iter().collect(),
        ));
        let env = Envelope {
            kind: "github.issue-opened".to_string(),
            repo: "o/r".to_string(),
            number: "1".to_string(),
            ..Envelope::default()
        };
        assert!(try_absorb("1", &env, &managed));
        assert_eq!(queue::queue_len(&managed.cfg.state_dir), 1);
        // A second, identical issue-opened event dedups and is absorbed as a Drop
        // (no additional op enqueued).
        assert!(try_absorb("1", &env, &managed));
        assert_eq!(queue::queue_len(&managed.cfg.state_dir), 1);
        let _ = std::fs::remove_dir_all(&managed.cfg.state_dir);
    }

    /// The plan's A-1 byte-identity safety test: a genuine internal-invariant
    /// panic inside the managed path is recovered by `catch_unwind` before any
    /// ack is sent, so the caller falls through to v1 — and v1's output for the
    /// same raw content is completely unaffected by the aborted managed attempt.
    #[test]
    fn managed_path_panic_falls_back_to_byte_identical_v1_output() {
        let managed = test_ctx(WorkitemChannels::Set(
            ["1".to_string()].into_iter().collect(),
        ));
        let key = item_key("o/r", "5");
        {
            let mut st = managed.state.lock().unwrap();
            // Known item, but summary_message_id missing: violates the invariant
            // that EditSummary requires an anchor. policy::decide resolves
            // "pr-status-changed status=open, known" -> EditSummary, so this
            // must panic rather than silently corrupt state.
            st.learn(WorkItem::new(key.clone(), "1".to_string(), ItemType::Pr, 0));
        }
        let env = Envelope {
            kind: "github.pr-status-changed".to_string(),
            repo: "o/r".to_string(),
            number: "5".to_string(),
            status: "open".to_string(),
            ..Envelope::default()
        };

        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            try_absorb("1", &env, &managed)
        }));
        assert!(
            result.is_err(),
            "broken invariant must panic, not silently corrupt state"
        );
        assert_eq!(
            queue::queue_len(&managed.cfg.state_dir),
            0,
            "a pre-ack panic must never leave a partial op enqueued"
        );

        // The v1 path (what handle() falls through to on Err) is untouched by
        // the aborted managed attempt: same raw content, ordinary v1 output.
        let raw = br#"{"content":"GJCEMBED1 kind=github.pr-status-changed repo=o/r number=5 status=open :: PR reopened"}"#;
        let (out, ct, kind) = transform_body(raw, &ds());
        assert_eq!(ct.as_deref(), Some("application/json"));
        assert_eq!(kind, "github.pr-status-changed");
        let v: Value = serde_json::from_slice(&out).unwrap();
        assert!(v.get("embeds").is_some());
        let _ = std::fs::remove_dir_all(&managed.cfg.state_dir);
    }

    /// Round 6 regression: `op.created_at` must be MILLISECONDS (what
    /// flush.rs's debounce/max-age checks compare against `Clock::now_ms()`),
    /// not the SECONDS `now` try_absorb shares with the registry. The bug
    /// only manifested when a REAL op — created via `try_absorb`, the actual
    /// production path — was fed into `flush_tick` against a REAL clock
    /// (`SystemClock`): the earlier injected-`TestClock` unit tests all used
    /// one consistent (ms) clock on both the op-creation and flush sides, so
    /// they could never see http.rs's seconds/milliseconds mismatch. This
    /// test wires the two real modules together and uses `SystemClock` on
    /// purpose to catch exactly that class of cross-unit bug.
    #[test]
    fn freshly_absorbed_op_is_delivered_not_buried() {
        use crate::discord::MockDiscord;
        use crate::flush::{flush_tick, Clock, FlushCfg, SystemClock};

        let managed = test_ctx(WorkitemChannels::Set(
            ["1".to_string()].into_iter().collect(),
        ));
        let env = Envelope {
            kind: "github.issue-opened".to_string(),
            repo: "o/r".to_string(),
            number: "1".to_string(),
            title: Some("A fresh issue".to_string()),
            ..Envelope::default()
        };

        // Real creation path (not a hand-built Op literal).
        assert!(try_absorb("1", &env, &managed));
        assert_eq!(queue::queue_len(&managed.cfg.state_dir), 1);

        // Sanity: the persisted op's created_at must look like "now in
        // milliseconds" (~13 digits, within a minute of wall-clock time), not
        // "now in seconds" (~10 digits) — the exact defect this round fixes.
        let clock = SystemClock;
        let now_ms = clock.now_ms();
        let entries = queue::scan(&managed.cfg.state_dir);
        assert_eq!(entries.len(), 1);
        let queue::QueueEntry::Pending { op, .. } = &entries[0] else {
            panic!("expected a pending op");
        };
        let age_ms = now_ms - op.created_at;
        assert!(
            (0..60_000).contains(&age_ms),
            "a just-created op must be ~0ms old under a millisecond clock, got age_ms={age_ms} \
             (created_at={}, now_ms={now_ms}); a seconds value here would show age_ms in the \
             trillions",
            op.created_at
        );

        // The actual regression: flush_tick against a REAL clock must DELIVER
        // this op (MockDiscord records exactly one post), never bury it.
        let api = MockDiscord::new();
        managed.token_cache.set("tok".to_string());
        let flush_cfg = FlushCfg {
            debounce_secs: 5,
            debounce_max_secs: 20,
            delivery_max_age_secs: 600,
            state_dir: managed.cfg.state_dir.clone(),
            fault_after_post: Vec::new(),
        };
        let bucket = ChannelBucket::new(managed.cfg.managed_rate);
        let events = flush_tick(
            &managed.state,
            &api,
            &clock,
            &bucket,
            managed.token_cache.get(),
            &flush_cfg,
        );

        assert!(
            events
                .iter()
                .any(|e| matches!(e, crate::flush::FlushEvent::Delivered { .. })),
            "expected a Delivered event, got {events:?}"
        );
        assert!(
            !events
                .iter()
                .any(|e| matches!(e, crate::flush::FlushEvent::Buried { .. })),
            "a freshly-created op must never be buried, got {events:?}"
        );
        let posts = api
            .calls()
            .iter()
            .filter(|c| matches!(c, crate::discord::DiscordCall::PostMessage { .. }))
            .count();
        assert_eq!(posts, 1, "MockDiscord must record exactly one post");
        assert_eq!(
            queue::queue_len(&managed.cfg.state_dir),
            0,
            "the op must be fully delivered and cleared, not left pending or buried"
        );

        let _ = std::fs::remove_dir_all(&managed.cfg.state_dir);
    }

    /// Round 6: the dedup-map restart-recovery fallback in
    /// `flush::apply_delivery_result` must store its timestamp in the SAME
    /// unit as the registry's `dedup` map (seconds — `DEDUP_TTL_SECS`,
    /// `store::now_ts()`), even though it reads it off `op.created_at`
    /// (milliseconds). A missed conversion here would make every
    /// restart-recovered dedup entry look ~1000x older than it is.
    #[test]
    fn apply_delivery_result_dedup_fallback_uses_seconds() {
        use crate::flush::{apply_delivery_result, Clock};
        use crate::queue::Committed;

        let mut st = State::new();
        let created_at_ms = crate::flush::SystemClock.now_ms();
        let op = Op {
            channel_id: "1".to_string(),
            item_key: "o/r#1".to_string(),
            kind: "github.issue-opened".to_string(),
            embed: json!({}),
            fingerprint: "iss|o/r|1|opened".to_string(),
            opclass: OpClass::NewMessage,
            target_message_id: None,
            target_thread_id: None,
            created_at: created_at_ms,
            attempts: 0,
            next_attempt_at: None,
        };
        let committed = Committed {
            message_id: "mid1".to_string(),
            fingerprint: op.fingerprint.clone(),
            delivered_at: created_at_ms,
        };
        st.learn(WorkItem::new(
            "o/r#1".to_string(),
            "1".to_string(),
            ItemType::Issue,
            0,
        ));

        apply_delivery_result(&mut st, &op, &committed);

        let seconds_now = crate::store::now_ts();
        let stored = st.dedup[&op.fingerprint];
        assert!(
            (seconds_now - 60..=seconds_now).contains(&stored),
            "dedup entry must be stored in SECONDS matching store::now_ts(), got {stored} \
             (seconds_now={seconds_now}); storing raw milliseconds would put this ~{}x too high",
            created_at_ms / seconds_now.max(1)
        );
    }
}
