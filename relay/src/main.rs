//! gjc-relay — loopback transform relay between clawhip and the Discord REST API.
//!
//! Behavior (see /home/cvps/.omc/plans/discord-unification-plan.md, Phase 1):
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

use std::io::Read;
use std::sync::Arc;

use serde_json::{json, Value};
use tiny_http::{Header, Method, Request, Response, Server};

const DEFAULT_UPSTREAM: &str = "https://discord.com";
const MAGIC: &str = "GJCEMBED1 ";
const ALLOWED_KEYS: [&str; 6] = ["kind", "repo", "status", "actor", "branch", "url"];

fn main() {
    let bind = std::env::var("RELAY_BIND").unwrap_or_else(|_| "127.0.0.1:25295".to_string());
    let ds_path = std::env::var("RELAY_DESIGN_SYSTEM")
        .unwrap_or_else(|_| "/home/cvps/.gjc-relay/design-system.json".to_string());

    let ds_raw = std::fs::read_to_string(&ds_path)
        .unwrap_or_else(|e| panic!("gjc-relay: cannot read design system {ds_path}: {e}"));
    let ds: Value = serde_json::from_str(&ds_raw)
        .unwrap_or_else(|e| panic!("gjc-relay: design system is not valid JSON: {e}"));
    let ds = Arc::new(ds);

    let upstream = Arc::new(
        std::env::var("RELAY_UPSTREAM").unwrap_or_else(|_| DEFAULT_UPSTREAM.to_string()),
    );

    // Diagnostic (default empty = inert): comma-separated channel ids for which the
    // relay returns a synthetic 429 instead of proxying. Lets the Phase-2 end-to-end
    // 429 drill exercise clawhip's backoff against ONE test channel while every real
    // channel keeps proxying normally (zero production blast radius).
    let force_429: Arc<Vec<String>> = Arc::new(
        std::env::var("RELAY_FORCE_429")
            .unwrap_or_default()
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
    );

    let agent = Arc::new(
        ureq::AgentBuilder::new()
            .redirects(0)
            .timeout_connect(std::time::Duration::from_secs(10))
            .timeout(std::time::Duration::from_secs(30))
            .build(),
    );

    let server = Arc::new(
        Server::http(&bind).unwrap_or_else(|e| panic!("gjc-relay: cannot bind {bind}: {e}")),
    );
    log_meta("startup", &format!("listening on {bind} -> {upstream}"));

    let mut handles = Vec::new();
    for _ in 0..8 {
        let server = server.clone();
        let ds = ds.clone();
        let agent = agent.clone();
        let upstream = upstream.clone();
        let force_429 = force_429.clone();
        handles.push(std::thread::spawn(move || loop {
            match server.recv() {
                Ok(req) => handle(req, &ds, &agent, &upstream, &force_429),
                Err(_) => break,
            }
        }));
    }
    for h in handles {
        let _ = h.join();
    }
}

fn channel_of(path: &str) -> Option<&str> {
    // Extract {id} from .../channels/{id}/messages
    let p = path.split('?').next().unwrap_or(path);
    p.split("/channels/").nth(1)?.split('/').next()
}

