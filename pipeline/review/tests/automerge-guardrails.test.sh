#!/usr/bin/env bash
# automerge-guardrails.test.sh — Workstream F proof for the automerge poller's PURE guardrail
# logic (automerge.sh), driven with the REAL ledger isolated under $TMP + stubbed impure seams
# (ci_state / head_contains / latest_suggestion_review / refetch_head_sha / pr_current_state /
# discord_embed) and a gh stub for `gh pr merge`. No network, no live PR, no real merge: the
# poller is sourced (AUTOMERGE_NO_MAIN=1) and consider_pr()/gate_open()/process_repo() are
# called directly. Covers exactly what CAN be proven offline:
#
#   (gate)   disabled / disable-marker / DRY_RUN      -> gate_open blocks, ZERO records
#   (defer)  non-GREEN (RED/PENDING/NONE/UNKNOWN) / draft / non-MERGEABLE / CHANGES_REQUESTED /
#            automerge-hold label / unconsumed-policy / diverged-policy-sha  -> no #try, no merge
#   (block)  policy #escalated                         -> terminal #blocked + one escalation, no #try
#   (stale)  HEAD moved inside the lock                -> no merge, no #try
#   (idem)   already MERGED on retry                   -> idempotent #merged, no #try, no merge
#   (cap)    #try cap reached                          -> single give-up (#blocked + escalation)
#   (merge)  fully eligible                            -> one #try, one #merged, one merge, one embed
#   (poll)   AUTOMERGE_MAX_PER_POLL honored            -> at most N merges per repo per poll
#
# The live merge proofs (a real renovate PR going green->merged; a real head-mismatch reject) are
# DEPLOY-phase and deliberately NOT faked here.
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../automerge.sh"

LEDGER="$TMP/automerge.jsonl"
MERGES="$TMP/merges.log"
EMBEDS="$TMP/embeds.log"
: >"$MERGES"; : >"$EMBEDS"

# gh stub: `pr merge --help` advertises --match-head-commit; a real `pr merge` is logged + succeeds.
cat >"$TMP/gh-stub.sh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr merge --help"*) printf '      --match-head-commit string\n'; exit 0 ;;
  *"pr merge"*)        printf '%s\n' "\$*" >> "$MERGES"; exit 0 ;;
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
export AUTOMERGE_METHOD="squash"
export AUTOMERGE_MIN_HEAD_AGE_MINS="10"
export AUTOMERGE_REVIEW_WAIT_MINS="30"
export AUTOMERGE_MAX_ATTEMPTS="3"
export AUTOMERGE_MAX_PER_POLL="1"
export REVIEW_AUTOMATED_AUTHORS="renovate[bot] dependabot[bot]"
export MERGE_GATE_CHANNEL="approvals"
export DRY_RUN="0"
export AUTOMERGE_NO_MAIN="1"
mkdir -p "$GJC_BOT_GH_ROOT"

# shellcheck source=/dev/null
source "$POLLER"

REPO="testrepo" FULL="engels74/testrepo"
PSHA="00000000000000000000000000000000000000a1"
SHA_OK="00000000000000000000000000000000000000b2"
SHA_MOVED="00000000000000000000000000000000000000c3"
NOW="$(date +%s)"; HEPOCH_OLD=$(( NOW - 100000 ))     # older than both the 10m + 30m windows

