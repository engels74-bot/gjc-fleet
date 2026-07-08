//! In-memory work-item model for the managed notification path (v2).
//!
//! A [`State`] tracks live work items (issues / PRs) keyed by `owner/repo#number`
//! plus a short-lived dedup ledger of event fingerprints. It is a plain data
//! structure: no I/O, no locking, no auth material. Durable snapshotting lives in
//! `store.rs`; delivery wiring arrives in Round 2.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Snapshot schema version. A mismatch on load triggers quarantine (see store.rs).
pub(crate) const STATE_VERSION: u32 = 2;

/// Work items untouched for longer than this are pruned. Conservative on purpose
/// (a stale summary is cheap; a wrongly-dropped anchor loses edit continuity).
pub(crate) const ITEM_TTL_SECS: i64 = 30 * 24 * 60 * 60; // 30 days

/// Dedup fingerprints expire after this window: a repeat of the same event
/// beyond it is treated as fresh (e.g. a genuinely re-run CI job days later).
pub(crate) const DEDUP_TTL_SECS: i64 = 7 * 24 * 60 * 60; // 7 days

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ItemType {
    Issue,
    Pr,
}

/// CI status facet: the latest observed check-run summary for the item.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct CiFacet {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) passed: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) failed: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) total: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) sha: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) run_url: Option<String>,
}

/// Review facet: the latest PR review verdict.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ReviewFacet {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) reviewer: Option<String>,
}

/// Pipeline facet: the latest automation-pipeline stage/status.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PipelineFacet {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) stage: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) status: Option<String>,
}

/// The set of facets a work item can accrue over its lifetime.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Facets {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) ci: Option<CiFacet>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) review: Option<ReviewFacet>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) pipeline: Option<PipelineFacet>,
}

/// One tracked issue or PR: the anchor summary message, optional thread, and the
/// accumulated facet/stage state. NEVER contains any auth token.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct WorkItem {
    pub(crate) key: String,
    pub(crate) channel_id: String,
    pub(crate) item_type: ItemType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) summary_message_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) thread_id: Option<String>,
    #[serde(default)]
    pub(crate) thread_disabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) stage: Option<String>,
    #[serde(default)]
    pub(crate) facets: Facets,
    #[serde(default)]
    pub(crate) terminal: bool,
    pub(crate) created_at: i64,
    pub(crate) last_event_at: i64,
}

impl WorkItem {
    /// Build a fresh work item first seen at `now`.
    pub(crate) fn new(key: String, channel_id: String, item_type: ItemType, now: i64) -> WorkItem {
        WorkItem {
            key,
            channel_id,
            item_type,
            title: None,
            summary_message_id: None,
            thread_id: None,
            thread_disabled: false,
            stage: None,
            facets: Facets::default(),
            terminal: false,
            created_at: now,
            last_event_at: now,
        }
    }
}

/// A partial update merged into an existing [`WorkItem`]. Only `Some` fields are
/// applied; facets replace the matching facet slot when present.
#[derive(Clone, Debug, Default)]
pub(crate) struct WorkItemUpdate {
    pub(crate) title: Option<String>,
    pub(crate) stage: Option<String>,
    pub(crate) summary_message_id: Option<String>,
    pub(crate) thread_id: Option<String>,
    pub(crate) ci: Option<CiFacet>,
    pub(crate) review: Option<ReviewFacet>,
    pub(crate) pipeline: Option<PipelineFacet>,
}

/// The complete durable state: schema version, live items, and the dedup ledger.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct State {
    pub(crate) version: u32,
    #[serde(default)]
    pub(crate) items: HashMap<String, WorkItem>,
    #[serde(default)]
    pub(crate) dedup: HashMap<String, i64>,
}

impl Default for State {
    fn default() -> State {
        State {
            version: STATE_VERSION,
            items: HashMap::new(),
            dedup: HashMap::new(),
        }
    }
}

/// Canonical work-item key `owner/repo#number`.
pub(crate) fn item_key(repo: &str, number: &str) -> String {
    format!("{repo}#{number}")
}

impl State {
    pub(crate) fn new() -> State {
        State::default()
    }

    /// Insert a newly-seen work item (overwrites any existing entry for its key).
    pub(crate) fn learn(&mut self, item: WorkItem) {
        self.items.insert(item.key.clone(), item);
    }

    /// Merge an update into an existing item, refreshing `last_event_at`.
    /// Returns false if the key is unknown.
    pub(crate) fn update(&mut self, key: &str, upd: WorkItemUpdate, now: i64) -> bool {
        let Some(item) = self.items.get_mut(key) else {
            return false;
        };
        if upd.title.is_some() {
            item.title = upd.title;
        }
        if upd.stage.is_some() {
            item.stage = upd.stage;
        }
        if upd.summary_message_id.is_some() {
            item.summary_message_id = upd.summary_message_id;
        }
        if upd.thread_id.is_some() {
            item.thread_id = upd.thread_id;
        }
        if upd.ci.is_some() {
            item.facets.ci = upd.ci;
        }
        if upd.review.is_some() {
            item.facets.review = upd.review;
        }
        if upd.pipeline.is_some() {
            item.facets.pipeline = upd.pipeline;
        }
        item.last_event_at = now;
        true
    }

    /// Mark an item terminal (merged/closed). Returns false if unknown.
    pub(crate) fn mark_terminal(&mut self, key: &str, now: i64) -> bool {
        let Some(item) = self.items.get_mut(key) else {
            return false;
        };
        item.terminal = true;
        item.last_event_at = now;
        true
    }

