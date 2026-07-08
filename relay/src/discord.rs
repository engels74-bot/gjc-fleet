//! Discord REST surface for the managed work-item path.
//!
//! [`DiscordApi`] is the seam the Round-2 flush loop delivers through; [`UreqDiscord`]
//! is the production implementation and [`MockDiscord`] the record/replay double used
//! by unit tests (and reused by the Round-2 flush tests).
//!
//! SECURITY: the bearer token is passed per call and is NEVER stored in a
//! serializable struct nor logged.

use std::collections::VecDeque;
use std::sync::Mutex;

use serde_json::{json, Value};

/// A Discord REST failure, shaped for the caller's backoff logic.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum DiscordErr {
    /// 429: honour `retry_after` seconds before retrying.
    RateLimited { retry_after: f64 },
    /// Any other non-2xx status.
    Status(u16),
    /// Connection / I/O failure with no HTTP status.
    Transport,
}

/// The Discord operations the managed path needs. Each takes the bearer token as
/// an argument; implementations must never persist or log it.
pub(crate) trait DiscordApi {
    /// POST an embed to a channel; returns the new message id.
    fn post_message(&self, cid: &str, token: &str, embed: &Value) -> Result<String, DiscordErr>;
    /// PATCH an existing message's embed.
    fn edit_message(
        &self,
        cid: &str,
        mid: &str,
        token: &str,
        embed: &Value,
    ) -> Result<(), DiscordErr>;
    /// Create a thread from a message; returns the thread id.
    fn create_thread_from_message(
        &self,
        cid: &str,
        mid: &str,
        token: &str,
        name: &str,
        auto_archive_minutes: u32,
    ) -> Result<String, DiscordErr>;
    /// POST an embed into a thread; returns the new message id.
    fn post_to_thread(
        &self,
        thread_id: &str,
        token: &str,
        embed: &Value,
    ) -> Result<String, DiscordErr>;
    /// GET the `limit` most recent messages in a channel (read-back
    /// reconciliation, A2a step 3a — new-message-class ops only).
    fn list_recent_messages(
        &self,
        cid: &str,
        token: &str,
        limit: u32,
    ) -> Result<Vec<Value>, DiscordErr>;
}

/// Parse Discord's 429 `retry_after` (seconds) from a JSON body.
pub(crate) fn parse_retry_after(body: &str) -> Option<f64> {
    serde_json::from_str::<Value>(body)
        .ok()?
        .get("retry_after")?
        .as_f64()
}

/// Production [`DiscordApi`] backed by a ureq agent talking to the Discord REST API.
pub(crate) struct UreqDiscord {
    agent: ureq::Agent,
    /// Host base, e.g. `https://discord.com`. Paths carry `/api/v10/...`.
    upstream_base: String,
}

impl UreqDiscord {
    pub(crate) fn new(agent: ureq::Agent, upstream_base: String) -> UreqDiscord {
        UreqDiscord {
            agent,
            upstream_base,
        }
    }

    fn channel_messages_url(&self, cid: &str) -> String {
        format!("{}/api/v10/channels/{cid}/messages", self.upstream_base)
    }
}

/// Map a ureq error into a [`DiscordErr`], parsing `retry_after` from a 429 body.
fn map_ureq_err(e: ureq::Error) -> DiscordErr {
    match e {
        ureq::Error::Status(429, resp) => {
            let body = resp.into_string().unwrap_or_default();
            DiscordErr::RateLimited {
                retry_after: parse_retry_after(&body).unwrap_or(1.0),
            }
        }
        ureq::Error::Status(code, _) => DiscordErr::Status(code),
        ureq::Error::Transport(_) => DiscordErr::Transport,
    }
}

/// Send a JSON body via ureq (the crate is built without the `json` feature, so
/// serialize + set Content-Type by hand).
fn send_json(req: ureq::Request, body: &Value) -> Result<ureq::Response, DiscordErr> {
    let s = serde_json::to_string(body).map_err(|_| DiscordErr::Transport)?;
    req.set("Content-Type", "application/json")
        .send_string(&s)
        .map_err(map_ureq_err)
}

/// Extract the `id` string from a Discord message/thread response.
fn extract_id(resp: ureq::Response) -> Result<String, DiscordErr> {
    let body = resp.into_string().map_err(|_| DiscordErr::Transport)?;
    serde_json::from_str::<Value>(&body)
        .ok()
        .and_then(|v| v.get("id").and_then(|i| i.as_str()).map(|s| s.to_string()))
        .ok_or(DiscordErr::Transport)
}

