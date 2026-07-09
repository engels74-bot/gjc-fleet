#!/usr/bin/env bash
# policy-rearm.test.sh — Workstream D proof for the review policy lane's FORCE-PUSH re-arm.
#
# ASSERTS review-detector.sh's policy_rearm_check()/policy_rearm_launch() decision logic: when
# an automated-author force-pushes the PR branch and rebases away a sha the fleet already acted
# on (recorded as #policy-pushed:<sha>), the detector re-arms the handler exactly once per head
# lineage, bounded by REVIEW_POLICY_MAX_REARMS, and escalates once when the cap is hit.
#
#   (a) #policy-pushed sha DIVERGED from head -> exactly one re-arm launch + one #rearm:<head>
#   (b) re-run with the SAME head            -> NO second re-arm (per-head dedup)
#   (c) cap REVIEW_POLICY_MAX_REARMS reached  -> escalate ONCE (#rearm-exhausted), no launches
#   (d) head_contains API failure             -> DEFER (no re-arm, no marker)
#   (e) contained/identical head              -> no re-arm
#
# No network, no real handler: the detector is sourced (REVIEW_DETECTOR_NO_MAIN=1) and its
# re-arm functions are driven directly, with a stubbed gh (compare + reviews endpoints), a
# stubbed RUNNER, an overridden pr_head_sha, and the REAL ledger isolated under $TMP.
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LAUNCHES="$TMP/launches.log"
: >"$LAUNCHES"

# Stub RUNNER: record each launch invocation; never touch the network.
cat >"$TMP/runner-stub.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAUNCHES"
exit 0
EOF
chmod 755 "$TMP/runner-stub.sh"

# Stub gh: route the two endpoints head_contains + latest_suggestion_review hit.
#   */compare/*  -> {"status":"<STUB_COMPARE_STATUS>"}  (or exit 1 when STUB_COMPARE_FAIL=1)
#   */reviews    -> STUB_REVIEWS_JSON (a one-review array carrying suggestions)
cat >"$TMP/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
arg="$*"
case "$arg" in
  *"/compare/"*)
    [ "${STUB_COMPARE_FAIL:-0}" = "1" ] && exit 1
    printf '{"status":"%s"}\n' "${STUB_COMPARE_STATUS:-identical}" ;;
  *"/reviews"*)
    printf '%s\n' "${STUB_REVIEWS_JSON:-[]}" ;;
  *) exit 0 ;;
esac
exit 0
EOF
chmod 755 "$TMP/gh-stub.sh"

# Locate the detector relative to this test file.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="$HERE/../review-detector.sh"

# Env: isolate all state under $TMP; source the detector as a library.
export GJC_BOT_STATE="$TMP"
export REVIEW_SEEN="$TMP/reviews.jsonl"
export REVIEW_POLICY_LEDGER="$TMP/review-policy.jsonl"
export REVIEW_RUN_BIN="$TMP/runner-stub.sh"
export GH_BIN="$TMP/gh-stub.sh"
export REVIEW_REPOS="testrepo"
export GJC_BOT_GH_ROOT="$TMP/gh-root"        # empty -> list_bot_repos yields nothing
export GJC_BOT_GH_OWNER="engels74"
export REVIEW_AUTOMATED_AUTHORS="renovate[bot] dependabot[bot]"
export REVIEW_POLICY_MAX_REARMS="2"
export DRY_RUN="0"
export REVIEW_DETECTOR_NO_MAIN="1"
mkdir -p "$GJC_BOT_GH_ROOT"

# shellcheck source=/dev/null
source "$DETECTOR"

# A one-review array carrying suggestions, so latest_suggestion_review yields rid 1001.
export STUB_REVIEWS_JSON='[{"id":1001,"user":{"login":"augmentcode[bot]"},"body":"1 suggestion posted"}]'

# Override pr_head_sha (which would otherwise git ls-remote): return the staged head sha.
STUB_HEAD=""
pr_head_sha() { printf '%s' "$STUB_HEAD"; }

# head_contains reads these via the gh-stub SUBPROCESS, so they must be exported. Exporting
# once carries the attribute across every later reassignment below.
export STUB_COMPARE_STATUS="identical" STUB_COMPARE_FAIL="0"

