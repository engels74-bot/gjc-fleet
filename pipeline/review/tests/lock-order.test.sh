#!/usr/bin/env bash
# lock-order.test.sh — K1 proof for the shared per-repo lock (Fork 5 Opt B) and its
# deadlock-freedom-by-construction. Two flavours of assertion, clearly labelled:
#
#   STATIC  — grep the scripts' SOURCE for the lock-acquisition invariants. Used because the
#             real _handler bodies cannot run offline: review-run.sh's _handler drives a LIVE
#             coding-engine (engine_run) and ci-fixer-run.sh's drives a live run + `git
#             ls-remote`, neither of which exists in a hermetic test. The locking ORDER,
#             however, is fully determined by the source text, so it is asserted there.
#   SIMULATED — a real flock race on a `review-<repo>.lock` path, proving mutual exclusion
#             for the same repo and independence across repos (the property the per-repo lock
#             actually buys the shared fleet/review/<repo> tree).
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_RUN="$HERE/../review-run.sh"
CIFIXER_RUN="$HERE/../ci-fixer-run.sh"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "===== K1 lock-order invariants ====="

# ── STATIC (a) — ci-fixer-run.sh takes the PER-REPO lock and NEVER the global review.lock ──
# Deadlock-free by construction: since ci-fixer-run never blocking-acquires the global lock,
# review-run's GLOBAL(fd9)->PER-REPO(fd8) order can never form a wait cycle with it.
grep -Fq 'review-${repo}.lock' "$CIFIXER_RUN" \
  || fail "STATIC(a): ci-fixer-run.sh should reference the per-repo review-\${repo}.lock"
# The global lock is named via the $REVIEW_LOCK variable everywhere it is ACQUIRED
# (review-run.sh / review-detector.sh / merge-gate.sh). ci-fixer-run must not use it at all.
if grep -Fq 'REVIEW_LOCK' "$CIFIXER_RUN"; then
  fail "STATIC(a): ci-fixer-run.sh must NOT reference the global \$REVIEW_LOCK (would risk a cycle)"
fi
echo "STATIC(a) OK: ci-fixer-run.sh uses only review-\${repo}.lock; no global \$REVIEW_LOCK acquire."

# ── STATIC (b) — review-run.sh _handler acquires BOTH locks, GLOBAL(fd9) before PER-REPO(fd8) ─
grep -Fq 'exec 9>"$REVIEW_LOCK"' "$REVIEW_RUN" \
  || fail "STATIC(b): review-run.sh should open the global review.lock on fd 9"
grep -Fq '"$FLOCK" -n 9' "$REVIEW_RUN" \
  || fail "STATIC(b): review-run.sh should acquire the global lock NON-BLOCKING on fd 9"
grep -Fq 'review-${repo}.lock' "$REVIEW_RUN" \
  || fail "STATIC(b): review-run.sh should reference the per-repo review-\${repo}.lock"
grep -Fq 'exec 8>"$rlock"' "$REVIEW_RUN" \
  || fail "STATIC(b): review-run.sh should open the per-repo lock on fd 8"
grep -Fq '"$FLOCK" 8' "$REVIEW_RUN" \
  || fail "STATIC(b): review-run.sh should acquire the per-repo lock BLOCKING on fd 8"

ln_global="$(grep -nF 'exec 9>"$REVIEW_LOCK"' "$REVIEW_RUN" | head -1 | cut -d: -f1)"
ln_repo="$(grep -nF 'exec 8>"$rlock"' "$REVIEW_RUN" | head -1 | cut -d: -f1)"
[ -n "$ln_global" ] && [ -n "$ln_repo" ] || fail "STATIC(b): could not locate both fd opens"
[ "$ln_global" -lt "$ln_repo" ] \
  || fail "STATIC(b): global lock (line $ln_global) must be acquired BEFORE per-repo (line $ln_repo)"
echo "STATIC(b) OK: global fd9 acquire (line $ln_global) precedes per-repo fd8 acquire (line $ln_repo)."

# ── STATIC (d) — the shared-tree mutation (ensure_checkout) runs UNDER the per-repo lock ─────
# The corruption primitive is ensure_checkout's `git fetch` / `git checkout -f` on the shared
# fleet/review/<repo> tree. K1 only closes the race if that runs INSIDE the per-repo lock, not in
# the launcher — otherwise a review launcher (gated only on the global lock) could checkout the
# tree while a ci-fixer handler holds only the per-repo lock and is mid-commit. Assert both
# lanes call ensure_checkout EXACTLY ONCE, AFTER their per-repo lock acquire.
ln_rr_checkout="$(grep -nF 'ensure_checkout "$repo"' "$REVIEW_RUN" | head -1 | cut -d: -f1)"
[ -n "$ln_rr_checkout" ] || fail 'STATIC(d): review-run.sh should call ensure_checkout "$repo"'
[ "$ln_rr_checkout" -gt "$ln_repo" ] \
  || fail "STATIC(d): review-run.sh ensure_checkout (line $ln_rr_checkout) must run AFTER the per-repo lock (line $ln_repo)"
[ "$(grep -cF 'ensure_checkout "$repo"' "$REVIEW_RUN")" -eq 1 ] \
  || fail "STATIC(d): review-run.sh must call ensure_checkout exactly once (in _handler, under the lock — not the launcher)"

ln_cf_lock="$(grep -nF '"$FLOCK" 9' "$CIFIXER_RUN" | head -1 | cut -d: -f1)"
ln_cf_checkout="$(grep -nF 'ensure_checkout "$repo"' "$CIFIXER_RUN" | head -1 | cut -d: -f1)"
[ -n "$ln_cf_lock" ] && [ -n "$ln_cf_checkout" ] || fail "STATIC(d): could not locate ci-fixer-run per-repo lock + checkout"
[ "$ln_cf_checkout" -gt "$ln_cf_lock" ] \
  || fail "STATIC(d): ci-fixer-run.sh ensure_checkout (line $ln_cf_checkout) must run AFTER the per-repo lock (line $ln_cf_lock)"
[ "$(grep -cF 'ensure_checkout "$repo"' "$CIFIXER_RUN")" -eq 1 ] \
  || fail "STATIC(d): ci-fixer-run.sh must call ensure_checkout exactly once (in _handler, under the lock — not the launcher)"
echo "STATIC(d) OK: ensure_checkout runs under the per-repo lock in both lanes (checkout inside the mutation window)."

# ── SIMULATED (c) — real flock proves per-repo mutual exclusion + cross-repo independence ──
RLOCK_A="$TMP/review-repoA.lock"
RLOCK_B="$TMP/review-repoB.lock"

# A holder grabs repoA's lock BLOCKING and keeps it for the window below.
"$FLOCK" "$RLOCK_A" sleep 5 &
HOLDER=$!
sleep 0.3                                   # let the holder acquire it

# Same repo: a second non-blocking acquire MUST fail (cannot mutate the tree concurrently).
if "$FLOCK" -n "$RLOCK_A" true; then
  kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
  fail "SIMULATED(c): review-repoA.lock was acquirable while held — mutual exclusion broken"
fi

# Different repo: its lock is INDEPENDENT and MUST be acquirable in parallel.
if ! "$FLOCK" -n "$RLOCK_B" true; then
  kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
  fail "SIMULATED(c): review-repoB.lock should be independent of repoA but was blocked"
fi

kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
echo "SIMULATED(c) OK: same-repo lock is mutually exclusive; different-repo locks are independent."

echo "PASS: K1 global->per-repo order is source-verified and per-repo mutual exclusion holds."
exit 0