    /// Drop items whose `last_event_at` is older than [`ITEM_TTL_SECS`].
    pub(crate) fn prune(&mut self, now: i64) {
        self.items
            .retain(|_, it| now - it.last_event_at < ITEM_TTL_SECS);
    }

    /// Drop dedup fingerprints older than [`DEDUP_TTL_SECS`].
    pub(crate) fn prune_dedup(&mut self, now: i64) {
        self.dedup.retain(|_, &mut ts| now - ts < DEDUP_TTL_SECS);
    }

    /// Check-and-insert a dedup fingerprint. Returns true when the event is fresh
    /// (not seen within [`DEDUP_TTL_SECS`]) and records it; false on a duplicate.
    /// An expired prior sighting counts as fresh and is refreshed.
    pub(crate) fn dedup_check_and_insert(&mut self, fp: String, now: i64) -> bool {
        if let Some(&ts) = self.dedup.get(&fp) {
            if now - ts < DEDUP_TTL_SECS {
                return false;
            }
        }
        self.dedup.insert(fp, now);
        true
    }
}

// --- dedup fingerprint helpers ---

/// CI fingerprint: `ci|repo|number-or-branch|sha|run_id|status`.
pub(crate) fn ci_fingerprint(
    repo: &str,
    number_or_branch: &str,
    sha: &str,
    run_id: &str,
    status: &str,
) -> String {
    format!("ci|{repo}|{number_or_branch}|{sha}|{run_id}|{status}")
}

/// Issue fingerprint: `iss|repo|number|kind`.
pub(crate) fn issue_fingerprint(repo: &str, number: &str, kind: &str) -> String {
    format!("iss|{repo}|{number}|{kind}")
}

/// PR fingerprint: `pr|repo|number|new_status`.
pub(crate) fn pr_fingerprint(repo: &str, number: &str, new_status: &str) -> String {
    format!("pr|{repo}|{number}|{new_status}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn learn_update_and_terminal() {
        let mut st = State::new();
        assert_eq!(st.version, STATE_VERSION);

        let key = item_key("engels74/zondarr", "42");
        st.learn(WorkItem::new(
            key.clone(),
            "chan1".to_string(),
            ItemType::Issue,
            1000,
        ));
        assert!(st.items.contains_key(&key));

        let ok = st.update(
            &key,
            WorkItemUpdate {
                title: Some("Fix login".to_string()),
                stage: Some("triage".to_string()),
                ci: Some(CiFacet {
                    status: Some("success".to_string()),
                    passed: Some(10),
                    total: Some(10),
                    ..CiFacet::default()
                }),
                ..WorkItemUpdate::default()
            },
            1100,
        );
        assert!(ok);
        let it = &st.items[&key];
        assert_eq!(it.title.as_deref(), Some("Fix login"));
        assert_eq!(it.stage.as_deref(), Some("triage"));
        assert_eq!(it.facets.ci.as_ref().unwrap().passed, Some(10));
        assert_eq!(it.last_event_at, 1100);

        assert!(st.mark_terminal(&key, 1200));
        assert!(st.items[&key].terminal);

        // unknown key
        assert!(!st.update("nope#1", WorkItemUpdate::default(), 1300));
        assert!(!st.mark_terminal("nope#1", 1300));
    }

    #[test]
    fn prune_drops_stale_items() {
        let mut st = State::new();
        st.learn(WorkItem::new(
            "r#1".to_string(),
            "c".to_string(),
            ItemType::Pr,
            0,
        ));
        st.learn(WorkItem::new(
            "r#2".to_string(),
            "c".to_string(),
            ItemType::Pr,
            ITEM_TTL_SECS, // recent
        ));
        // now well past the first item's TTL but within the second's
        st.prune(ITEM_TTL_SECS + 10);
        assert!(!st.items.contains_key("r#1"));
        assert!(st.items.contains_key("r#2"));
    }

    #[test]
    fn fingerprint_formats() {
        assert_eq!(
            ci_fingerprint("o/r", "42", "abc", "99", "success"),
            "ci|o/r|42|abc|99|success"
        );
        // CI keyed by branch when there is no number (branch push)
        assert_eq!(
            ci_fingerprint("o/r", "main", "abc", "99", "failure"),
            "ci|o/r|main|abc|99|failure"
        );
        assert_eq!(issue_fingerprint("o/r", "7", "opened"), "iss|o/r|7|opened");
        assert_eq!(pr_fingerprint("o/r", "5", "merged"), "pr|o/r|5|merged");
    }

    #[test]
    fn dedup_hit_within_ttl_miss_after() {
        let mut st = State::new();
        let fp = ci_fingerprint("o/r", "42", "abc", "99", "success");

        // fresh insert
        assert!(st.dedup_check_and_insert(fp.clone(), 1000));
        // duplicate within TTL -> false
        assert!(!st.dedup_check_and_insert(fp.clone(), 1000 + DEDUP_TTL_SECS - 1));
        // beyond TTL -> fresh again
        assert!(st.dedup_check_and_insert(fp.clone(), 1000 + DEDUP_TTL_SECS + 1));

        // a different fingerprint is always fresh
        let other = pr_fingerprint("o/r", "5", "open");
        assert!(st.dedup_check_and_insert(other, 1000));
    }

    #[test]
    fn prune_dedup_drops_expired() {
        let mut st = State::new();
        st.dedup.insert("old".to_string(), 0);
        st.dedup.insert("new".to_string(), DEDUP_TTL_SECS);
        st.prune_dedup(DEDUP_TTL_SECS + 10);
        assert!(!st.dedup.contains_key("old"));
        assert!(st.dedup.contains_key("new"));
    }
}
