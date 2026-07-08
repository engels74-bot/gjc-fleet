//! Two-phase durable operation queue for the managed delivery path (A2a/A3a).
//!
//! Every managed delivery is first durably enqueued as a
//! `<state_dir>/queue/<epoch_ms>-<seq>-<opclass>.json` file (fsynced) BEFORE the
//! caller acks the inbound request (persist-before-ack). Once flush.rs delivers
//! it, a sibling `.committed` marker records the result (also fsynced) and the
//! `.json` is unlinked — closing the crash window between "delivered" and
//! "durably recorded as delivered". Ops that exceed their retry budget are
//! buried into `<state_dir>/dead/` with a journal entry.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::log::log_meta;

/// The four managed-delivery operation kinds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OpClass {
    NewMessage,
    EditSummary,
    ThreadCreate,
    ThreadPost,
}

impl OpClass {
    fn tag(self) -> &'static str {
        match self {
            OpClass::NewMessage => "new",
            OpClass::EditSummary => "editsummary",
            OpClass::ThreadCreate => "threadcreate",
            OpClass::ThreadPost => "threadpost",
        }
    }
}

/// A durable, queued delivery. NEVER carries an auth token — the token is
/// supplied by the flush thread at delivery time from the in-memory TokenCache.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub(crate) struct Op {
    pub(crate) channel_id: String,
    pub(crate) item_key: String,
    pub(crate) kind: String,
    pub(crate) embed: Value,
    pub(crate) fingerprint: String,
    pub(crate) opclass: OpClass,
    /// EditSummary: the message id to PATCH. ThreadCreate/ThreadPost: the anchor
    /// summary message id (used both to branch a new thread and, on a thread
    /// 404, to recreate it). Unused by NewMessage.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) target_message_id: Option<String>,
    /// ThreadPost only: the thread id to post into. None means "create a fresh
    /// thread first" (handled as OpClass::ThreadCreate instead by the caller).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) target_thread_id: Option<String>,
    /// MILLISECONDS (not the registry's seconds convention). flush.rs's
    /// debounce window and `delivery_max_age_secs` burial check both compare
    /// this against `Clock::now_ms()`. Constructed via `http::now_ms()`, not
    /// `store::now_ts()` (Round 6: a seconds value here made every fresh op
    /// look ~2000x older than it was and get buried within seconds).
    pub(crate) created_at: i64,
    #[serde(default)]
    pub(crate) attempts: u32,
    /// MILLISECONDS, same clock as `created_at`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) next_attempt_at: Option<i64>,
}

/// The durable record of a successful delivery, written before the op file is
/// removed. For `ThreadCreate`, `message_id` holds the newly created thread id
/// (the artifact that matters for registry fold-back), not the first message
/// posted into it.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct Committed {
    pub(crate) message_id: String,
    pub(crate) fingerprint: String,
    pub(crate) delivered_at: i64,
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

static SEQ: AtomicU64 = AtomicU64::new(0);

fn queue_dir(state_dir: &str) -> PathBuf {
    Path::new(state_dir).join("queue")
}

fn dead_dir(state_dir: &str) -> PathBuf {
    Path::new(state_dir).join("dead")
}

fn committed_path(op_path: &Path) -> PathBuf {
    let mut s = op_path.as_os_str().to_owned();
    s.push(".committed");
    PathBuf::from(s)
}

fn atomic_write(path: &Path, data: &[u8]) -> io::Result<()> {
    let mut f = fs::File::create(path)?;
    f.write_all(data)?;
    f.sync_all()
}

fn op_filename(op: &Op, epoch_ms: i64, seq: u64) -> String {
    format!("{epoch_ms:013}-{seq:010}-{}.json", op.opclass.tag())
}

/// Durably enqueue `op`, fsyncing before returning. Returns the written path.
pub(crate) fn enqueue(state_dir: &str, op: &Op) -> io::Result<PathBuf> {
    let dir = queue_dir(state_dir);
    fs::create_dir_all(&dir)?;
    let path = dir.join(op_filename(
        op,
        now_ms(),
        SEQ.fetch_add(1, Ordering::SeqCst),
    ));
    let data = serde_json::to_vec_pretty(op).map_err(io::Error::other)?;
    atomic_write(&path, &data)?;
    Ok(path)
}