REPO="testrepo" PR="42"
LEDGER="$REVIEW_POLICY_LEDGER"
PSHA="00000000000000000000000000000000000000a1"   # the sha we last acted on
HEAD_A="00000000000000000000000000000000000000b2"
HEAD_B="00000000000000000000000000000000000000c3"
HEAD_C="00000000000000000000000000000000000000d4"
HEAD_D="00000000000000000000000000000000000000e5"
HEAD_E="00000000000000000000000000000000000000f6"

fail() { echo "FAIL: $*" >&2; exit 1; }
reset_ledger() { : >"$LEDGER"; : >"$LAUNCHES"; rm -f "$TMP/review.log"; }
launches() { wc -l <"$LAUNCHES" | tr -d ' '; }

echo "===== policy re-arm (force-push resilience) assertions ====="

# ── (a) diverged head -> exactly one re-arm launch + one #rearm:<head> marker ──────────────
reset_ledger
ledger_mark "$LEDGER" "${REPO}#${PR}#policy-pushed:${PSHA}"
STUB_COMPARE_STATUS="diverged"; STUB_HEAD="$HEAD_A"
policy_rearm_check "$REPO" "$PR"
a_launch="$(launches)"
a_rearm="$(ledger_count "$LEDGER" "${REPO}#${PR}#rearm:")"
a_marker="$(ledger_seen "$LEDGER" "${REPO}#${PR}#rearm:${HEAD_A}" && echo yes || echo no)"
echo "(a) launches=$a_launch  #rearm=$a_rearm  #rearm:$HEAD_A=$a_marker  (expect 1/1/yes)"
[ "$a_launch" -eq 1 ]  || fail "(a) expected exactly 1 re-arm launch, got $a_launch"
[ "$a_rearm" -eq 1 ]   || fail "(a) expected exactly 1 #rearm marker, got $a_rearm"
[ "$a_marker" = "yes" ] || fail "(a) expected the #rearm:$HEAD_A dedup marker"

# ── (b) re-run with the SAME head -> NO second re-arm (per-head dedup) ─────────────────────
# (continues from (a): the #rearm:$HEAD_A marker is present)
policy_rearm_check "$REPO" "$PR"
b_launch="$(launches)"
b_rearm="$(ledger_count "$LEDGER" "${REPO}#${PR}#rearm:")"
echo "(b) launches=$b_launch  #rearm=$b_rearm  (expect 1/1 — dedup, unchanged)"
[ "$b_launch" -eq 1 ] || fail "(b) same head must not re-arm again, launches=$b_launch"
[ "$b_rearm" -eq 1 ]  || fail "(b) same head must not add a #rearm marker, got $b_rearm"

# ── (c) cap REVIEW_POLICY_MAX_REARMS reached -> escalate ONCE, no launches ─────────────────
reset_ledger
ledger_mark "$LEDGER" "${REPO}#${PR}#policy-pushed:${PSHA}"
# Pre-seed the cap (max_rearms=2) with two prior distinct-head re-arms.
ledger_mark "$LEDGER" "${REPO}#${PR}#rearm:${HEAD_A}"
ledger_mark "$LEDGER" "${REPO}#${PR}#rearm:${HEAD_B}"
STUB_COMPARE_STATUS="diverged"; STUB_HEAD="$HEAD_C"     # a third, distinct diverged head
policy_rearm_check "$REPO" "$PR"                        # -> cap hit, escalate once
policy_rearm_check "$REPO" "$PR"                        # -> already escalated, no repeat
c_launch="$(launches)"
c_exhausted="$(ledger_count "$LEDGER" "${REPO}#${PR}#rearm-exhausted")"
c_logs="$(grep -c 'rearm EXHAUSTED' "$TMP/review.log" 2>/dev/null || echo 0)"
echo "(c) launches=$c_launch  #rearm-exhausted=$c_exhausted  EXHAUSTED logs=$c_logs  (expect 0/1/1)"
[ "$c_launch" -eq 0 ]    || fail "(c) cap reached must not launch, got $c_launch"
[ "$c_exhausted" -eq 1 ] || fail "(c) expected exactly 1 #rearm-exhausted marker, got $c_exhausted"
[ "$c_logs" -eq 1 ]      || fail "(c) expected exactly 1 EXHAUSTED escalation log, got $c_logs"