fn handle(mut req: Request, ds: &Value, agent: &ureq::Agent, upstream: &str, force_429: &[String]) {
    let method = req.method().clone();
    let full_path = req.url().to_string();
    let log_path = full_path.split('?').next().unwrap_or(&full_path).to_string();

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
                log_meta("force429", &format!("POST {} -> 429 (diagnostic)", log_path));
                return;
            }
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
        log_meta("proxy", &format!("{} {} -> {}", method.as_str(), log_path, status));
    } else {
        log_meta(
            "transform",
            &format!("{} {} kind={} -> {}", method.as_str(), log_path, kind_label, status),
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
                obj.insert("content".to_string(), json!(cap(&degraded.join("\n"), 2000)));
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

/// Build a Discord embed from a GJCEMBED1 envelope. Err(()) => route to clean degrade.
fn build_embed(content: &str, ds: &Value) -> Result<(Value, String), ()> {
    let rest = &content[MAGIC.len()..];
    let (head, tail) = match rest.find(" :: ") {
        Some(i) => (&rest[..i], &rest[i + 4..]),
        None => (rest, ""),
    };

    let mut kind = "default".to_string();
    let mut present: Vec<(String, String)> = Vec::new();
    for tok in head.split(' ') {
        if tok.is_empty() {
            continue;
        }
        let eq = tok.find('=').ok_or(())?; // bare token -> malformed
        let key = &tok[..eq];
        let val = &tok[eq + 1..];
        if !ALLOWED_KEYS.contains(&key) {
            return Err(()); // unknown key -> malformed
        }
        if is_placeholder(val) || val.is_empty() {
            continue; // absent field -> omit
        }
        // `url` accepts the extra characters a real URL query/fragment needs, so a
        // link like .../pull/5?diff=split does not degrade the whole embed to plain
        // text. Other head slots keep the strict slug charset.
        let charset_ok = if key == "url" {
            val.chars().all(|c| {
                c.is_ascii_alphanumeric()
                    || matches!(c, '.' | '_' | ':' | '/' | '-' | '?' | '=' | '&' | '#' | '%' | '~' | '+' | ',' | '@')
            })
        } else {
            val.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '/' | '-'))
        };
        if !charset_ok {
            return Err(()); // charset violation -> malformed
        }
        if key == "kind" {
            kind = val.to_string();
        } else {
            present.push((key.to_string(), val.to_string()));
        }
    }

    // A tail that is a single unexpanded placeholder (e.g. clawhip left {summary}
    // or {message} unsubstituted because the field was absent) means "no message".
    let message = if is_lone_placeholder(tail) { "" } else { tail };

    let kinds = ds.get("kinds").ok_or(())?;
    let entry = kinds.get(&kind).or_else(|| kinds.get("default")).ok_or(())?;
    let color = entry.get("color").and_then(|c| c.as_i64()).unwrap_or(9_807_270);
    let title_tmpl = entry
        .get("title")
        .and_then(|t| t.as_str())
        .unwrap_or("💬 {kind}");
    let title = cap(&title_tmpl.replace("{kind}", &kind), 256);

    let mut embed = serde_json::Map::new();
    embed.insert("title".into(), json!(title));
    embed.insert("color".into(), json!(color));
    if !message.is_empty() {
        embed.insert("description".into(), json!(cap(message, 4096)));
    }
    if let Some((_, repo)) = present.iter().find(|(k, _)| k == "repo") {
        embed.insert("author".into(), json!({ "name": cap(repo, 256) }));
    }
    if let Some((_, url)) = present.iter().find(|(k, _)| k == "url") {
        if url.starts_with("http://") || url.starts_with("https://") {
            embed.insert("url".into(), json!(url));
        }
    }

    let mut fields = Vec::new();
    for (key, label) in [("repo", "Repo"), ("branch", "Branch"), ("actor", "Actor"), ("status", "Status")] {
        if let Some((_, val)) = present.iter().find(|(k, _)| k == key) {
            fields.push(json!({ "name": label, "value": cap(val, 1024), "inline": true }));
        }
    }
    if fields.len() > 25 {
        fields.truncate(25);
    }
    if !fields.is_empty() {
        embed.insert("fields".into(), json!(fields));
    }

    let now_utc = chrono::Utc::now();
    let berlin = now_utc.with_timezone(&chrono_tz::Europe::Berlin);
    let tool = kind.split('.').next().unwrap_or("gjc");
    let footer = format!("GJC · {} · {} Berlin", tool, berlin.format("%H:%M"));
    embed.insert("footer".into(), json!({ "text": cap(&footer, 2048) }));
    embed.insert("timestamp".into(), json!(now_utc.to_rfc3339()));

    let mut e = Value::Object(embed);
    enforce_total(&mut e, 6000);
    Ok((e, kind))
}

fn is_placeholder(val: &str) -> bool {
    val.len() >= 2 && val.starts_with('{') && val.ends_with('}')
}

