//! GJCEMBED1 envelope primitives: the magic prefix, the allowed head keys, and
//! the placeholder / degrade / cap helpers shared across the relay.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;

pub(crate) const MAGIC: &str = "GJCEMBED1 ";

/// The v2 head-key vocabulary (14 keys): the original v1 slots plus the CI /
/// work-item fields introduced in the notification overhaul. Additive — v1
/// traffic never carries the new keys, so v1 rendering is unchanged.
pub(crate) const ALLOWED_KEYS: [&str; 14] = [
    "kind", "repo", "status", "actor", "branch", "url", // v1
    "number", "stage", "sha", "run", "passed", "failed", "total", "t64", // v2
];

/// Digit-bearing v2 keys validated leniently (digits are already inside the
/// slug charset, so this documents intent and keeps parse_envelope explicit).
#[allow(dead_code)] // v2 parse path wired into delivery in Round 2
const DIGIT_KEYS: [&str; 5] = ["number", "passed", "failed", "total", "run"];

/// True for a char inside the strict v1 slug charset (also covers digits).
#[allow(dead_code)] // used by parse_envelope (Round-2 managed path)
fn is_slug_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '/' | '-')
}

/// True for a char inside the base64url-unpadded alphabet.
#[allow(dead_code)] // used by parse_envelope (Round-2 managed path)
fn is_base64url_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '-' | '_')
}

/// Decode an unpadded base64url `t64` value into its UTF-8 title, capped to
/// 256 chars. None on invalid base64 or invalid UTF-8.
#[allow(dead_code)] // consumed by the Round-2 managed path
pub(crate) fn decode_t64(s: &str) -> Option<String> {
    let bytes = URL_SAFE_NO_PAD.decode(s.as_bytes()).ok()?;
    let title = String::from_utf8(bytes).ok()?;
    Some(cap(&title, 256))
}

/// A fully parsed GJCEMBED1 envelope for the managed work-item path. Absent
/// head slots are empty strings; `title` is the decoded `t64` (or the tail
/// message fallback); `message` is the cleaned tail. build_embed in render.rs
/// keeps its own v1 parsing — this is deliberate, safer duplication.
#[allow(dead_code)] // fields read by the Round-2 managed path
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Envelope {
    pub(crate) kind: String,
    pub(crate) repo: String,
    pub(crate) status: String,
    pub(crate) actor: String,
    pub(crate) branch: String,
    pub(crate) url: String,
    pub(crate) number: String,
    pub(crate) stage: String,
    pub(crate) sha: String,
    pub(crate) run: String,
    pub(crate) passed: String,
    pub(crate) failed: String,
    pub(crate) total: String,
    pub(crate) title: Option<String>,
    pub(crate) message: String,
}

/// Parse a single GJCEMBED1 line into an [`Envelope`]. Err(()) on a malformed
/// head (bare token, unknown key, or charset violation) — the caller then falls
/// back to the v1 degrade path. Absent / placeholder head values are omitted.
#[allow(dead_code)] // consumed by the Round-2 managed path
pub(crate) fn parse_envelope(content: &str) -> Result<Envelope, ()> {
    let rest = content.strip_prefix(MAGIC).ok_or(())?;
    let (head, tail) = match rest.find(" :: ") {
        Some(i) => (&rest[..i], &rest[i + 4..]),
        None => (rest, ""),
    };

    let mut env = Envelope {
        kind: "default".to_string(),
        ..Envelope::default()
    };
    let mut t64_raw: Option<String> = None;

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
        // Charset per key class: `url` is permissive (real URLs), `t64` is the
        // base64url alphabet, digit-bearing and other slots are the slug charset
        // (which already permits digits, so digit keys are validated leniently).
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
        } else if key == "t64" {
            val.chars().all(is_base64url_char)
        } else {
            // Slug charset covers both the v1 slots and the lenient digit keys.
            let _ = DIGIT_KEYS; // documents which keys are the digit-bearing set
            val.chars().all(is_slug_char)
        };
        if !charset_ok {
            return Err(()); // charset violation -> malformed
        }

        match key {
            "kind" => env.kind = val.to_string(),
            "repo" => env.repo = val.to_string(),
            "status" => env.status = val.to_string(),
            "actor" => env.actor = val.to_string(),
            "branch" => env.branch = val.to_string(),
            "url" => env.url = val.to_string(),
            "number" => env.number = val.to_string(),
            "stage" => env.stage = val.to_string(),
            "sha" => env.sha = val.to_string(),
            "run" => env.run = val.to_string(),
            "passed" => env.passed = val.to_string(),
            "failed" => env.failed = val.to_string(),
            "total" => env.total = val.to_string(),
            "t64" => t64_raw = Some(val.to_string()),
            _ => unreachable!("key already checked against ALLOWED_KEYS"),
        }
    }

    // A tail that is a single unexpanded placeholder means "no message".
    let message = if is_lone_placeholder(tail) {
        String::new()
    } else {
        tail.to_string()
    };
    // title = decoded t64 (if present and valid), else the tail message.
    let title = match &t64_raw {
        Some(v) => decode_t64(v).or_else(|| non_empty(&message)),
        None => non_empty(&message),
    };
    env.message = message;
    env.title = title;
    Ok(env)
}