# ── (d) head_contains API failure -> DEFER (no re-arm, no marker) ──────────────────────────
reset_ledger
ledger_mark "$LEDGER" "${REPO}#${PR}#policy-pushed:${PSHA}"
STUB_COMPARE_FAIL="1"; STUB_HEAD="$HEAD_D"
policy_rearm_check "$REPO" "$PR"
STUB_COMPARE_FAIL="0"
d_launch="$(launches)"
d_rearm="$(ledger_count "$LEDGER" "${REPO}#${PR}#rearm:")"
d_defer="$(grep -c 'rearm defer (head_contains API failure)' "$TMP/review.log" 2>/dev/null || echo 0)"
echo "(d) launches=$d_launch  #rearm=$d_rearm  defer logs=$d_defer  (expect 0/0/>=1)"
[ "$d_launch" -eq 0 ] || fail "(d) API failure must DEFER, not launch (got $d_launch)"
[ "$d_rearm" -eq 0 ]  || fail "(d) API failure must not write a #rearm marker (got $d_rearm)"
[ "$d_defer" -ge 1 ]  || fail "(d) expected a 'defer (head_contains API failure)' log line"

# ── (e) contained/identical head -> no re-arm ─────────────────────────────────────────────
reset_ledger
ledger_mark "$LEDGER" "${REPO}#${PR}#policy-pushed:${PSHA}"
STUB_COMPARE_STATUS="identical"; STUB_HEAD="$HEAD_E"
policy_rearm_check "$REPO" "$PR"
e_launch="$(launches)"
e_rearm="$(ledger_count "$LEDGER" "${REPO}#${PR}#rearm:")"
echo "(e) launches=$e_launch  #rearm=$e_rearm  (expect 0/0 — contained, no advance)"
[ "$e_launch" -eq 0 ] || fail "(e) contained head must not re-arm, got $e_launch"
[ "$e_rearm" -eq 0 ]  || fail "(e) contained head must not write a #rearm marker, got $e_rearm"

# ── (f) no #policy-pushed marker at all -> fast no-op ──────────────────────────────────────
reset_ledger
STUB_COMPARE_STATUS="diverged"; STUB_HEAD="$HEAD_A"
policy_rearm_check "$REPO" "$PR"
f_launch="$(launches)"
echo "(f) launches=$f_launch  (expect 0 — nothing armed for this PR)"
[ "$f_launch" -eq 0 ] || fail "(f) unarmed PR must not re-arm, got $f_launch"

# ── (g) REGRESSION GUARD: head merely AHEAD of psha (normal renovate/CI commit ON TOP) ──────
#      psha is still an ANCESTOR of head => contained => must NOT re-arm. A prior mapping bug
#      treated `ahead` as an advance and would have re-armed spuriously on EVERY normal commit.
reset_ledger
ledger_mark "$LEDGER" "${REPO}#${PR}#policy-pushed:${PSHA}"
STUB_COMPARE_STATUS="ahead"; STUB_HEAD="$HEAD_B"
policy_rearm_check "$REPO" "$PR"
g_launch="$(launches)"
g_rearm="$(ledger_count "$LEDGER" "${REPO}#${PR}#rearm:")"
echo "(g) launches=$g_launch  #rearm=$g_rearm  (expect 0/0 — 'ahead' = contained, no re-arm)"
[ "$g_launch" -eq 0 ] || fail "(g) 'ahead' head is contained; must NOT re-arm, got $g_launch"
[ "$g_rearm" -eq 0 ]  || fail "(g) 'ahead' head must not write a #rearm marker, got $g_rearm"

# ── (h) head BEHIND psha (psha not an ancestor of head) -> NOT contained -> re-arm ──────────
reset_ledger
ledger_mark "$LEDGER" "${REPO}#${PR}#policy-pushed:${PSHA}"
STUB_COMPARE_STATUS="behind"; STUB_HEAD="$HEAD_C"
policy_rearm_check "$REPO" "$PR"
h_launch="$(launches)"
h_rearm="$(ledger_count "$LEDGER" "${REPO}#${PR}#rearm:")"
echo "(h) launches=$h_launch  #rearm=$h_rearm  (expect 1/1 — 'behind' = not contained, re-arm)"
[ "$h_launch" -eq 1 ] || fail "(h) 'behind' head is not contained; must re-arm, got $h_launch"
[ "$h_rearm" -eq 1 ]  || fail "(h) 'behind' head must write one #rearm marker, got $h_rearm"

echo "PASS: re-arm fires on diverged+behind (not contained), stays quiet on identical+ahead (contained), dedups per head, caps+escalates once, defers on API failure."
exit 0
