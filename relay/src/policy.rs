//! Surface routing policy: the A6 taxonomy that maps an event to the Discord
//! surface it should land on.
//!
//! [`decide`] is a **pure** function. It never touches the registry, the lock, or
//! the network: the caller computes `item_known` / `dedup_hit` from a registry
//! snapshot *under the lock*, releases the lock, and then calls `decide`. Any
//! side effects the taxonomy notes (mark-terminal, final thread note, stage edit,
//! logging) are the caller's responsibility.

use serde_json::Value;

use crate::envelope::Envelope;

/// Where a managed event should be delivered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Surface {
    /// Post a new anchor/summary message.
    NewMessage,
    /// Edit the existing summary message in place.
    EditSummary,
    /// Post into the item's thread.
    ThreadPost,
    /// Edit the summary and post a thread note.
    EditAndThread,
    /// Not managed — the caller forwards it down the untouched v1/clawhip path.
    Unmanaged,
    /// Suppress entirely (dedup hit, or the branch-push CI flood class).
    Drop,
}

/// Decide the surface for `kind` given the caller-computed registry snapshot
/// booleans and the feature flag. `ds` supplies optional per-kind overrides.
///
/// Precedence (safety-critical — do not reorder):
///   1. flag guard: feature off -> Unmanaged, unconditionally.
///   2. compiled branch-aware decision (`compiled_decision`), which already
///      folds in dedup-hit suppression and the unknown-item CI flood-class
///      Drop (the #easyhdr reboot-flood killer).
///   3. if that compiled decision is Drop, RETURN Drop immediately — the
///      per-kind design-system `surface` override is NEVER consulted for a
///      safety Drop. This is what stops an operator's steady-state remap
///      (e.g. ci-passed -> edit-summary) from resurrecting a flood-class
///      unknown-item CI event or a dedup replay into a delivered message.
///   4. an unknown-item CI event (started/passed/cancelled/failed with
///      item_known=false) is ALSO locked even when its compiled decision
///      isn't literally Drop: ci-failed unknown compiles to NewMessage (a
///      branch failure must surface), and that must not be re-mapped by an
///      operator override either — only the "is this item known" axis, not
///      the design system, may steer CI behavior for an anchor-less event.
///   5. only otherwise (item known, i.e. the anchored steady state): the
///      per-kind override (if present) may substitute the compiled decision;
///      else the compiled decision itself is used.
pub(crate) fn decide(
    kind: &str,
    env: &Envelope,
    item_known: bool,
    dedup_hit: bool,
    flag_on: bool,
    ds: &Value,
) -> Surface {
    // Hard guard: feature off (or the caller determined the channel is unmanaged).
    if !flag_on {
        return Surface::Unmanaged;
    }

    let compiled = compiled_decision(kind, env, item_known, dedup_hit);

    // Safety Drops (dedup replay, or the unknown-item CI flood class) are
    // non-overridable: they win over any per-kind design-system surface.
    if compiled == Surface::Drop {
        return Surface::Drop;
    }

    // The unknown-item CI safety lock extends beyond the literal Drop case:
    // ci-failed with an unknown item compiles to NewMessage (branch failures
    // must surface), and that outcome is equally non-overridable — only once
    // the item is known does the per-kind override apply to a CI kind.
    if is_unknown_item_ci(kind, item_known) {
        return compiled;
    }

    // Operator escape hatch: ds["kinds"][kind]["surface"] replaces the
    // compiled decision for this kind — only reached for the anchored
    // steady state (item known) or a non-CI kind.
    if let Some(ov) = override_surface(ds, kind) {
        return ov;
    }

    compiled
}

/// The compiled decision including dedup suppression: the compiled A6
/// taxonomy default, with any *managed* (non-Unmanaged) result downgraded to
/// Drop on a dedup hit. Idempotency always wins — a duplicate must never
/// re-deliver, regardless of any operator override.
fn compiled_decision(kind: &str, env: &Envelope, item_known: bool, dedup_hit: bool) -> Surface {
    let base = compiled_default(kind, env, item_known);
    if base != Surface::Unmanaged && dedup_hit {
        Surface::Drop
    } else {
        base
    }
}

/// True for a CI kind observed against an unknown (anchor-less) item — the
/// branch-push safety class whose compiled outcome (Drop for
/// started/passed/cancelled, NewMessage for failed) is never subject to the
/// per-kind design-system override.
fn is_unknown_item_ci(kind: &str, item_known: bool) -> bool {
    !item_known
        && matches!(
            kind,
            "github.ci-started" | "github.ci-passed" | "github.ci-cancelled" | "github.ci-failed"
        )
}