#[allow(dead_code)] // used by parse_envelope (Round-2 managed path)
fn non_empty(s: &str) -> Option<String> {
    if s.trim().is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

pub(crate) fn is_placeholder(val: &str) -> bool {
    val.len() >= 2 && val.starts_with('{') && val.ends_with('}')
}

/// True for a string that is exactly one unexpanded `{identifier}` placeholder
/// (no surrounding text, no spaces) — i.e. a template token clawhip left
/// unsubstituted because the field was absent.
pub(crate) fn is_lone_placeholder(s: &str) -> bool {
    let s = s.trim();
    let inner = match s.strip_prefix('{').and_then(|s| s.strip_suffix('}')) {
        Some(i) => i,
        None => return false,
    };
    !inner.is_empty() && inner.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Strip all protocol artifacts and return only the human-readable remainder.
pub(crate) fn clean_degrade(content: &str) -> String {
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

pub(crate) fn cap(s: &str, n: usize) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;

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
    fn clean_degrade_strips_all_protocol_artifacts() {
        let out = clean_degrade("GJCEMBED1 kindagent.failed :: degrade me cleanly");
        assert_eq!(out, "degrade me cleanly");
        assert!(!out.contains("GJCEMBED1") && !out.contains("::") && !out.contains('='));
        // no usable tail -> drop leading key=value tokens, keep human words
        let out2 = clean_degrade("GJCEMBED1 repo=x/y status=open something happened");
        assert!(
            !out2.contains("GJCEMBED1")
                && !out2.contains('=')
                && out2.contains("something happened")
        );
    }

    #[test]
    fn t64_decode_roundtrip_and_invalid() {
        let title = "Fix the flaky login test ✅";
        let encoded = URL_SAFE_NO_PAD.encode(title.as_bytes());
        assert_eq!(decode_t64(&encoded).as_deref(), Some(title));
        // invalid base64url (padding / illegal char) -> None
        assert!(decode_t64("not base64!!").is_none());
        // valid base64 but invalid UTF-8 -> None (0xff byte)
        let bad = URL_SAFE_NO_PAD.encode([0xff, 0xfe]);
        assert!(decode_t64(&bad).is_none());
    }

    #[test]
    fn t64_decode_caps_to_256_chars() {
        let long = "z".repeat(400);
        let encoded = URL_SAFE_NO_PAD.encode(long.as_bytes());
        let out = decode_t64(&encoded).unwrap();
        assert!(out.chars().count() <= 256);
    }

    #[test]
    fn parse_envelope_full_ci_envelope() {
        let env = parse_envelope(
            "GJCEMBED1 kind=github.ci-passed repo=engels74/zondarr number=42 branch=main \
             sha=abc123 run=99 passed=10 failed=0 total=10 status=success :: CI is green",
        )
        .unwrap();
        assert_eq!(env.kind, "github.ci-passed");
        assert_eq!(env.repo, "engels74/zondarr");
        assert_eq!(env.number, "42");
        assert_eq!(env.branch, "main");
        assert_eq!(env.sha, "abc123");
        assert_eq!(env.run, "99");
        assert_eq!(env.passed, "10");
        assert_eq!(env.failed, "0");
        assert_eq!(env.total, "10");
        assert_eq!(env.status, "success");
        assert_eq!(env.message, "CI is green");
        // no t64 -> title falls back to the tail message
        assert_eq!(env.title.as_deref(), Some("CI is green"));
    }

    #[test]
    fn parse_envelope_prefers_t64_title() {
        let title = "Add retry to the poller";
        let t64 = URL_SAFE_NO_PAD.encode(title.as_bytes());
        let env = parse_envelope(&format!(
            "GJCEMBED1 kind=github.issue-opened number=7 t64={t64} :: tail"
        ))
        .unwrap();
        assert_eq!(env.title.as_deref(), Some(title));
        assert_eq!(env.message, "tail");
        assert_eq!(env.number, "7");
    }

    #[test]
    fn parse_envelope_new_keys_no_longer_degrade() {
        // Every new v2 key is accepted (would previously have been Err).
        let env = parse_envelope(
            "GJCEMBED1 kind=github.ci-failed stage=build number=3 sha=deadbeef \
             run=1 passed=1 failed=2 total=3 :: {summary}",
        )
        .unwrap();
        assert_eq!(env.stage, "build");
        // lone-placeholder tail -> empty message, and no t64 -> no title
        assert_eq!(env.message, "");
        assert!(env.title.is_none());
    }

    #[test]
    fn parse_envelope_rejects_unknown_and_bare() {
        assert!(parse_envelope("GJCEMBED1 bogus=y :: x").is_err());
        assert!(parse_envelope("GJCEMBED1 kindfoo :: x").is_err());
        // not a GJCEMBED1 line at all
        assert!(parse_envelope("plain text").is_err());
    }
}