/// Count pending (uncommitted) ops in the queue.
pub(crate) fn queue_len(state_dir: &str) -> usize {
    let dir = queue_dir(state_dir);
    let Ok(rd) = fs::read_dir(&dir) else {
        return 0;
    };
    rd.filter_map(Result::ok)
        .filter(|e| e.path().extension().map(|x| x == "json").unwrap_or(false))
        .count()
}

/// Outcome of a capacity-checked enqueue.
#[derive(Debug)]
pub(crate) enum EnqueueOutcome {
    Enqueued,
    CapacityExceeded,
}

/// Enqueue `op`, but if the queue already holds `cap` pending ops, bury it
/// immediately instead (never blocks, never grows past cap).
pub(crate) fn enqueue_checked(state_dir: &str, op: &Op, cap: usize) -> io::Result<EnqueueOutcome> {
    if queue_len(state_dir) >= cap {
        bury_new(state_dir, op, "queue capacity exceeded")?;
        return Ok(EnqueueOutcome::CapacityExceeded);
    }
    enqueue(state_dir, op)?;
    Ok(EnqueueOutcome::Enqueued)
}

/// Persist the delivery result, fsync it, then unlink the op file (leaving the
/// `.committed` marker as the crash-recovery record until [`cleanup_committed`]).
pub(crate) fn mark_committed(op_path: &Path, committed: &Committed) -> io::Result<PathBuf> {
    let cpath = committed_path(op_path);
    let data = serde_json::to_vec_pretty(committed).map_err(io::Error::other)?;
    atomic_write(&cpath, &data)?;
    fs::remove_file(op_path)?;
    Ok(cpath)
}

/// Remove a `.committed` marker once its result has been durably folded back
/// into the registry snapshot (best-effort cleanup).
pub(crate) fn cleanup_committed(committed_path: &Path) -> io::Result<()> {
    fs::remove_file(committed_path)
}

/// Remove both files for an op recovered from the narrow crash window where a
/// process died between fsyncing `.committed` and unlinking the `.json` (the
/// case [`scan`] surfaces as [`QueueEntry::Committed`] with the op file still
/// present). Best-effort: a missing file on either side is not an error.
pub(crate) fn cleanup_recovered(op_path: &Path, committed_path: &Path) -> io::Result<()> {
    let _ = fs::remove_file(op_path);
    fs::remove_file(committed_path)
}

/// Rewrite an op file in place with updated retry bookkeeping
/// (`attempts`/`next_attempt_at`). Used by flush.rs after a failed attempt.
pub(crate) fn record_attempt(op_path: &Path, op: &Op) -> io::Result<()> {
    let data = serde_json::to_vec_pretty(op).map_err(io::Error::other)?;
    atomic_write(op_path, &data)
}

/// Move a still-queued op aside into `dead/` and journal a dead-letter line.
pub(crate) fn bury(state_dir: &str, op_path: &Path, reason: &str) -> io::Result<()> {
    let dir = dead_dir(state_dir);
    fs::create_dir_all(&dir)?;
    let name = op_path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "op path has no file name"))?
        .to_owned();
    let dest = dir.join(&name);
    fs::rename(op_path, &dest)?;
    log_meta(
        "dead-letter",
        &format!("buried {} : {reason}", name.to_string_lossy()),
    );
    Ok(())
}

/// Bury an op that was never written to `queue/` (capacity-overflow path).
fn bury_new(state_dir: &str, op: &Op, reason: &str) -> io::Result<()> {
    let dir = dead_dir(state_dir);
    fs::create_dir_all(&dir)?;
    let filename = op_filename(op, now_ms(), SEQ.fetch_add(1, Ordering::SeqCst));
    let path = dir.join(&filename);
    let data = serde_json::to_vec_pretty(op).map_err(io::Error::other)?;
    atomic_write(&path, &data)?;
    log_meta("dead-letter", &format!("buried {filename} : {reason}"));
    Ok(())
}

