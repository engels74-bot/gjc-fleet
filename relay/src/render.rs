//! Embed rendering: turn a GJCEMBED1 envelope into a Discord embed and enforce
//! Discord's aggregate character caps.

use serde_json::{json, Value};

use crate::envelope::{cap, is_lone_placeholder, is_placeholder, Envelope, ALLOWED_KEYS, MAGIC};

/// Build a Discord embed from a GJCEMBED1 envelope. Err(()) => route to clean degrade.
pub(crate) fn build_embed(content: &str, ds: &Value) -> Result<(Value, String), ()> {
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
                    || matches!(
                        c,
                        '.' | '_'
                            | ':'
                            | '/'
                            | '-'
                            | '?'
                            | '='
                            | '&'
                            | '#'
                            | '%'
                            | '~'
                            | '+'
                            | ','
                            | '@'
                    )
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
    let entry = kinds
        .get(&kind)
        .or_else(|| kinds.get("default"))
        .ok_or(())?;
    let color = entry
        .get("color")
        .and_then(|c| c.as_i64())
        .unwrap_or(9_807_270);
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
    for (key, label) in [
        ("repo", "Repo"),
        ("branch", "Branch"),
        ("actor", "Actor"),
        ("status", "Status"),
    ] {
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

/// Build a Discord embed directly from a parsed [`Envelope`] for the managed
/// work-item path (Round 2). Deliberately a separate function from
/// `build_embed` (see envelope.rs's module doc) — it adds the CI/work-item
/// fields the v1 taxonomy never carries, and never routes to clean-degrade
/// (the caller already committed to a managed surface by the time this runs).
pub(crate) fn build_embed_from_envelope(env: &Envelope, ds: &Value) -> Value {
    let kinds = ds.get("kinds");
    let entry = kinds.and_then(|k| k.get(&env.kind).or_else(|| k.get("default")));
    let color = entry
        .and_then(|e| e.get("color"))
        .and_then(|c| c.as_i64())
        .unwrap_or(9_807_270);
    let title_tmpl = entry
        .and_then(|e| e.get("title"))
        .and_then(|t| t.as_str())
        .unwrap_or("💬 {kind}");
    let base_title = title_tmpl.replace("{kind}", &env.kind);
    let title = match &env.title {
        Some(t) if !t.is_empty() => cap(&format!("{base_title}: {t}"), 256),
        _ => cap(&base_title, 256),
    };

    let mut embed = serde_json::Map::new();
    embed.insert("title".into(), json!(title));
    embed.insert("color".into(), json!(color));
    if !env.message.is_empty() {
        embed.insert("description".into(), json!(cap(&env.message, 4096)));
    }
    if !env.repo.is_empty() {
        embed.insert("author".into(), json!({ "name": cap(&env.repo, 256) }));
    }
    if env.url.starts_with("http://") || env.url.starts_with("https://") {
        embed.insert("url".into(), json!(env.url));
    }

    let mut fields = Vec::new();
    for (val, label) in [
        (&env.repo, "Repo"),
        (&env.branch, "Branch"),
        (&env.actor, "Actor"),
        (&env.status, "Status"),
        (&env.stage, "Stage"),
        (&env.number, "Number"),
        (&env.sha, "SHA"),
    ] {
        if !val.is_empty() {
            fields.push(json!({ "name": label, "value": cap(val, 1024), "inline": true }));
        }
    }
    if !(env.passed.is_empty() && env.failed.is_empty() && env.total.is_empty()) {
        let summary = format!(
            "{}/{} passed ({} failed)",
            if env.passed.is_empty() { "?" } else { &env.passed },
            if env.total.is_empty() { "?" } else { &env.total },
            if env.failed.is_empty() { "?" } else { &env.failed },
        );
        fields.push(json!({ "name": "Tests", "value": cap(&summary, 1024), "inline": true }));
    }
    if fields.len() > 25 {
        fields.truncate(25);
    }
    if !fields.is_empty() {
        embed.insert("fields".into(), json!(fields));
    }

    let now_utc = chrono::Utc::now();
    let berlin = now_utc.with_timezone(&chrono_tz::Europe::Berlin);
    let tool = env.kind.split('.').next().unwrap_or("gjc");
    let footer = format!("GJC · {} · {} Berlin", tool, berlin.format("%H:%M"));
    embed.insert("footer".into(), json!({ "text": cap(&footer, 2048) }));
    embed.insert("timestamp".into(), json!(now_utc.to_rfc3339()));

    let mut e = Value::Object(embed);
    enforce_total(&mut e, 6000);
    e
}

pub(crate) fn embed_text_len(embed: &Value) -> usize {
    let mut total = 0;
    let sget = |k: &str| {
        embed
            .get(k)
            .and_then(|v| v.as_str())
            .map(|s| s.chars().count())
            .unwrap_or(0)
    };
    total += sget("title");
    total += sget("description");
    if let Some(f) = embed
        .get("footer")
        .and_then(|f| f.get("text"))
        .and_then(|t| t.as_str())
    {
        total += f.chars().count();
    }
    if let Some(a) = embed
        .get("author")
        .and_then(|a| a.get("name"))
        .and_then(|t| t.as_str())
    {
        total += a.chars().count();
    }
    if let Some(arr) = embed.get("fields").and_then(|f| f.as_array()) {
        for field in arr {
            total += field
                .get("name")
                .and_then(|v| v.as_str())
                .map(|s| s.chars().count())
                .unwrap_or(0);
            total += field
                .get("value")
                .and_then(|v| v.as_str())
                .map(|s| s.chars().count())
                .unwrap_or(0);
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
        let names: Vec<&str> = e["fields"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"Repo") && names.contains(&"Actor"));
        assert_eq!(e["author"]["name"], "engels74/zondarr");
        assert!(e["footer"]["text"].as_str().unwrap().contains("Berlin"));
    }

    #[test]
    fn absent_placeholder_field_is_omitted_and_lone_tail_is_empty() {
        // repo left as literal {project}, tail left as literal {summary}
        let (e, _) = build_embed(
            "GJCEMBED1 kind=agent.started actor=gjc-run repo={project} :: {summary}",
            &ds(),
        )
        .unwrap();
        assert!(
            e.get("description").is_none(),
            "lone-placeholder tail must yield no description"
        );
        let names: Vec<&str> = e["fields"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f["name"].as_str().unwrap())
            .collect();
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
    fn enforce_total_bounds_aggregate_to_6000() {
        let big = "X".repeat(9000);
        let (e, _) = build_embed(&format!("GJCEMBED1 kind=agent.started :: {big}"), &ds()).unwrap();
        assert!(embed_text_len(&e) <= 6000);
        assert!(e["description"].as_str().unwrap().chars().count() <= 4096);
    }

    #[test]
    fn build_embed_from_envelope_includes_ci_fields() {
        let env = Envelope {
            kind: "github.ci-failed".to_string(),
            repo: "engels74/zondarr".to_string(),
            status: "failure".to_string(),
            branch: "main".to_string(),
            number: "42".to_string(),
            sha: "abc123".to_string(),
            passed: "8".to_string(),
            failed: "2".to_string(),
            total: "10".to_string(),
            title: Some("Fix the flaky test".to_string()),
            message: "CI failed on main".to_string(),
            ..Envelope::default()
        };
        let e = build_embed_from_envelope(&env, &ds());
        assert!(e["title"].as_str().unwrap().contains("Fix the flaky test"));
        assert_eq!(e["description"], "CI failed on main");
        let names: Vec<&str> = e["fields"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"Tests"));
        assert!(names.contains(&"SHA"));
        assert!(names.contains(&"Number"));
        let tests_val = e["fields"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["name"] == "Tests")
            .unwrap()["value"]
            .as_str()
            .unwrap()
            .to_string();
        assert_eq!(tests_val, "8/10 passed (2 failed)");
    }

    #[test]
    fn build_embed_from_envelope_no_title_falls_back_to_kind() {
        let env = Envelope {
            kind: "agent.started".to_string(),
            ..Envelope::default()
        };
        let e = build_embed_from_envelope(&env, &ds());
        assert_eq!(e["title"], "🚀 Agent started");
    }
}
