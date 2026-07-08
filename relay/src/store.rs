//! Durable snapshot of the work-item [`State`] (best-effort cache).
//!
//! The on-disk `state.json` is a crash-recovery cache, not the delivery source of
//! truth (that is the Round-2 queue). Loads are defensive: a corrupt or
//! wrong-version file is quarantined and replaced with a fresh empty state rather
//! than crashing the relay. Writes are atomic (tmp + fsync + rename). No auth
//! token is ever serialized here — [`State`] carries none by construction.

use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::registry::{State, STATE_VERSION};

const STATE_FILE: &str = "state.json";
const TMP_FILE: &str = "state.json.tmp";

/// Current wall-clock time in epoch seconds (0 on a pre-epoch clock).
pub(crate) fn now_ts() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Load `state_dir/state.json`. A missing file yields a fresh empty state. A
/// parse error or version mismatch quarantines the file (renamed to
/// `state.json.corrupt-<epoch>`) and yields a fresh state. Expired dedup
/// fingerprints are pruned on a successful load.
pub(crate) fn load(state_dir: &str) -> State {
    let path = Path::new(state_dir).join(STATE_FILE);
    let raw = match std::fs::read_to_string(&path) {
        Ok(r) => r,
        Err(_) => return State::new(), // absent -> fresh (not a corruption)
    };

    match serde_json::from_str::<State>(&raw) {
        Ok(mut st) if st.version == STATE_VERSION => {
            st.prune_dedup(now_ts());
            st
        }
        Ok(_) => {
            // Recognisable JSON but the wrong schema version.
            quarantine(&path);
            State::new()
        }
        Err(_) => {
            quarantine(&path);
            State::new()
        }
    }
}

/// Atomically persist `state` to `state_dir/state.json`: create the dir if
/// missing, write to a temp file, fsync it, then rename over the target (atomic
/// on the same filesystem).
pub(crate) fn save(state_dir: &str, state: &State) -> io::Result<()> {
    let dir = Path::new(state_dir);
    std::fs::create_dir_all(dir)?;

    let data = serde_json::to_vec_pretty(state).map_err(io::Error::other)?;
    let tmp = dir.join(TMP_FILE);
    let final_path = dir.join(STATE_FILE);

    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(&data)?;
        f.sync_all()?; // fsync before the rename so the payload is durable
    }
    std::fs::rename(&tmp, &final_path)?;
    Ok(())
}

/// Rename a suspect state file aside as `state.json.corrupt-<epoch>` so it is
/// preserved for inspection without blocking a fresh start. Best-effort.
fn quarantine(path: &Path) {
    let corrupt: PathBuf = path.with_file_name(format!("{STATE_FILE}.corrupt-{}", now_ts()));
    let _ = std::fs::rename(path, corrupt);
}

/// Dirty-flag persistence guard enforcing at most one write per second, with an
/// unconditional [`flush_now`](Persister::flush_now) for shutdown / SIGTERM.
///
/// Round 2 wires this into the main loop; here it is a self-contained API.
pub(crate) struct Persister {
    dirty: bool,
    last_write: Option<Instant>,
    min_interval: Duration,
}

impl Default for Persister {
    fn default() -> Persister {
        Persister {
            dirty: false,
            last_write: None,
            min_interval: Duration::from_secs(1),
        }
    }
}

impl Persister {
    pub(crate) fn new() -> Persister {
        Persister::default()
    }

    /// Record that the in-memory state changed and should be flushed.
    pub(crate) fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    #[allow(dead_code)] // exercised by tests; no production caller needs it yet
    pub(crate) fn is_dirty(&self) -> bool {
        self.dirty
    }

    /// Flush iff dirty and at least one second has elapsed since the last write.
    /// Returns Ok(true) when a write happened.
    pub(crate) fn maybe_flush(&mut self, state_dir: &str, state: &State) -> io::Result<bool> {
        if !self.dirty {
            return Ok(false);
        }
        if let Some(last) = self.last_write {
            if last.elapsed() < self.min_interval {
                return Ok(false);
            }
        }
        save(state_dir, state)?;
        self.last_write = Some(Instant::now());
        self.dirty = false;
        Ok(true)
    }

