#!/usr/bin/env bash
# ci-fixer-caps-backoff.test.sh — B-3 proof for the fix-until-green poller's PURE guardrail
# logic (ci-fixer.sh), driven with a mocked ledger + stubbed ci_state / gh / runner / embed.
# No network, no live PR, no real coding-engine run: the poller is sourced (CI_FIXER_NO_MAIN=1)
# and consider_pr() is called directly per case. Covers exactly what CAN be tested offline:
#
#   (a) RED under caps + enough backoff elapsed -> would-launch (records BOTH #try keys, one run)
#   (b) per-sha cap reached                     -> terminal give-up, taken EXACTLY ONCE (dedup)
#   (c) backoff not elapsed                     -> skip (no new attempt, no run)
#   (d) GREEN / PENDING                          -> zero fixer records, no run
#   (e) per-repo lock busy                       -> deferred (no attempt, no run)
#
# The live termination proofs (a real trivially-fixable RED going green; a real unfixable RED
# walking the backoff/caps to a single escalation; a real concurrent-launch deferral) are
# DEPLOY-phase — see docs/40's runbook — and are deliberately NOT faked here.
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../ci-fixer.sh"

LEDGER="$TMP/ci-fixer.jsonl"
LAUNCHES="$TMP/launches.log"
EMBEDS="$TMP/embeds.log"
: >"$LAUNCHES"; : >"$EMBEDS"

# Runner stub: record each launch; never touch the network.
cat >"$TMP/runner-stub.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAUNCHES"
exit 0
EOF
chmod 755 "$TMP/runner-stub.sh"

# gh stub: swallow every call (give_up's \`gh pr comment\` succeeds) with no network.
cat >"$TMP/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$TMP/gh-stub.sh"

# Isolate ALL state under $TMP; source the poller as a library.
export GJC_BOT_STATE="$TMP"
export CI_FIXER_LEDGER="$LEDGER"
export CI_FIXER_LOG="$TMP/ci-fixer.log"
export CI_FIXER_RUN_BIN="$TMP/runner-stub.sh"
export GH_BIN="$TMP/gh-stub.sh"
export GJC_BOT_GH_ROOT="$TMP/gh-root"          # empty -> list_bot_repos yields nothing
export CI_FIXER_REPOS="testrepo"               # main() is never called; avoids the scan anyway
export CI_FIXER_ENABLED="1"
export CI_FIXER_MAX_PER_SHA="2"
export CI_FIXER_MAX_PER_PR="5"
export CI_FIXER_BACKOFF_BASE_MINS="10"
export CI_FIX_NOTIFY_CHANNEL="events"
export CI_FIX_ESCALATE_CHANNEL="approvals"
export DRY_RUN="0"
export CI_FIXER_NO_MAIN="1"
mkdir -p "$GJC_BOT_GH_ROOT"

# shellcheck source=/dev/null
source "$POLLER"

# ── stubs (override the impure calls AFTER sourcing) ──────────────────────────────────────
STUB_STATE="RED"
ci_state()       { printf '%s' "$STUB_STATE"; }
ci_red_summary() { printf -- '- build: failure\n- test: failure'; }
discord_embed()  { printf '%s\n' "$*" >> "$EMBEDS"; return 0; }

REPO="testrepo" FULL="engels74/testrepo"
fail() { echo "FAIL: $*" >&2; exit 1; }
reset_ledger() { : >"$LEDGER"; : >"$LAUNCHES"; : >"$EMBEDS"; }

echo "===== ci-fixer caps + backoff guardrail assertions ====="

# ── (a) RED under caps + backoff elapsed -> would-launch (records BOTH #try keys) ─────────
reset_ledger
STUB_STATE="RED"
SHA_A="a000000000000000000000000000000000000001"
consider_pr "$REPO" "$FULL" "101" "$SHA_A"
pr_try="$(ledger_count "$LEDGER" "${FULL}#pr:101#try")"
sha_try="$(ledger_count "$LEDGER" "${FULL}#sha:${SHA_A}#try")"
launches="$(wc -l <"$LAUNCHES" | tr -d ' ')"
echo "(a) pr #try=$pr_try  sha #try=$sha_try  launches=$launches  (expect 1/1/1)"
[ "$pr_try" -eq 1 ]  || fail "(a) expected 1 per-pr #try, got $pr_try"
[ "$sha_try" -eq 1 ] || fail "(a) expected 1 per-sha #try, got $sha_try"
[ "$launches" -eq 1 ] || fail "(a) expected exactly 1 run launch, got $launches"

