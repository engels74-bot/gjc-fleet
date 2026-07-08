#!/usr/bin/env bash
# policy-deferred-mark.test.sh — P1 #10 proof for the B-2 one-review policy.
#
# ASSERTS the deferred-mark invariant of review-detector.sh's policy lane: two poll
# cycles racing on review-<repo>.lock for the SAME automated-author PR consume the first
# review EXACTLY ONCE (exactly one `<repo>#<pr>#consumed` marker; exactly one handler
# launch). Covers both hostile interleavings:
#
#   Phase 1 — a second poller runs WHILE the first holds the lock  -> deferred (no mark).
#   Phase 2 — a second poller runs AFTER the first released the lock -> in-lock review-id
#             re-check short-circuits it (no second mark).
#
# No network, no gh, no real handler: the detector is sourced (REVIEW_DETECTOR_NO_MAIN=1)
# and its policy_first_consume() is driven directly with a stub RUNNER + a FIFO barrier
# that makes the lock-window race deterministic (POLICY_TEST_HOLD).
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIFO="$TMP/barrier.fifo"
LAUNCHES="$TMP/launches.log"
mkfifo "$FIFO"
: >"$LAUNCHES"

# Stub RUNNER: record each launch invocation; never touch the network.
cat >"$TMP/runner-stub.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAUNCHES"
exit 0
EOF
chmod 755 "$TMP/runner-stub.sh"

# Locate the detector relative to this test file.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="$HERE/../review-detector.sh"

# Env: isolate all state under $TMP; source the detector as a library.
export GJC_BOT_STATE="$TMP"
export REVIEW_SEEN="$TMP/reviews.jsonl"
export REVIEW_POLICY_LEDGER="$TMP/review-policy.jsonl"
export REVIEW_RUN_BIN="$TMP/runner-stub.sh"
export REVIEW_REPOS="testrepo"
export GJC_BOT_GH_ROOT="$TMP/gh-root"        # empty -> list_bot_repos yields nothing
export REVIEW_AUTOMATED_AUTHORS="renovate[bot] dependabot[bot]"
export REVIEW_POLICY_MAX_HANDLER_RUNS="2"
export DRY_RUN="0"
export REVIEW_DETECTOR_NO_MAIN="1"
mkdir -p "$GJC_BOT_GH_ROOT"

# shellcheck source=/dev/null
source "$DETECTOR"

REPO="testrepo" PR="42" RID="1001"
LEDGER="$REVIEW_POLICY_LEDGER"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── Phase 1: race — poller B runs while poller A holds the lock ───────────────────────────
# A: acquires review-<repo>.lock, marks #consumed, launches, then blocks on the FIFO
#    (lock still held) until we release it.
POLICY_TEST_HOLD="$FIFO" policy_first_consume "$REPO" "$PR" "$RID" &
A_PID=$!

# Wait until A has launched (proves it is now parked at the barrier, still holding the lock).
for _ in $(seq 1 100); do
  [ "$(wc -l <"$LAUNCHES")" -ge 1 ] && break
  sleep 0.05
done
[ "$(wc -l <"$LAUNCHES")" -ge 1 ] || fail "poller A never launched — cannot establish the lock-window race"

# B: runs now, contending for the SAME lock while A holds it. Must defer (no mark, no launch).
policy_first_consume "$REPO" "$PR" "$RID"

consumed_during_race="$(ledger_count "$LEDGER" "${REPO}#${PR}#consumed")"
[ "$consumed_during_race" -eq 1 ] || fail "expected exactly 1 #consumed during the race, got $consumed_during_race"

# Release A from the barrier and reap it.
printf 'go\n' >"$FIFO"
wait "$A_PID"

# ── Phase 2: late acquirer — poller B' runs AFTER A released the lock ─────────────────────
# The in-lock review-id re-check (seen "$key") must short-circuit it: still no second mark.
policy_first_consume "$REPO" "$PR" "$RID"

# ── Assertions ───────────────────────────────────────────────────────────────────────────
consumed="$(ledger_count "$LEDGER" "${REPO}#${PR}#consumed")"
launches="$(wc -l <"$LAUNCHES" | tr -d ' ')"
deferred="$(grep -c 'deferred (lock busy)' "$TMP/review.log" 2>/dev/null || echo 0)"

echo "----- deferred-mark invariant assertions -----"
echo "#consumed markers : $consumed   (expected 1)"
echo "handler launches  : $launches   (expected 1)"
echo "deferred logs      : $deferred   (expected >=1)"
echo "ledger entries:"
grep -F "${REPO}#${PR}#consumed" "$LEDGER" 2>/dev/null || true

[ "$consumed" -eq 1 ] || fail "deferred-mark invariant VIOLATED: expected exactly 1 #consumed marker, got $consumed"
[ "$launches" -eq 1 ] || fail "expected exactly 1 handler launch, got $launches"
[ "$deferred" -ge 1 ] || fail "expected the racing poller to log 'deferred (lock busy)'"

echo "PASS: exactly one #consumed marker and one launch under a concurrent lock-window race (P1 #10)."
exit 0