    /// Force an immediate write regardless of the rate limit (shutdown path).
    /// Not yet wired to a signal handler — see main.rs's doc comment on the
    /// persister thread for why SIGTERM wiring is deferred this round.
    #[allow(dead_code)]
    pub(crate) fn flush_now(&mut self, state_dir: &str, state: &State) -> io::Result<()> {
        save(state_dir, state)?;
        self.last_write = Some(Instant::now());
        self.dirty = false;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::{ItemType, WorkItem, DEDUP_TTL_SECS};

    /// Create a unique temp dir under the system temp root; caller cleans up.
    fn temp_dir(tag: &str) -> String {
        let mut p = std::env::temp_dir();
        let uniq = format!(
            "gjc-relay-test-{tag}-{}-{}",
            std::process::id(),
            now_ts_nanos()
        );
        p.push(uniq);
        std::fs::create_dir_all(&p).unwrap();
        p.to_string_lossy().into_owned()
    }

    fn now_ts_nanos() -> u128 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    }

    fn cleanup(dir: &str) {
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn save_then_load_roundtrip() {
        let dir = temp_dir("roundtrip");
        let mut st = State::new();
        st.learn(WorkItem::new(
            "o/r#1".to_string(),
            "chan".to_string(),
            ItemType::Pr,
            now_ts(),
        ));
        save(&dir, &st).unwrap();

        let loaded = load(&dir);
        assert_eq!(loaded.version, STATE_VERSION);
        assert!(loaded.items.contains_key("o/r#1"));
        cleanup(&dir);
    }

    #[test]
    fn corrupt_file_quarantined_and_fresh() {
        let dir = temp_dir("corrupt");
        let path = Path::new(&dir).join(STATE_FILE);
        std::fs::write(&path, b"{ this is not valid json").unwrap();

        let st = load(&dir);
        assert_eq!(st.version, STATE_VERSION);
        assert!(st.items.is_empty());

        // a .corrupt-* sibling exists and the original is gone
        assert!(!path.exists(), "corrupt state.json must be renamed away");
        let has_corrupt = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .any(|e| {
                e.file_name()
                    .to_string_lossy()
                    .contains("state.json.corrupt-")
            });
        assert!(has_corrupt, "expected a quarantined .corrupt-* file");
        cleanup(&dir);
    }

    #[test]
    fn version_mismatch_quarantined_and_fresh() {
        let dir = temp_dir("version");
        let path = Path::new(&dir).join(STATE_FILE);
        // valid JSON, wrong version
        std::fs::write(&path, br#"{"version":1,"items":{},"dedup":{}}"#).unwrap();

        let st = load(&dir);
        assert_eq!(st.version, STATE_VERSION);
        assert!(!path.exists());
        let has_corrupt = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .any(|e| {
                e.file_name()
                    .to_string_lossy()
                    .contains("state.json.corrupt-")
            });
        assert!(has_corrupt);
        cleanup(&dir);
    }

    #[test]
    fn dedup_ttl_pruned_on_load() {
        let dir = temp_dir("dedup");
        let mut st = State::new();
        // one expired, one fresh relative to now
        let now = now_ts();
        st.dedup.insert("stale".to_string(), now - DEDUP_TTL_SECS - 10);
        st.dedup.insert("fresh".to_string(), now);
        save(&dir, &st).unwrap();

        let loaded = load(&dir);
        assert!(!loaded.dedup.contains_key("stale"), "expired dedup pruned");
        assert!(loaded.dedup.contains_key("fresh"));
        cleanup(&dir);
    }

    #[test]
    fn persister_rate_limits_but_flush_now_forces() {
        let dir = temp_dir("persister");
        let st = State::new();
        let mut p = Persister::new();

        // clean -> nothing to flush
        assert!(!p.maybe_flush(&dir, &st).unwrap());

        p.mark_dirty();
        assert!(p.is_dirty());
        // first flush writes
        assert!(p.maybe_flush(&dir, &st).unwrap());
        assert!(!p.is_dirty());

        // immediate second attempt is rate-limited even when dirty
        p.mark_dirty();
        assert!(!p.maybe_flush(&dir, &st).unwrap());

        // flush_now ignores the rate limit
        p.flush_now(&dir, &st).unwrap();
        assert!(!p.is_dirty());
        cleanup(&dir);
    }
}