/// One scanned queue entry: either still pending or already committed
/// (delivered but not yet folded back / cleaned up — the crash-recovery case).
pub(crate) enum QueueEntry {
    Pending {
        op_path: PathBuf,
        op: Op,
    },
    Committed {
        op_path: PathBuf,
        committed_path: PathBuf,
        committed: Committed,
        op: Op,
    },
}

/// Scan `queue/` in filename order (== chronological + seq order, since
/// `epoch_ms` and `seq` are both zero-padded to a fixed width). Entries whose
/// op file fails to parse are logged and skipped rather than silently lost.
pub(crate) fn scan(state_dir: &str) -> Vec<QueueEntry> {
    let dir = queue_dir(state_dir);
    let Ok(rd) = fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut json_paths: Vec<PathBuf> = rd
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().map(|e| e == "json").unwrap_or(false))
        .collect();
    json_paths.sort();

    let mut out = Vec::with_capacity(json_paths.len());
    for op_path in json_paths {
        let Ok(raw) = fs::read_to_string(&op_path) else {
            log_meta("queue-scan", &format!("unreadable op file {op_path:?}"));
            continue;
        };
        let Ok(op) = serde_json::from_str::<Op>(&raw) else {
            log_meta("queue-scan", &format!("corrupt op file {op_path:?}"));
            continue;
        };
        let cpath = committed_path(&op_path);
        if cpath.exists() {
            if let Ok(craw) = fs::read_to_string(&cpath) {
                if let Ok(committed) = serde_json::from_str::<Committed>(&craw) {
                    out.push(QueueEntry::Committed {
                        op_path,
                        committed_path: cpath,
                        committed,
                        op,
                    });
                    continue;
                }
            }
        }
        out.push(QueueEntry::Pending { op_path, op });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir(tag: &str) -> String {
        let mut p = std::env::temp_dir();
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        p.push(format!(
            "gjc-relay-queue-test-{tag}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p.to_string_lossy().into_owned()
    }

    fn cleanup(dir: &str) {
        let _ = fs::remove_dir_all(dir);
    }

    fn sample_op(opclass: OpClass) -> Op {
        Op {
            channel_id: "111".to_string(),
            item_key: "o/r#1".to_string(),
            kind: "github.issue-opened".to_string(),
            embed: serde_json::json!({ "title": "hi" }),
            fingerprint: "iss|o/r|1|opened".to_string(),
            opclass,
            target_message_id: None,
            target_thread_id: None,
            created_at: 1000,
            attempts: 0,
            next_attempt_at: None,
        }
    }

    #[test]
    fn op_order_is_chronological() {
        let dir = temp_dir("order");
        let p1 = enqueue(&dir, &sample_op(OpClass::NewMessage)).unwrap();
        let p2 = enqueue(&dir, &sample_op(OpClass::EditSummary)).unwrap();
        let p3 = enqueue(&dir, &sample_op(OpClass::ThreadPost)).unwrap();

        let entries = scan(&dir);
        assert_eq!(entries.len(), 3);
        let paths: Vec<&PathBuf> = entries
            .iter()
            .map(|e| match e {
                QueueEntry::Pending { op_path, .. } => op_path,
                QueueEntry::Committed { op_path, .. } => op_path,
            })
            .collect();
        assert_eq!(paths, vec![&p1, &p2, &p3]);
        cleanup(&dir);
    }

    #[test]
    fn mark_committed_unlinks_the_op_file_immediately() {
        let dir = temp_dir("committed-normal");
        let op_path = enqueue(&dir, &sample_op(OpClass::NewMessage)).unwrap();
        let committed = Committed {
            message_id: "999".to_string(),
            fingerprint: "iss|o/r|1|opened".to_string(),
            delivered_at: 2000,
        };
        let cpath = mark_committed(&op_path, &committed).unwrap();
        assert!(!op_path.exists(), "op file must be unlinked on commit");
        assert!(cpath.exists());
        cleanup_committed(&cpath).unwrap();
        assert!(!cpath.exists());
        cleanup(&dir);
    }

    /// The narrow crash-recovery window: a process died after fsyncing
    /// `.committed` but before unlinking `.json`, so BOTH files are still on
    /// disk on the next startup scan. This is what "committed-skip on
    /// startup" means — scan() must surface it (not re-POST) so the caller
    /// can fold the result back and finish cleaning up.
    #[test]
    fn committed_skip_on_startup_scan() {
        let dir = temp_dir("committed-skip");
        let op_path = enqueue(&dir, &sample_op(OpClass::NewMessage)).unwrap();
        let committed = Committed {
            message_id: "999".to_string(),
            fingerprint: "iss|o/r|1|opened".to_string(),
            delivered_at: 2000,
        };
        // Simulate the crash: write the .committed marker directly, WITHOUT
        // going through mark_committed (which would also unlink the .json).
        let cpath = committed_path(&op_path);
        let data = serde_json::to_vec_pretty(&committed).unwrap();
        atomic_write(&cpath, &data).unwrap();
        assert!(op_path.exists() && cpath.exists());

        let entries = scan(&dir);
        assert_eq!(entries.len(), 1);
        match &entries[0] {
            QueueEntry::Committed {
                committed: c, op, ..
            } => {
                assert_eq!(c.message_id, "999");
                assert_eq!(op.item_key, "o/r#1");
            }
            QueueEntry::Pending { .. } => panic!("expected a Committed entry"),
        }
        cleanup_recovered(&op_path, &cpath).unwrap();
        assert!(!op_path.exists() && !cpath.exists());
        assert!(
            scan(&dir).is_empty(),
            "both files must be gone after recovery cleanup"
        );
        cleanup(&dir);
    }

    #[test]
    fn bury_moves_to_dead_and_journals() {
        let dir = temp_dir("bury");
        let op_path = enqueue(&dir, &sample_op(OpClass::EditSummary)).unwrap();
        bury(&dir, &op_path, "test reason").unwrap();
        assert!(!op_path.exists());
        let dead_entries: Vec<_> = fs::read_dir(Path::new(&dir).join("dead"))
            .unwrap()
            .filter_map(Result::ok)
            .collect();
        assert_eq!(dead_entries.len(), 1);
        cleanup(&dir);
    }

    #[test]
    fn enqueue_checked_buries_when_at_capacity() {
        let dir = temp_dir("cap");
        let _p1 = enqueue(&dir, &sample_op(OpClass::NewMessage)).unwrap();
        let outcome = enqueue_checked(&dir, &sample_op(OpClass::NewMessage), 1).unwrap();
        assert!(matches!(outcome, EnqueueOutcome::CapacityExceeded));
        // still only 1 pending in queue/, the second went straight to dead/
        assert_eq!(queue_len(&dir), 1);
        let dead_entries: Vec<_> = fs::read_dir(Path::new(&dir).join("dead"))
            .unwrap()
            .filter_map(Result::ok)
            .collect();
        assert_eq!(dead_entries.len(), 1);
        cleanup(&dir);
    }

    #[test]
    fn no_auth_token_in_any_serialized_op_file() {
        let dir = temp_dir("no-token");
        let mut op = sample_op(OpClass::NewMessage);
        op.embed = serde_json::json!({ "title": "hi", "description": "no secrets here" });
        let op_path = enqueue(&dir, &op).unwrap();
        let raw = fs::read_to_string(&op_path).unwrap();
        assert!(!raw.to_ascii_lowercase().contains("authorization"));
        assert!(!raw.to_ascii_lowercase().contains("bearer"));
        assert!(!raw.to_ascii_lowercase().contains("token"));

        let committed = Committed {
            message_id: "1".to_string(),
            fingerprint: op.fingerprint.clone(),
            delivered_at: 1,
        };
        let cpath = mark_committed(&op_path, &committed).unwrap();
        let craw = fs::read_to_string(&cpath).unwrap();
        assert!(!craw.to_ascii_lowercase().contains("token"));
        cleanup(&dir);
    }
}