/// The compiled A6 taxonomy default (before dedup / override are applied).
fn compiled_default(kind: &str, env: &Envelope, item_known: bool) -> Surface {
    match kind {
        // Issues.
        "github.issue-opened" => Surface::NewMessage,
        "github.issue-commented" => {
            if item_known {
                Surface::ThreadPost
            } else {
                Surface::NewMessage
            }
        }

        // PR status transitions.
        "github.pr-status-changed" => match pr_status(env) {
            // Terminal states edit the summary (caller marks terminal + final note).
            "merged" | "closed" => Surface::EditSummary,
            // Open/opened/reopened: new anchor if unknown, else fold into summary.
            _ => {
                if item_known {
                    Surface::EditSummary
                } else {
                    Surface::NewMessage
                }
            }
        },

        // Work-item dispatch: fold into the anchor if it exists, else create it.
        "workitem.dispatched" => {
            if item_known {
                Surface::EditAndThread
            } else {
                Surface::NewMessage
            }
        }

        // CI success/neutral: edit the summary when anchored; a branch-push CI
        // event with no work item is the flood class -> Drop (caller logs it).
        "github.ci-started" | "github.ci-passed" | "github.ci-cancelled" => {
            if item_known {
                Surface::EditSummary
            } else {
                Surface::Drop
            }
        }

        // CI failure must always surface: edit+thread when anchored, else a new
        // message so branch failures are not lost.
        "github.ci-failed" => {
            if item_known {
                Surface::EditAndThread
            } else {
                Surface::NewMessage
            }
        }

        // Merge verdict is a human decision point -> always a new message
        // (caller also applies the stage edit).
        "workitem.merge-verdict" => Surface::NewMessage,

        // Highest-severity approval keeps the untouched clawhip path.
        "agent.approval-requested" => Surface::Unmanaged,

        // Everything else stays unmanaged: sessions, commits, branch changes,
        // releases, canaries, heartbeats, and any custom/unrecognized kind
        // (custom-without-number included) fall through here.
        _ => Surface::Unmanaged,
    }
}

/// The PR status slot, lowercased; empty when absent.
fn pr_status(env: &Envelope) -> &str {
    match env.status.trim() {
        "" => "",
        s => s,
    }
}

/// Resolve a per-kind `surface` override from the design system, if present.
fn override_surface(ds: &Value, kind: &str) -> Option<Surface> {
    let s = ds.get("kinds")?.get(kind)?.get("surface")?.as_str()?;
    surface_from_str(s)
}

