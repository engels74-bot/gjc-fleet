#!/usr/bin/env bash
# automerge-gh-probe.test.sh — MUST-FIX (G-F1, PM1 mitigation). Proves the automerge poller
# FAILS CLOSED when the host `gh` cannot server-verify the merge head: if `gh pr merge --help`
# does NOT advertise --match-head-commit, the poller refuses ALL merges this pass, emits EXACTLY
# ONE automerge.escalation, calls `gh pr merge` ZERO times, and records ZERO #try.
#
# The poller is sourced (AUTOMERGE_NO_MAIN=1) and capability_ok_or_escalate() is driven directly
# with a gh stub whose `pr merge --help` output lacks the flag + a stubbed discord_embed.
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../automerge.sh"

LEDGER="$TMP/automerge.jsonl"
MERGES="$TMP/merges.log"
EMBEDS="$TMP/embeds.log"
: >"$MERGES"; : >"$EMBEDS"

# gh stub: `pr merge --help` advertises OTHER flags but NOT --match-head-commit (the exact PM1
# failure mode: an older/repackaged gh). Any real `pr merge` is logged so we can prove it never runs.
cat >"$TMP/gh-stub.sh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr merge --help"*) printf '      --auto\n      --squash\n      --delete-branch\n'; exit 0 ;;
  *"pr merge"*)        printf '%s\n' "\$*" >> "$MERGES"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 755 "$TMP/gh-stub.sh"

export GJC_BOT_STATE="$TMP"
export AUTOMERGE_LEDGER="$LEDGER"
export AUTOMERGE_LOG="$TMP/automerge.log"
export REVIEW_POLICY_LEDGER="$TMP/review-policy.jsonl"
export GH_BIN="$TMP/gh-stub.sh"
export GJC_BOT_GH_ROOT="$TMP/gh-root"
export AUTOMERGE_REPOS="testrepo"
export AUTOMERGE_ENABLED="1"
export MERGE_GATE_CHANNEL="approvals"
export DRY_RUN="0"
export AUTOMERGE_NO_MAIN="1"
mkdir -p "$GJC_BOT_GH_ROOT"

# shellcheck source=/dev/null
source "$POLLER"

discord_embed() { printf '%s\n' "$*" >> "$EMBEDS"; return 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "===== automerge gh-capability fail-closed assertions (G-F1) ====="

# First probe: capability ABSENT -> refuse (rc 1), emit exactly one escalation.
rc=0; capability_ok_or_escalate || rc=$?
[ "$rc" -eq 1 ] || fail "capability_ok_or_escalate must return non-zero when --match-head-commit is absent (got $rc)"

# Second probe in the same host-hour: deduped -> still exactly ONE escalation total.
capability_ok_or_escalate || true

escs="$(grep -c 'automerge.escalation' "$EMBEDS")"
mergecalls="$(wc -l <"$MERGES" | tr -d ' ')"
trymarks="$(grep -c '#try' "$LEDGER" 2>/dev/null || true)"

echo "escalations=$escs  gh-pr-merge-calls=$mergecalls  #try-marks=$trymarks  (expect 1/0/0)"
[ "$escs" -eq 1 ]       || fail "expected EXACTLY ONE automerge.escalation, got $escs"
[ "$mergecalls" -eq 0 ] || fail "fail-closed must NEVER call 'gh pr merge', got $mergecalls"
[ "$trymarks" -eq 0 ]   || fail "fail-closed must record ZERO #try, got $trymarks"

echo "PASS: gh without --match-head-commit -> fail-closed (one escalation, zero merges, zero #try, deduped)."
exit 0