impl DiscordApi for UreqDiscord {
    fn post_message(&self, cid: &str, token: &str, embed: &Value) -> Result<String, DiscordErr> {
        let url = self.channel_messages_url(cid);
        let req = self.agent.post(&url).set("Authorization", token);
        let resp = send_json(req, &json!({ "embeds": [embed] }))?;
        extract_id(resp)
    }

    fn edit_message(
        &self,
        cid: &str,
        mid: &str,
        token: &str,
        embed: &Value,
    ) -> Result<(), DiscordErr> {
        let url = format!("{}/{mid}", self.channel_messages_url(cid));
        let req = self.agent.request("PATCH", &url).set("Authorization", token);
        send_json(req, &json!({ "embeds": [embed] }))?;
        Ok(())
    }

    fn create_thread_from_message(
        &self,
        cid: &str,
        mid: &str,
        token: &str,
        name: &str,
        auto_archive_minutes: u32,
    ) -> Result<String, DiscordErr> {
        let url = format!("{}/{mid}/threads", self.channel_messages_url(cid));
        let req = self.agent.post(&url).set("Authorization", token);
        let resp = send_json(
            req,
            &json!({ "name": name, "auto_archive_duration": auto_archive_minutes }),
        )?;
        extract_id(resp)
    }

    fn post_to_thread(
        &self,
        thread_id: &str,
        token: &str,
        embed: &Value,
    ) -> Result<String, DiscordErr> {
        // A thread is itself a channel for message posting.
        let url = self.channel_messages_url(thread_id);
        let req = self.agent.post(&url).set("Authorization", token);
        let resp = send_json(req, &json!({ "embeds": [embed] }))?;
        extract_id(resp)
    }

    fn list_recent_messages(
        &self,
        cid: &str,
        token: &str,
        limit: u32,
    ) -> Result<Vec<Value>, DiscordErr> {
        let url = format!("{}?limit={limit}", self.channel_messages_url(cid));
        let resp = self
            .agent
            .get(&url)
            .set("Authorization", token)
            .call()
            .map_err(map_ureq_err)?;
        let body = resp.into_string().map_err(|_| DiscordErr::Transport)?;
        let v: Value = serde_json::from_str(&body).map_err(|_| DiscordErr::Transport)?;
        v.as_array().cloned().ok_or(DiscordErr::Transport)
    }
}

/// A recorded call against [`MockDiscord`] (token is intentionally NOT captured).
/// Test-only infrastructure: constructed exclusively by `#[cfg(test)]` code in
/// this and other modules (flush.rs, http.rs), so it is legitimately unused in
/// a non-test build.
#[allow(dead_code)]
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum DiscordCall {
    PostMessage {
        cid: String,
        embed: Value,
    },
    EditMessage {
        cid: String,
        mid: String,
        embed: Value,
    },
    CreateThread {
        cid: String,
        mid: String,
        name: String,
        auto_archive_minutes: u32,
    },
    PostToThread {
        thread_id: String,
        embed: Value,
    },
    ListMessages {
        cid: String,
        limit: u32,
    },
}

/// Record/replay [`DiscordApi`] double. Records every call and returns programmed
/// results; when no result is queued, id-returning calls yield an auto-incrementing
/// `mock-id-<n>` and edits succeed. Thread-safe so Round-2 tests can share it.
/// Test-only: real delivery always goes through [`UreqDiscord`].
#[allow(dead_code)]
pub(crate) struct MockDiscord {
    calls: Mutex<Vec<DiscordCall>>,
    id_results: Mutex<VecDeque<Result<String, DiscordErr>>>,
    edit_results: Mutex<VecDeque<Result<(), DiscordErr>>>,
    list_results: Mutex<VecDeque<Result<Vec<Value>, DiscordErr>>>,
    counter: Mutex<u64>,
}

impl Default for MockDiscord {
    fn default() -> MockDiscord {
        MockDiscord {
            calls: Mutex::new(Vec::new()),
            id_results: Mutex::new(VecDeque::new()),
            edit_results: Mutex::new(VecDeque::new()),
            list_results: Mutex::new(VecDeque::new()),
            counter: Mutex::new(0),
        }
    }
}

#[allow(dead_code)] // test-only double; see the struct's doc comment
impl MockDiscord {
    pub(crate) fn new() -> MockDiscord {
        MockDiscord::default()
    }

    /// Program the next id-returning call (post_message / create_thread / post_to_thread).
    pub(crate) fn push_id_result(&self, r: Result<String, DiscordErr>) {
        self.id_results.lock().unwrap().push_back(r);
    }

    /// Program the next edit_message result.
    pub(crate) fn push_edit_result(&self, r: Result<(), DiscordErr>) {
        self.edit_results.lock().unwrap().push_back(r);
    }