/// True for a string that is exactly one unexpanded `{identifier}` placeholder
/// (no surrounding text, no spaces) — i.e. a template token clawhip left
/// unsubstituted because the field was absent.
fn is_lone_placeholder(s: &str) -> bool {
    let s = s.trim();
    let inner = match s.strip_prefix('{').and_then(|s| s.strip_suffix('}')) {
        Some(i) => i,
        None => return false,
    };
    !inner.is_empty() && inner.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Strip all protocol artifacts and return only the human-readable remainder.
fn clean_degrade(content: &str) -> String {
    let rest = content.strip_prefix(MAGIC).unwrap_or(content);
    if let Some(i) = rest.find(" :: ") {
        let tail = &rest[i + 4..];
        let t = if is_lone_placeholder(tail) { "" } else { tail };
        if !t.trim().is_empty() {
            return t.to_string();
        }
    }
    // No usable tail: drop leading key=value tokens, keep human words.
    let mut words: Vec<&str> = Vec::new();
    let mut dropping = true;
    for tok in rest.split(' ') {
        if dropping && tok.contains('=') {
            continue;
        }
        dropping = false;
        if !tok.is_empty() {
            words.push(tok);
        }
    }
    let s = words.join(" ").trim().to_string();
    if s.is_empty() {
        "(notification)".to_string()
    } else {
        s
    }
}

fn cap(s: &str, n: usize) -> String {
    let count = s.chars().count();
    if count <= n {
        s.to_string()
    } else {
        let take = n.saturating_sub(1).max(1);
        let mut out: String = s.chars().take(take).collect();
        out.push('…');
        out
    }
}

fn embed_text_len(embed: &Value) -> usize {
    let mut total = 0;
    let sget = |k: &str| embed.get(k).and_then(|v| v.as_str()).map(|s| s.chars().count()).unwrap_or(0);
    total += sget("title");
    total += sget("description");
    if let Some(f) = embed.get("footer").and_then(|f| f.get("text")).and_then(|t| t.as_str()) {
        total += f.chars().count();
    }
    if let Some(a) = embed.get("author").and_then(|a| a.get("name")).and_then(|t| t.as_str()) {
        total += a.chars().count();
    }
    if let Some(arr) = embed.get("fields").and_then(|f| f.as_array()) {
        for field in arr {
            total += field.get("name").and_then(|v| v.as_str()).map(|s| s.chars().count()).unwrap_or(0);
            total += field.get("value").and_then(|v| v.as_str()).map(|s| s.chars().count()).unwrap_or(0);
        }
    }
    total
}

/// Keep the embed under Discord's 6000-char aggregate cap: truncate the description
/// first, then drop fields if the fixed overhead alone still exceeds the cap.
fn enforce_total(embed: &mut Value, max: usize) {
    if embed_text_len(embed) <= max {
        return;
    }
    let desc_len = embed
        .get("description")
        .and_then(|d| d.as_str())
        .map(|s| s.chars().count())
        .unwrap_or(0);
    let overhead = embed_text_len(embed).saturating_sub(desc_len);

    if overhead >= max {
        if let Some(o) = embed.as_object_mut() {
            o.remove("fields");
        }
    }
    let desc_len2 = embed
        .get("description")
        .and_then(|d| d.as_str())
        .map(|s| s.chars().count())
        .unwrap_or(0);
    let overhead2 = embed_text_len(embed).saturating_sub(desc_len2);
    let allowed = max.saturating_sub(overhead2).max(1);
    if let Some(desc) = embed.get("description").and_then(|d| d.as_str()) {
        if desc.chars().count() > allowed {
            let capped = cap(desc, allowed);
            embed["description"] = json!(capped);
        }
    }
}

/// Metadata-only logging. NEVER receives headers or bodies.
fn log_meta(event: &str, msg: &str) {
    println!("gjc-relay [{event}] {msg}");
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn cap_leaves_short_and_truncates_long_on_char_boundary() {
        assert_eq!(cap("hello", 10), "hello");
        assert_eq!(cap("hello", 5), "hello");
        assert_eq!(cap("hello world", 5), "hell…");
        // multi-byte: must not panic or split a codepoint
        let s = "héllo wörld ✅✅✅";
        let c = cap(s, 4);
        assert_eq!(c.chars().count(), 4);
        assert!(c.ends_with('…'));
    }

    #[test]
    fn placeholder_detection() {
        assert!(is_placeholder("{branch}"));
        assert!(!is_placeholder("main"));
        assert!(is_lone_placeholder("{summary}"));
        assert!(is_lone_placeholder("  {message}  "));
        assert!(!is_lone_placeholder("{a} {b}"));
        assert!(!is_lone_placeholder("PR #{number} merged"));
        assert!(!is_lone_placeholder("{}"));
    }

    #[test]
    fn channel_of_extracts_id() {
        assert_eq!(channel_of("/api/v10/channels/123/messages"), Some("123"));
        assert_eq!(channel_of("/api/v10/channels/123/messages?wait=true"), Some("123"));
        assert_eq!(channel_of("/api/v10/gateway"), None);
    }

    #[test]
    fn valid_envelope_builds_embed_with_fields_and_taxonomy() {
        let (e, kind) = build_embed(
            "GJCEMBED1 kind=agent.started actor=gjc-run repo=engels74/zondarr :: picked up issue #42",
            &ds(),
        )
        .unwrap();
        assert_eq!(kind, "agent.started");
        assert_eq!(e["title"], "🚀 Agent started");
        assert_eq!(e["color"], 5793266);
        assert_eq!(e["description"], "picked up issue #42");
        let names: Vec<&str> = e["fields"].as_array().unwrap().iter().map(|f| f["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"Repo") && names.contains(&"Actor"));
        assert_eq!(e["author"]["name"], "engels74/zondarr");
        assert!(e["footer"]["text"].as_str().unwrap().contains("Berlin"));
    }

    #[test]
    fn absent_placeholder_field_is_omitted_and_lone_tail_is_empty() {
        // repo left as literal {project}, tail left as literal {summary}
        let (e, _) = build_embed("GJCEMBED1 kind=agent.started actor=gjc-run repo={project} :: {summary}", &ds()).unwrap();
        assert!(e.get("description").is_none(), "lone-placeholder tail must yield no description");
        let names: Vec<&str> = e["fields"].as_array().unwrap().iter().map(|f| f["name"].as_str().unwrap()).collect();
        assert!(!names.contains(&"Repo"), "absent repo must be omitted");
        assert!(names.contains(&"Actor"));
    }

    #[test]
    fn tail_preserves_quotes_backslashes_newlines() {
        let msg = "build \"broke\": C:\\tmp\\x\nassert a==\"b\"";
        let (e, _) = build_embed(&format!("GJCEMBED1 kind=agent.started :: {msg}"), &ds()).unwrap();
        let d = e["description"].as_str().unwrap();
        assert!(d.contains('"') && d.contains('\\') && d.contains('\n'));
    }

    #[test]
    fn unknown_kind_falls_back_to_default() {
        let (e, _) = build_embed("GJCEMBED1 kind=totally.unknown :: hi", &ds()).unwrap();
        assert_eq!(e["title"], "💬 totally.unknown");
        assert_eq!(e["color"], 9807270);
    }

    #[test]
    fn url_with_query_string_is_accepted_not_degraded() {
        let (e, _) = build_embed(
            "GJCEMBED1 kind=github.pr-status-changed url=https://github.com/o/r/pull/5?diff=split :: PR #5",
            &ds(),
        )
        .unwrap();
        assert_eq!(e["url"], "https://github.com/o/r/pull/5?diff=split");
    }

    #[test]
    fn malformed_head_returns_err() {
        // bare token (no '=')
        assert!(build_embed("GJCEMBED1 kindagent.started :: x", &ds()).is_err());
        // unknown key
        assert!(build_embed("GJCEMBED1 bogus=y :: x", &ds()).is_err());
        // space-bearing value would already be a separate bare token -> Err
        assert!(build_embed("GJCEMBED1 repo=a b :: x", &ds()).is_err());
    }

    #[test]
    fn clean_degrade_strips_all_protocol_artifacts() {
        let out = clean_degrade("GJCEMBED1 kindagent.failed :: degrade me cleanly");
        assert_eq!(out, "degrade me cleanly");
        assert!(!out.contains("GJCEMBED1") && !out.contains("::") && !out.contains('='));
        // no usable tail -> drop leading key=value tokens, keep human words
        let out2 = clean_degrade("GJCEMBED1 repo=x/y status=open something happened");
        assert!(!out2.contains("GJCEMBED1") && !out2.contains('=') && out2.contains("something happened"));
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
        assert_eq!(v["message_reference"]["message_id"], "9", "unknown fields preserved");
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

    #[test]
    fn enforce_total_bounds_aggregate_to_6000() {
        let big = "X".repeat(9000);
        let (e, _) = build_embed(&format!("GJCEMBED1 kind=agent.started :: {big}"), &ds()).unwrap();
        assert!(embed_text_len(&e) <= 6000);
        assert!(e["description"].as_str().unwrap().chars().count() <= 4096);
    }
}
