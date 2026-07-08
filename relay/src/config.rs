//! Runtime configuration for gjc-relay, loaded from environment variables.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use serde_json::Value;

const DEFAULT_UPSTREAM: &str = "https://discord.com";

/// Fixed size of the per-channel token pool shared between managed traffic and
/// the reserved/critical share. `managed_tokens` may claim 1..=4 of these; the
/// remainder (`RATE_POOL - managed_tokens`) is the critical reservation the
/// Round-2 bucket honours for high-severity kinds.
#[allow(dead_code)] // consumed by the Round-2 rate bucket
const RATE_POOL: u32 = 5;

/// A resolved managed-traffic rate: `managed_tokens` per `window_secs` window.
/// The reserved/critical share is `RATE_POOL - managed_tokens`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ManagedRate {
    pub(crate) managed_tokens: u32,
    pub(crate) window_secs: u64,
}

impl ManagedRate {
    /// Tokens reserved for critical/high-severity traffic (never spent by the
    /// managed rate limiter). Documented here, consumed by the Round-2 bucket.
    #[allow(dead_code)] // consumed by the Round-2 rate bucket
    pub(crate) fn reserved_share(&self) -> u32 {
        RATE_POOL.saturating_sub(self.managed_tokens)
    }

    /// Parse `RELAY_MANAGED_RATE`: a named preset (with aliases) or an explicit
    /// `<tokens>/<window>s` form. Panics with a clear message on anything
    /// out of range so the binary rejects bad config even if render.sh missed it.
    fn parse(raw: &str) -> ManagedRate {
        let s = raw.trim();
        let rate = match s.to_ascii_lowercase().as_str() {
            "low" | "conservative" => ManagedRate {
                managed_tokens: 2,
                window_secs: 5,
            },
            "medium" | "balanced" => ManagedRate {
                managed_tokens: 3,
                window_secs: 5,
            },
            "high" | "throughput" => ManagedRate {
                managed_tokens: 4,
                window_secs: 5,
            },
            _ => {
                // Explicit "<tokens>/<window>s".
                let (tok_s, rest) = s.split_once('/').unwrap_or_else(|| {
                    panic!(
                        "gjc-relay: RELAY_MANAGED_RATE {s:?} is not a known preset \
                         (low|medium|high) nor a <tokens>/<window>s form"
                    )
                });
                let win_s = rest.strip_suffix('s').unwrap_or(rest);
                let managed_tokens: u32 = tok_s.trim().parse().unwrap_or_else(|_| {
                    panic!("gjc-relay: RELAY_MANAGED_RATE {s:?} has non-numeric token count")
                });
                let window_secs: u64 = win_s.trim().parse().unwrap_or_else(|_| {
                    panic!("gjc-relay: RELAY_MANAGED_RATE {s:?} has non-numeric window")
                });
                ManagedRate {
                    managed_tokens,
                    window_secs,
                }
            }
        };
        if !(1..=4).contains(&rate.managed_tokens) {
            panic!(
                "gjc-relay: RELAY_MANAGED_RATE tokens {} out of range (must be 1..=4)",
                rate.managed_tokens
            );
        }
        if rate.window_secs < 1 {
            panic!(
                "gjc-relay: RELAY_MANAGED_RATE window {}s out of range (must be >= 1s)",
                rate.window_secs
            );
        }
        rate
    }
}

/// Configuration derived from the environment: bind address, design system,
/// upstream host, and the diagnostic force-429 channel list.
///
/// The v2 work-item fields (`workitem_channels` onward) are additive and inert
/// unless `RELAY_WORKITEM_CHANNELS` is non-empty: with it unset the managed path
/// is fully off and the relay behaves byte-identically to v1.
#[allow(dead_code)] // v2 fields wired into delivery in Round 2
pub(crate) struct Config {
    pub(crate) bind: String,
    pub(crate) ds: Arc<Value>,
    pub(crate) upstream: Arc<String>,
    pub(crate) force_429: Arc<Vec<String>>,
    /// Diagnostic (default empty = inert): comma-separated channel ids for
    /// which the flush loop hard-aborts the process immediately after a
    /// new-message-class POST succeeds, but before the `.committed` marker is
    /// written — modeling the exact crash window the read-back reconciliation
    /// (A2a step 3a) exists to recover from. See `Config::from_env`'s doc
    /// comment on this field for the full rationale; drill-only, zero
    /// production blast radius when unset.
    pub(crate) fault_after_post: Arc<Vec<String>>,

    // --- v2 work-item core (inert while workitem_channels is empty) ---
    // These fields are read by the Round-2 delivery path; unused this round.
    /// Managed channel selector: empty (feature off), the literal "all", or an
    /// explicit set of numeric channel ids.
    pub(crate) workitem_channels: WorkitemChannels,
    pub(crate) state_dir: String,
    pub(crate) debounce_secs: u64,
    pub(crate) debounce_max_secs: u64,
    pub(crate) delivery_max_age_secs: u64,
    pub(crate) queue_cap: usize,
    /// Per-channel debounce overrides from `RELAY_DEBOUNCE_SECS__<cid>`.
    pub(crate) debounce_overrides: HashMap<String, u64>,
    pub(crate) managed_rate: ManagedRate,
    pub(crate) heartbeat_enabled: bool,
    pub(crate) heartbeat_secs: u64,
}