# ── (b) per-sha cap reached -> give-up EXACTLY ONCE (dedup on re-run) ─────────────────────
reset_ledger
STUB_STATE="RED"
SHA_B="b000000000000000000000000000000000000002"
# Pre-seed the per-sha cap (max_per_sha=2) so the very next poll must give up.
ledger_mark "$LEDGER" "${FULL}#sha:${SHA_B}#try"
ledger_mark "$LEDGER" "${FULL}#sha:${SHA_B}#try"
consider_pr "$REPO" "$FULL" "102" "$SHA_B"      # -> give up (mark #gaveup, post comment)
consider_pr "$REPO" "$FULL" "102" "$SHA_B"      # -> already gave up, no second escalation
gaveup="$(ledger_count "$LEDGER" "${FULL}#pr:102#gaveup")"
gave_logs="$(grep -c 'GAVE UP' "$TMP/ci-fixer.log" 2>/dev/null || echo 0)"
new_try="$(ledger_count "$LEDGER" "${FULL}#pr:102#try")"
launches="$(wc -l <"$LAUNCHES" | tr -d ' ')"
echo "(b) #gaveup=$gaveup  'GAVE UP' logs=$gave_logs  pr #try=$new_try  launches=$launches  (expect 1/1/0/0)"
[ "$gaveup" -eq 1 ]    || fail "(b) expected exactly 1 #gaveup marker, got $gaveup"
[ "$gave_logs" -eq 1 ] || fail "(b) expected the give-up path taken exactly once, got $gave_logs"
[ "$new_try" -eq 0 ]   || fail "(b) give-up must not record a fix attempt, got $new_try"
[ "$launches" -eq 0 ]  || fail "(b) give-up must not launch a run, got $launches"

# ── (c) backoff not elapsed -> skip (no new attempt, no run) ──────────────────────────────
reset_ledger
STUB_STATE="RED"
SHA_C="c000000000000000000000000000000000000003"
ledger_mark "$LEDGER" "${FULL}#pr:103#try"      # one prior attempt, ts = now => min wait 20m
consider_pr "$REPO" "$FULL" "103" "$SHA_C"
pr_try="$(ledger_count "$LEDGER" "${FULL}#pr:103#try")"
launches="$(wc -l <"$LAUNCHES" | tr -d ' ')"
echo "(c) pr #try=$pr_try  launches=$launches  (expect 1/0 — unchanged, deferred by backoff)"
[ "$pr_try" -eq 1 ]   || fail "(c) backoff skip must not add a #try, got $pr_try"
[ "$launches" -eq 0 ] || fail "(c) backoff skip must not launch, got $launches"

# ── (d) GREEN / PENDING -> zero fixer records ────────────────────────────────────────────
for state in GREEN PENDING; do
  reset_ledger
  STUB_STATE="$state"
  SHA_D="d0000000000000000000000000000000000000${state:0:2}"
  consider_pr "$REPO" "$FULL" "104" "$SHA_D"
  recs="$(wc -l <"$LEDGER" | tr -d ' ')"
  launches="$(wc -l <"$LAUNCHES" | tr -d ' ')"
  echo "(d/$state) ledger records=$recs  launches=$launches  (expect 0/0)"
  [ "$recs" -eq 0 ]     || fail "(d/$state) expected zero fixer records, got $recs"
  [ "$launches" -eq 0 ] || fail "(d/$state) expected no launch, got $launches"
done

# ── (e) per-repo lock busy -> deferred (no attempt, no run) ───────────────────────────────
reset_ledger
STUB_STATE="RED"
SHA_E="e000000000000000000000000000000000000005"
LOCK="$TMP/review-${REPO}.lock"
"$FLOCK" "$LOCK" sleep 5 &                        # hold review-<repo>.lock BLOCKING
HOLDER=$!
sleep 0.3                                         # let the holder acquire the lock
consider_pr "$REPO" "$FULL" "105" "$SHA_E"
pr_try="$(ledger_count "$LEDGER" "${FULL}#pr:105#try")"
launches="$(wc -l <"$LAUNCHES" | tr -d ' ')"
deferred="$(grep -c 'busy' "$TMP/ci-fixer.log" 2>/dev/null || echo 0)"
kill "$HOLDER" 2>/dev/null || true; wait "$HOLDER" 2>/dev/null || true
echo "(e) pr #try=$pr_try  launches=$launches  'busy' logs=$deferred  (expect 0/0/>=1)"
[ "$pr_try" -eq 0 ]   || fail "(e) lock-busy defer must not record a #try, got $pr_try"
[ "$launches" -eq 0 ] || fail "(e) lock-busy defer must not launch, got $launches"
[ "$deferred" -ge 1 ] || fail "(e) expected a 'busy' defer log line"

echo "PASS: caps, backoff, give-up dedup, green/pending no-op, and lock-busy defer all hold."
exit 0