# ── stubs (override the impure seams AFTER sourcing) ──────────────────────────────────────
STUB_CI="GREEN";         ci_state()                { printf '%s' "$STUB_CI"; }
STUB_HC=0;               head_contains()           { return "$STUB_HC"; }
STUB_HAS_REVIEW=0;       latest_suggestion_review() { [ "$STUB_HAS_REVIEW" = "1" ] && { printf '{"id":9,"submitted_at":"2020-01-01T00:00:00Z"}'; return 0; }; return 1; }
STUB_REFETCH="$SHA_OK";  refetch_head_sha()        { printf '%s' "$STUB_REFETCH"; }
STUB_PRSTATE="OPEN";     pr_current_state()        { printf '%s' "$STUB_PRSTATE"; }
discord_embed()          { printf '%s\n' "$*" >> "$EMBEDS"; return 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
reset() { : >"$LEDGER"; : >"$MERGES"; : >"$EMBEDS"; rm -f "$TMP/automerge.log"; : >"$REVIEW_POLICY_LEDGER"; STUB_CI="GREEN"; STUB_HC=0; STUB_HAS_REVIEW=0; STUB_REFETCH="$SHA_OK"; STUB_PRSTATE="OPEN"; }
tries()  { ledger_count "$LEDGER" "${FULL}#pr:$1#try"; }
merges() { wc -l <"$MERGES" | tr -d ' '; }
assert_deferred() {  # <label> <pr>
  local t m; t="$(tries "$2")"; m="$(merges)"
  [ "$t" -eq 0 ] || fail "$1: expected 0 #try, got $t"
  [ "$m" -eq 0 ] || fail "$1: expected 0 merge calls, got $m"
}
elig() {  # <pr> [draft] [mergeable] [rdec] [has_hold]
  consider_pr "$REPO" "$FULL" "$1" "renovate[bot]" "${2:-false}" "${3:-MERGEABLE}" "${4:-}" "${5:-0}" "$SHA_OK" "$HEPOCH_OLD" || true
}

echo "===== automerge guardrail assertions ====="

# ── (gate) kill switches -> gate_open blocks, zero records ─────────────────────────────────
reset
AUTOMERGE_ENABLED="0"; gate_open && fail "(gate) disabled must block"; AUTOMERGE_ENABLED="1"
touch "$DISABLE_MARKER"; gate_open && fail "(gate) disable marker must block"; rm -f "$DISABLE_MARKER"
DRY_RUN="1"; gate_open && fail "(gate) DRY_RUN must block"; DRY_RUN="0"
[ "$(wc -l <"$LEDGER" | tr -d ' ')" -eq 0 ] || fail "(gate) gate checks must not write ledger records"
echo "(gate) disabled / marker / DRY_RUN all block gate_open, zero records — OK"

# ── (defer) non-GREEN CI -> no #try, no merge ─────────────────────────────────────────────
for st in RED PENDING NONE UNKNOWN; do
  reset; STUB_CI="$st"; elig 301; assert_deferred "non-GREEN/$st" 301
done
echo "(defer) RED/PENDING/NONE/UNKNOWN never merge, never #try — OK"

# ── (defer) static eligibility ────────────────────────────────────────────────────────────
reset; elig 302 "true"  "MERGEABLE"   ""                 0; assert_deferred "draft" 302
reset; elig 303 "false" "CONFLICTING" ""                 0; assert_deferred "non-mergeable" 303
reset; elig 304 "false" "MERGEABLE"   "CHANGES_REQUESTED" 0; assert_deferred "changes-requested" 304
reset; elig 305 "false" "MERGEABLE"   ""                 1; assert_deferred "automerge-hold" 305
echo "(defer) draft / non-MERGEABLE / CHANGES_REQUESTED / automerge-hold all defer — OK"

# ── (defer) policy not settled ────────────────────────────────────────────────────────────
reset; STUB_HAS_REVIEW=1; elig 306; assert_deferred "unconsumed-policy" 306   # review exists, no #consumed
reset; ledger_mark "$REVIEW_POLICY_LEDGER" "${REPO}#307#policy-pushed:${PSHA}"; STUB_HC=1
elig 307; assert_deferred "diverged-policy-sha" 307                            # policy sha not contained
echo "(defer) unconsumed-policy + diverged-policy-sha defer without #try — OK"

# ── (block) policy #escalated -> terminal #blocked + one escalation, no #try ──────────────
reset; ledger_mark "$REVIEW_POLICY_LEDGER" "${REPO}#308#escalated"
elig 308
[ "$(tries 308)" -eq 0 ]  || fail "(block) escalated must not #try"
[ "$(merges)" -eq 0 ]     || fail "(block) escalated must not merge"
ledger_seen "$LEDGER" "${FULL}#pr:308#blocked" || fail "(block) escalated must mark #blocked"
[ "$(grep -c 'automerge.escalation' "$EMBEDS")" -eq 1 ] || fail "(block) escalated must emit exactly one escalation"
echo "(block) policy #escalated -> #blocked + one escalation, no #try — OK"

# ── (stale) HEAD moved inside the lock -> no merge, no #try ────────────────────────────────
reset; STUB_REFETCH="$SHA_MOVED"; elig 309; assert_deferred "sha-moved-in-lock" 309
echo "(stale) HEAD moved in-lock -> no merge, no #try — OK"

# ── (idem) already MERGED on retry -> idempotent #merged, no #try, no merge ────────────────
reset; STUB_PRSTATE="MERGED"; elig 310
[ "$(ledger_count "$LEDGER" "${FULL}#pr:310#merged")" -eq 1 ] || fail "(idem) already-MERGED must record #merged"
[ "$(tries 310)" -eq 0 ]  || fail "(idem) already-MERGED must not #try"
[ "$(merges)" -eq 0 ]     || fail "(idem) already-MERGED must not call gh pr merge"
echo "(idem) already-MERGED retry -> idempotent #merged, no #try, no merge — OK"

# ── (cap) #try cap reached -> single give-up (one #blocked + one escalation), no merge ─────
reset
for _ in 1 2 3; do ledger_mark "$LEDGER" "${FULL}#pr:311#try"; done
elig 311                                                       # cap hit -> give up
elig 311                                                       # already blocked -> no repeat
[ "$(ledger_count "$LEDGER" "${FULL}#pr:311#blocked")" -eq 1 ] || fail "(cap) expected exactly one #blocked"
[ "$(grep -c 'automerge.escalation' "$EMBEDS")" -eq 1 ]         || fail "(cap) expected exactly one escalation"
[ "$(tries 311)" -eq 3 ]  || fail "(cap) give-up must not add a #try (still 3), got $(tries 311)"
[ "$(merges)" -eq 0 ]     || fail "(cap) give-up must not merge"
echo "(cap) #try cap -> single give-up, dedup on re-run — OK"

# ── (merge) fully eligible -> one #try, one #merged, one merge call, one merged embed ──────
reset
elig 312
[ "$(tries 312)" -eq 1 ] || fail "(merge) expected exactly one #try, got $(tries 312)"
[ "$(ledger_count "$LEDGER" "${FULL}#pr:312#merged")" -eq 1 ] || fail "(merge) expected one #merged"
[ "$(merges)" -eq 1 ]    || fail "(merge) expected exactly one gh pr merge call, got $(merges)"
[ "$(grep -c -- '--status merged' "$EMBEDS")" -eq 1 ] || fail "(merge) expected one 'merged' announcement embed"
echo "(merge) eligible PR -> #try + #merged + one merge + one embed — OK"

# ── (poll) AUTOMERGE_MAX_PER_POLL honored -> at most N merges per repo per poll ────────────
reset
list_open_prs()    { printf '401\trenovate[bot]\tfalse\tMERGEABLE\t\t\n402\trenovate[bot]\tfalse\tMERGEABLE\t\t\n'; }
head_commit_epoch() { printf '%s' "$HEPOCH_OLD"; }
AUTOMERGE_MAX_PER_POLL="1"
process_repo "$REPO" "$FULL"
[ "$(merges)" -eq 1 ] || fail "(poll) AUTOMERGE_MAX_PER_POLL=1 must cap at 1 merge/repo/poll, got $(merges)"
echo "(poll) AUTOMERGE_MAX_PER_POLL honored (1 merge for 2 eligible PRs) — OK"

echo "PASS: gate switches, non-GREEN/eligibility/policy defers, escalation blocks, stale-sha + idempotent handling, #try cap give-up, a clean merge, and the per-poll cap all hold."
exit 0