/// The parsed `RELAY_WORKITEM_CHANNELS` selector.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum WorkitemChannels {
    /// Feature off: no channel is managed.
    None,
    /// Every channel is managed.
    All,
    /// Only the listed channel ids are managed.
    Set(HashSet<String>),
}

impl Config {
    pub(crate) fn from_env() -> Config {
        let bind = std::env::var("RELAY_BIND").unwrap_or_else(|_| "127.0.0.1:25295".to_string());
        let ds_path = std::env::var("RELAY_DESIGN_SYSTEM").unwrap_or_else(|_| {
            let home = std::env::var("HOME")
                .expect("gjc-relay: neither RELAY_DESIGN_SYSTEM nor HOME is set");
            format!("{home}/.gjc-relay/design-system.json")
        });

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

        // Diagnostic (default empty = inert): comma-separated channel ids for which
        // the flush loop hard-aborts right after a new-message-class Discord POST
        // succeeds but before the .committed marker is fsynced. Lets the DEPLOY-LAB
        // C1 crash-window drill prove the read-back reconciliation live on ONE test
        // channel (crash mid-window, restart, observe zero duplicate messages) while
        // every real channel keeps delivering normally (zero production blast radius).
        let fault_after_post: Arc<Vec<String>> = Arc::new(
            std::env::var("RELAY_FAULT_AFTER_POST")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect(),
        );

        // --- v2 work-item core ---
        let workitem_channels =
            parse_workitem_channels(&std::env::var("RELAY_WORKITEM_CHANNELS").unwrap_or_default());

        let state_dir = std::env::var("RELAY_STATE_DIR").unwrap_or_else(|_| {
            let home =
                std::env::var("HOME").expect("gjc-relay: neither RELAY_STATE_DIR nor HOME is set");
            format!("{home}/.gjc-relay/state")
        });

        let debounce_secs = env_u64("RELAY_DEBOUNCE_SECS", 5);
        let debounce_max_secs = env_u64("RELAY_DEBOUNCE_MAX_SECS", 20);
        let delivery_max_age_secs = env_u64("RELAY_DELIVERY_MAX_AGE_SECS", 600);
        let queue_cap = env_u64("RELAY_QUEUE_CAP", 500) as usize;

        // Per-channel debounce overrides: scan the environment once for
        // RELAY_DEBOUNCE_SECS__<cid> keys.
        let mut debounce_overrides: HashMap<String, u64> = HashMap::new();
        for (k, v) in std::env::vars() {
            if let Some(cid) = k.strip_prefix("RELAY_DEBOUNCE_SECS__") {
                if cid.is_empty() {
                    continue;
                }
                if let Ok(secs) = v.trim().parse::<u64>() {
                    debounce_overrides.insert(cid.to_string(), secs);
                }
            }
        }

        let managed_rate = ManagedRate::parse(
            &std::env::var("RELAY_MANAGED_RATE").unwrap_or_else(|_| "medium".to_string()),
        );

        let heartbeat_enabled = std::env::var("RELAY_HEARTBEAT_ENABLED")
            .map(|v| v.trim() != "0")
            .unwrap_or(true);
        let heartbeat_secs = env_u64("RELAY_HEARTBEAT_SECS", 120);

        Config {
            bind,
            ds,
            upstream,
            force_429,
            fault_after_post,
            workitem_channels,
            state_dir,
            debounce_secs,
            debounce_max_secs,
            delivery_max_age_secs,
            queue_cap,
            debounce_overrides,
            managed_rate,
            heartbeat_enabled,
            heartbeat_secs,
        }
    }

    /// True when the managed work-item path applies to `cid`: false when the
    /// feature is off (empty selector), true for "all" or an explicit member.
    #[allow(dead_code)] // caller lives in the Round-2 delivery path
    pub(crate) fn channel_is_managed(&self, cid: &str) -> bool {
        match &self.workitem_channels {
            WorkitemChannels::None => false,
            WorkitemChannels::All => true,
            WorkitemChannels::Set(set) => set.contains(cid),
        }
    }

    /// Debounce window for `cid`: the per-channel override if present, else the
    /// global default.
    #[allow(dead_code)] // caller lives in the Round-2 debounce path
    pub(crate) fn debounce_for(&self, cid: &str) -> u64 {
        self.debounce_overrides
            .get(cid)
            .copied()
            .unwrap_or(self.debounce_secs)
    }
}

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(default)
}