/// Parse a surface name (case- and separator-insensitive).
fn surface_from_str(s: &str) -> Option<Surface> {
    let norm: String = s
        .trim()
        .to_ascii_lowercase()
        .chars()
        .filter(|c| *c != '_' && *c != '-' && *c != ' ')
        .collect();
    match norm.as_str() {
        "newmessage" => Some(Surface::NewMessage),
        "editsummary" => Some(Surface::EditSummary),
        "threadpost" => Some(Surface::ThreadPost),
        "editandthread" => Some(Surface::EditAndThread),
        "unmanaged" => Some(Surface::Unmanaged),
        "drop" => Some(Surface::Drop),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn env_with(kind: &str, status: &str) -> Envelope {
        Envelope {
            kind: kind.to_string(),
            status: status.to_string(),
            ..Envelope::default()
        }
    }

    #[test]
    fn flag_off_is_always_unmanaged() {
        let env = env_with("github.issue-opened", "");
        assert_eq!(
            decide(
                "github.issue-opened",
                &env,
                false,
                false,
                false,
                &Value::Null
            ),
            Surface::Unmanaged
        );
    }

    #[test]
    fn taxonomy_table() {
        // (kind, status, item_known, dedup_hit, expected)
        let rows: &[(&str, &str, bool, bool, Surface)] = &[
            // issues
            ("github.issue-opened", "", false, false, Surface::NewMessage),
            (
                "github.issue-commented",
                "",
                true,
                false,
                Surface::ThreadPost,
            ),
            (
                "github.issue-commented",
                "",
                false,
                false,
                Surface::NewMessage,
            ),
            // pr status
            (
                "github.pr-status-changed",
                "open",
                false,
                false,
                Surface::NewMessage,
            ),
            (
                "github.pr-status-changed",
                "open",
                true,
                false,
                Surface::EditSummary,
            ),
            (
                "github.pr-status-changed",
                "merged",
                true,
                false,
                Surface::EditSummary,
            ),
            (
                "github.pr-status-changed",
                "closed",
                true,
                false,
                Surface::EditSummary,
            ),
            // workitem dispatch
            (
                "workitem.dispatched",
                "",
                true,
                false,
                Surface::EditAndThread,
            ),
            ("workitem.dispatched", "", false, false, Surface::NewMessage),
            // CI success/neutral: known -> edit, unknown -> Drop (flood class)
            ("github.ci-started", "", true, false, Surface::EditSummary),
            ("github.ci-started", "", false, false, Surface::Drop),
            ("github.ci-passed", "", true, false, Surface::EditSummary),
            ("github.ci-passed", "", false, false, Surface::Drop),
            ("github.ci-cancelled", "", true, false, Surface::EditSummary),
            ("github.ci-cancelled", "", false, false, Surface::Drop),
            // CI failure: known -> edit+thread, unknown -> new message
            ("github.ci-failed", "", true, false, Surface::EditAndThread),
            ("github.ci-failed", "", false, false, Surface::NewMessage),
            // merge verdict
            (
                "workitem.merge-verdict",
                "",
                false,
                false,
                Surface::NewMessage,
            ),
            (
                "workitem.merge-verdict",
                "",
                true,
                false,
                Surface::NewMessage,
            ),
            // unmanaged classes
            (
                "agent.approval-requested",
                "",
                true,
                false,
                Surface::Unmanaged,
            ),
            ("session.started", "", false, false, Surface::Unmanaged),
            ("session.ended", "", true, false, Surface::Unmanaged),
            ("git.commit", "", false, false, Surface::Unmanaged),
            ("git.branch-changed", "", false, false, Surface::Unmanaged),
            (
                "github.release-published",
                "",
                false,
                false,
                Surface::Unmanaged,
            ),
            ("gjc.canary", "", false, false, Surface::Unmanaged),
            ("heartbeat", "", false, false, Surface::Unmanaged),
            ("custom.thing", "", false, false, Surface::Unmanaged),
        ];

        for (kind, status, known, dedup, expected) in rows {
            let env = env_with(kind, status);
            let got = decide(kind, &env, *known, *dedup, true, &Value::Null);
            assert_eq!(
                got, *expected,
                "kind={kind} status={status} known={known} dedup={dedup}"
            );
        }
    }

    #[test]
    fn dedup_hit_drops_managed_kinds() {
        // a managed kind that would otherwise be NewMessage
        let env = env_with("github.issue-opened", "");
        assert_eq!(
            decide("github.issue-opened", &env, false, true, true, &Value::Null),
            Surface::Drop
        );
        // dedup on an unmanaged kind does NOT force Drop
        let env2 = env_with("session.started", "");
        assert_eq!(
            decide("session.started", &env2, false, true, true, &Value::Null),
            Surface::Unmanaged
        );
    }

    #[test]
    fn per_kind_override_replaces_default() {
        let ds = json!({
            "kinds": {
                "github.issue-opened": { "surface": "thread_post" }
            }
        });
        let env = env_with("github.issue-opened", "");
        // default would be NewMessage; override wins
        assert_eq!(
            decide("github.issue-opened", &env, false, false, true, &ds),
            Surface::ThreadPost
        );
        // but dedup still wins over the override
        assert_eq!(
            decide("github.issue-opened", &env, false, true, true, &ds),
            Surface::Drop
        );
    }

    /// The #1 product-safety property (plan A6): the unknown-item CI
    /// flood-class Drop (and dedup Drop) must NEVER be overridable by a
    /// per-kind design-system `surface` remap — otherwise the anchored
    /// steady-state override (ci-started/-passed/-cancelled -> edit-summary,
    /// ci-failed -> edit-and-thread) would resurrect the exact #easyhdr
    /// reboot-flood class the overhaul exists to kill the moment a channel
    /// opts in.
    #[test]
    fn flood_drop_cannot_be_overridden_by_per_kind_surface() {
        let ds_edit_summary =
            |kind: &str| json!({ "kinds": { kind: { "surface": "edit-summary" } } });

        for kind in [
            "github.ci-started",
            "github.ci-passed",
            "github.ci-cancelled",
        ] {
            let ds = ds_edit_summary(kind);
            let env = env_with(kind, "");

            // Unknown item (branch-push flood class): override must be ignored -> Drop.
            assert_eq!(
                decide(kind, &env, false, false, true, &ds),
                Surface::Drop,
                "kind={kind}: unknown-item flood Drop must not be overridable"
            );

            // Positive control: item KNOWN (steady state) -> the override DOES apply.
            assert_eq!(
                decide(kind, &env, true, false, true, &ds),
                Surface::EditSummary,
                "kind={kind}: steady-state override must still apply when the item is known"
            );
        }

        // ci-failed, unknown item, WITH an (irrelevant) override present ->
        // branch failures must still surface as NewMessage, never suppressed
        // or redirected by the override.
        let ds_failed = json!({
            "kinds": { "github.ci-failed": { "surface": "edit-summary" } }
        });
        let env_failed = env_with("github.ci-failed", "");
        assert_eq!(
            decide(
                "github.ci-failed",
                &env_failed,
                false,
                false,
                true,
                &ds_failed
            ),
            Surface::NewMessage,
            "unknown-item ci-failed must surface as NewMessage regardless of override"
        );

        // dedup_hit=true on a managed kind, WITH any override present -> Drop,
        // never the override.
        let ds_dedup = json!({
            "kinds": { "github.issue-opened": { "surface": "thread_post" } }
        });
        let env_issue = env_with("github.issue-opened", "");
        assert_eq!(
            decide(
                "github.issue-opened",
                &env_issue,
                false,
                true,
                true,
                &ds_dedup
            ),
            Surface::Drop,
            "dedup hit must win over any per-kind override"
        );
    }

    #[test]
    fn surface_from_str_variants() {
        assert_eq!(surface_from_str("NewMessage"), Some(Surface::NewMessage));
        assert_eq!(surface_from_str("edit_summary"), Some(Surface::EditSummary));
        assert_eq!(
            surface_from_str("edit-and-thread"),
            Some(Surface::EditAndThread)
        );
        assert_eq!(surface_from_str("DROP"), Some(Surface::Drop));
        assert_eq!(surface_from_str("nonsense"), None);
    }
}
