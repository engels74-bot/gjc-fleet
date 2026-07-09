#!/usr/bin/env bash
# automerge-approve.test.sh — proof for the gated bot self-approval seam (ensure_approved) in
# automerge.sh. The poller is sourced (AUTOMERGE_NO_MAIN=1) with the REAL ledger isolated under
# $TMP + a gh stub whose `pr review` is logged (and toggleably failed); ensure_approved() is called
# directly. No network, no live PR, no real approval. Covers exactly what CAN be proven offline:
#
#   (off)   AUTOMERGE_APPROVE=0            -> no-op passthrough: returns 0, no gh call, no ledger write
#   (fresh) AUTOMERGE_APPROVE=1, new sha   -> one `gh pr review --approve`, records #approved:<sha>, rc 0
#   (dedup) AUTOMERGE_APPROVE=1, seen sha  -> returns 0 WITHOUT a second gh call (ledger short-circuit)
#   (fail)  AUTOMERGE_APPROVE=1, gh fails  -> returns 1, no #approved recorded (caller defers, no #try)
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../automerge.sh"

LEDGER="$TMP/automerge.jsonl"
REVIEWS="$TMP/reviews.log"
: >"$REVIEWS"

# gh stub: a `pr review` is logged so we can prove call count; it FAILS iff GH_REVIEW_FAIL=1 (the
# transient-failure case). `pr merge --help` still advertises --match-head-commit so sourcing is clean.
cat >"$TMP/gh-stub.sh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr merge --help"*) printf '      --match-head-commit string\n'; exit 0 ;;
  *"pr review"*)       printf '%s\n' "\$*" >> "$REVIEWS"; [ "\${GH_REVIEW_FAIL:-0}" = "1" ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 755 "$TMP/gh-stub.sh"

# Isolate ALL state under $TMP; source the poller as a library.
export GJC_BOT_STATE="$TMP"
export AUTOMERGE_LEDGER="$LEDGER"
export AUTOMERGE_LOG="$TMP/automerge.log"
export REVIEW_POLICY_LEDGER="$TMP/review-policy.jsonl"
export GH_BIN="$TMP/gh-stub.sh"
export GJC_BOT_GH_ROOT="$TMP/gh-root"          # empty -> list_bot_repos yields nothing
export AUTOMERGE_REPOS="testrepo"
export AUTOMERGE_ENABLED="1"
export AUTOMERGE_APPROVE="0"    # per-case toggled below; exported so the sourced poller reads it
export DRY_RUN="0"
export AUTOMERGE_NO_MAIN="1"
mkdir -p "$GJC_BOT_GH_ROOT"

# shellcheck source=/dev/null
source "$POLLER"

FULL="engels74/testrepo"
SHA="00000000000000000000000000000000000000b2"

fail() { echo "FAIL: $*" >&2; exit 1; }
reset() { : >"$LEDGER"; : >"$REVIEWS"; rm -f "$TMP/automerge.log"; unset GH_REVIEW_FAIL; }
reviews() { wc -l <"$REVIEWS" | tr -d ' '; }

echo "===== automerge self-approval (ensure_approved) assertions ====="

# ── (off) AUTOMERGE_APPROVE=0 -> no-op passthrough ──────────────────────────────────────────
reset; AUTOMERGE_APPROVE="0"
rc=0; ensure_approved "$FULL" 501 "$SHA" || rc=$?
[ "$rc" -eq 0 ]        || fail "(off) no-op must return 0, got $rc"
[ "$(reviews)" -eq 0 ] || fail "(off) no-op must NOT call gh pr review, got $(reviews)"
[ "$(wc -l <"$LEDGER" | tr -d ' ')" -eq 0 ] || fail "(off) no-op must NOT write a ledger record"
echo "(off) AUTOMERGE_APPROVE=0 -> return 0, no gh call, no ledger write — OK"

# ── (fresh) AUTOMERGE_APPROVE=1, new sha -> one approve, records #approved:<sha> ─────────────
reset; AUTOMERGE_APPROVE="1"
rc=0; ensure_approved "$FULL" 502 "$SHA" || rc=$?
[ "$rc" -eq 0 ]        || fail "(fresh) must return 0 on approve success, got $rc"
[ "$(reviews)" -eq 1 ] || fail "(fresh) must call gh pr review exactly once, got $(reviews)"
grep -q -- '--approve' "$REVIEWS" || fail "(fresh) gh call must be a --approve review"
ledger_seen "$LEDGER" "${FULL}#pr:502#approved:${SHA}" || fail "(fresh) must record #approved:<sha>"
echo "(fresh) new sha -> one --approve, #approved:<sha> recorded, rc 0 — OK"

# ── (dedup) AUTOMERGE_APPROVE=1, sha already approved -> return 0, NO second gh call ─────────
reset; AUTOMERGE_APPROVE="1"
ledger_mark "$LEDGER" "${FULL}#pr:503#approved:${SHA}"
rc=0; ensure_approved "$FULL" 503 "$SHA" || rc=$?
[ "$rc" -eq 0 ]        || fail "(dedup) already-approved must return 0, got $rc"
[ "$(reviews)" -eq 0 ] || fail "(dedup) already-approved must NOT call gh again, got $(reviews)"
echo "(dedup) sha already in ledger -> return 0 without a second gh call — OK"

# ── (fail) AUTOMERGE_APPROVE=1, gh review fails -> return 1, no #approved recorded ───────────
reset; AUTOMERGE_APPROVE="1"; export GH_REVIEW_FAIL="1"
rc=0; ensure_approved "$FULL" 504 "$SHA" || rc=$?
[ "$rc" -eq 1 ]        || fail "(fail) gh failure must return 1, got $rc"
[ "$(reviews)" -eq 1 ] || fail "(fail) gh review must have been attempted once, got $(reviews)"
ledger_seen "$LEDGER" "${FULL}#pr:504#approved:${SHA}" && fail "(fail) must NOT record #approved on failure"
unset GH_REVIEW_FAIL
echo "(fail) gh review fails -> return 1, no #approved recorded — OK"

echo "PASS: AUTOMERGE_APPROVE=0 no-op, a fresh sha approval, per-sha dedup, and a transient approve failure all hold."
exit 0