fn parse_workitem_channels(raw: &str) -> WorkitemChannels {
    let s = raw.trim();
    if s.is_empty() {
        return WorkitemChannels::None;
    }
    if s.eq_ignore_ascii_case("all") {
        return WorkitemChannels::All;
    }
    let set: HashSet<String> = s
        .split(',')
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .collect();
    if set.is_empty() {
        WorkitemChannels::None
    } else {
        WorkitemChannels::Set(set)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn managed_rate_presets_and_aliases() {
        assert_eq!(
            ManagedRate::parse("low"),
            ManagedRate {
                managed_tokens: 2,
                window_secs: 5
            }
        );
        assert_eq!(
            ManagedRate::parse("conservative"),
            ManagedRate::parse("low")
        );
        assert_eq!(
            ManagedRate::parse("medium"),
            ManagedRate {
                managed_tokens: 3,
                window_secs: 5
            }
        );
        assert_eq!(ManagedRate::parse("balanced"), ManagedRate::parse("medium"));
        assert_eq!(
            ManagedRate::parse("high"),
            ManagedRate {
                managed_tokens: 4,
                window_secs: 5
            }
        );
        assert_eq!(ManagedRate::parse("throughput"), ManagedRate::parse("high"));
        // case-insensitive
        assert_eq!(ManagedRate::parse("MEDIUM"), ManagedRate::parse("medium"));
    }

    #[test]
    fn managed_rate_explicit_parse() {
        assert_eq!(
            ManagedRate::parse("3/5s"),
            ManagedRate {
                managed_tokens: 3,
                window_secs: 5
            }
        );
        // trailing 's' optional
        assert_eq!(
            ManagedRate::parse("2/10"),
            ManagedRate {
                managed_tokens: 2,
                window_secs: 10
            }
        );
    }

    #[test]
    fn managed_rate_reserved_share() {
        assert_eq!(ManagedRate::parse("low").reserved_share(), 3);
        assert_eq!(ManagedRate::parse("medium").reserved_share(), 2);
        assert_eq!(ManagedRate::parse("high").reserved_share(), 1);
    }

    #[test]
    #[should_panic(expected = "out of range")]
    fn managed_rate_rejects_zero_tokens() {
        ManagedRate::parse("0/5s");
    }

    #[test]
    #[should_panic(expected = "out of range")]
    fn managed_rate_rejects_too_many_tokens() {
        ManagedRate::parse("5/5s");
    }

    #[test]
    #[should_panic(expected = "out of range")]
    fn managed_rate_rejects_zero_window() {
        ManagedRate::parse("3/0s");
    }

    #[test]
    #[should_panic]
    fn managed_rate_rejects_garbage() {
        ManagedRate::parse("not-a-rate");
    }

    #[test]
    fn channel_is_managed_empty_all_set() {
        assert_eq!(parse_workitem_channels(""), WorkitemChannels::None);
        assert_eq!(parse_workitem_channels("   "), WorkitemChannels::None);
        assert_eq!(parse_workitem_channels("all"), WorkitemChannels::All);
        assert_eq!(parse_workitem_channels("ALL"), WorkitemChannels::All);

        let set = parse_workitem_channels("111, 222 ,333");
        match &set {
            WorkitemChannels::Set(s) => {
                assert!(s.contains("111") && s.contains("222") && s.contains("333"));
                assert_eq!(s.len(), 3);
            }
            _ => panic!("expected a set"),
        }
    }

    #[test]
    fn channel_is_managed_via_config() {
        let mk = |wc: WorkitemChannels| Config {
            bind: String::new(),
            ds: Arc::new(Value::Null),
            upstream: Arc::new(String::new()),
            force_429: Arc::new(vec![]),
            fault_after_post: Arc::new(vec![]),
            workitem_channels: wc,
            state_dir: String::new(),
            debounce_secs: 5,
            debounce_max_secs: 20,
            delivery_max_age_secs: 600,
            queue_cap: 500,
            debounce_overrides: HashMap::new(),
            managed_rate: ManagedRate::parse("medium"),
            heartbeat_enabled: true,
            heartbeat_secs: 120,
        };

        let off = mk(WorkitemChannels::None);
        assert!(!off.channel_is_managed("111"));

        let all = mk(WorkitemChannels::All);
        assert!(all.channel_is_managed("anything"));

        let set = mk(parse_workitem_channels("111,222"));
        assert!(set.channel_is_managed("111"));
        assert!(!set.channel_is_managed("999"));
    }

    #[test]
    fn debounce_for_override_else_default() {
        let mut overrides = HashMap::new();
        overrides.insert("111".to_string(), 12u64);
        let cfg = Config {
            bind: String::new(),
            ds: Arc::new(Value::Null),
            upstream: Arc::new(String::new()),
            force_429: Arc::new(vec![]),
            fault_after_post: Arc::new(vec![]),
            workitem_channels: WorkitemChannels::None,
            state_dir: String::new(),
            debounce_secs: 5,
            debounce_max_secs: 20,
            delivery_max_age_secs: 600,
            queue_cap: 500,
            debounce_overrides: overrides,
            managed_rate: ManagedRate::parse("medium"),
            heartbeat_enabled: true,
            heartbeat_secs: 120,
        };
        assert_eq!(cfg.debounce_for("111"), 12);
        assert_eq!(cfg.debounce_for("999"), 5);
    }
}