    /// Program the next list_recent_messages result.
    pub(crate) fn push_list_result(&self, r: Result<Vec<Value>, DiscordErr>) {
        self.list_results.lock().unwrap().push_back(r);
    }

    /// Snapshot of all recorded calls in order.
    pub(crate) fn calls(&self) -> Vec<DiscordCall> {
        self.calls.lock().unwrap().clone()
    }

    fn next_id(&self) -> Result<String, DiscordErr> {
        if let Some(r) = self.id_results.lock().unwrap().pop_front() {
            return r;
        }
        let mut c = self.counter.lock().unwrap();
        *c += 1;
        Ok(format!("mock-id-{c}"))
    }

    fn next_edit(&self) -> Result<(), DiscordErr> {
        self.edit_results
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or(Ok(()))
    }
}

impl DiscordApi for MockDiscord {
    fn post_message(&self, cid: &str, _token: &str, embed: &Value) -> Result<String, DiscordErr> {
        self.calls.lock().unwrap().push(DiscordCall::PostMessage {
            cid: cid.to_string(),
            embed: embed.clone(),
        });
        self.next_id()
    }

    fn edit_message(
        &self,
        cid: &str,
        mid: &str,
        _token: &str,
        embed: &Value,
    ) -> Result<(), DiscordErr> {
        self.calls.lock().unwrap().push(DiscordCall::EditMessage {
            cid: cid.to_string(),
            mid: mid.to_string(),
            embed: embed.clone(),
        });
        self.next_edit()
    }

    fn create_thread_from_message(
        &self,
        cid: &str,
        mid: &str,
        _token: &str,
        name: &str,
        auto_archive_minutes: u32,
    ) -> Result<String, DiscordErr> {
        self.calls.lock().unwrap().push(DiscordCall::CreateThread {
            cid: cid.to_string(),
            mid: mid.to_string(),
            name: name.to_string(),
            auto_archive_minutes,
        });
        self.next_id()
    }

    fn post_to_thread(
        &self,
        thread_id: &str,
        _token: &str,
        embed: &Value,
    ) -> Result<String, DiscordErr> {
        self.calls.lock().unwrap().push(DiscordCall::PostToThread {
            thread_id: thread_id.to_string(),
            embed: embed.clone(),
        });
        self.next_id()
    }

    fn list_recent_messages(
        &self,
        cid: &str,
        _token: &str,
        limit: u32,
    ) -> Result<Vec<Value>, DiscordErr> {
        self.calls.lock().unwrap().push(DiscordCall::ListMessages {
            cid: cid.to_string(),
            limit,
        });
        self.list_results
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or(Ok(Vec::new()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mock_records_post_and_returns_programmed_id() {
        let mock = MockDiscord::new();
        mock.push_id_result(Ok("999".to_string()));
        let embed = json!({ "title": "hi" });

        let id = mock.post_message("chan1", "SECRET", &embed).unwrap();
        assert_eq!(id, "999");

        let calls = mock.calls();
        assert_eq!(calls.len(), 1);
        assert_eq!(
            calls[0],
            DiscordCall::PostMessage {
                cid: "chan1".to_string(),
                embed
            }
        );
    }

    #[test]
    fn mock_auto_ids_when_unprogrammed() {
        let mock = MockDiscord::new();
        let e = json!({});
        let a = mock.post_message("c", "t", &e).unwrap();
        let b = mock.create_thread_from_message("c", &a, "t", "name", 1440).unwrap();
        assert_ne!(a, b, "auto ids must be distinct");
        assert!(a.starts_with("mock-id-") && b.starts_with("mock-id-"));
        assert_eq!(mock.calls().len(), 2);
    }

    #[test]
    fn mock_edit_default_and_programmed() {
        let mock = MockDiscord::new();
        // default edit succeeds
        assert!(mock.edit_message("c", "m", "t", &json!({})).is_ok());
        // programmed failure
        mock.push_edit_result(Err(DiscordErr::Status(404)));
        assert_eq!(
            mock.edit_message("c", "m", "t", &json!({})),
            Err(DiscordErr::Status(404))
        );
    }

    #[test]
    fn retry_after_parse_from_429_body() {
        let body = r#"{"message":"rate limited","retry_after":1.5,"global":false}"#;
        assert_eq!(parse_retry_after(body), Some(1.5));
        // integer form
        assert_eq!(parse_retry_after(r#"{"retry_after":2}"#), Some(2.0));
        // missing / malformed
        assert_eq!(parse_retry_after(r#"{"message":"x"}"#), None);
        assert_eq!(parse_retry_after("not json"), None);
    }
}
