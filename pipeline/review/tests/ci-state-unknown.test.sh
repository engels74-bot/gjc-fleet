#!/usr/bin/env bash
# ci-state-unknown.test.sh — K2 proof that lib/gh-ci.sh's ci_state() distinguishes a GitHub
# API FAILURE (UNKNOWN, callers defer) from a genuine NO-CI commit (NONE), and that RED
# classification still works. Then a CALLER proof: ci-fixer.sh's consider_pr() must DEFER on
# UNKNOWN (record nothing, launch nothing) — an API blip is never treated as actionable.
#
# No network: `gh` is replaced by a stub whose per-endpoint output + exit code are driven by
# env vars (GH_STUB_RC / CHECKRUNS_JSON / STATUSES_JSON). ci-fixer.sh is sourced as a library
# (CI_FIXER_NO_MAIN=1) so its poll loop never runs; consider_pr() is called directly.
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../ci-fixer.sh"

LAUNCHES="$TMP/launches.log"
: >"$LAUNCHES"
LEDGER="$TMP/ci-fixer.jsonl"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── gh stub: route by endpoint, echo the env-provided JSON, exit with GH_STUB_RC ───────────
GH_STUB="$TMP/gh-stub.sh"
cat >"$GH_STUB" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *check-runs*) printf '%s' "${CHECKRUNS_JSON:-}" ;;
  *status*)     printf '%s' "${STATUSES_JSON:-}" ;;
esac
exit "${GH_STUB_RC:-0}"
EOF
chmod 755 "$GH_STUB"

# Runner stub: record each launch; never touch the network.
RUNNER_STUB="$TMP/runner-stub.sh"
cat >"$RUNNER_STUB" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAUNCHES"
exit 0
EOF
chmod 755 "$RUNNER_STUB"

# Isolate ALL state under $TMP; point the shared libs' tool binaries at real jq + our gh stub.
export GJC_BOT_STATE="$TMP"
export GJC_BOT_GH_ROOT="$TMP/gh-root"      # empty -> list_bot_repos yields nothing
export CI_FIXER_LEDGER="$LEDGER"
export CI_FIXER_LOG="$TMP/ci-fixer.log"
export CI_FIXER_RUN_BIN="$RUNNER_STUB"
export CI_FIXER_REPOS="testrepo"
export CI_FIXER_ENABLED="1"
export CI_FIXER_MAX_PER_SHA="2"
export CI_FIXER_MAX_PER_PR="5"
export CI_FIXER_BACKOFF_BASE_MINS="10"
export CI_FIX_NOTIFY_CHANNEL="events"
export CI_FIX_ESCALATE_CHANNEL="approvals"
export DRY_RUN="0"
export CI_FIXER_NO_MAIN="1"
export GH_BIN="$GH_STUB"
JQ="$(command -v jq || echo /home/linuxbrew/.linuxbrew/bin/jq)"; export JQ
mkdir -p "$GJC_BOT_GH_ROOT"

# shellcheck source=/dev/null
source "$POLLER"     # transitively sources lib/gh-ci.sh -> defines the REAL ci_state()

FULL="engels74/testrepo"
echo "===== ci_state UNKNOWN vs NONE vs RED ====="

# ── (a) gh fails on BOTH the initial call and the single retry -> UNKNOWN ──────────────────
export GH_STUB_RC="1"
export CHECKRUNS_JSON='{"check_runs":[]}'
export STATUSES_JSON='{"statuses":[]}'
SHA_A="a000000000000000000000000000000000000001"
got="$(ci_state "$FULL" "$SHA_A")"
echo "(a) gh non-zero (both tries) -> ci_state=$got  (expect UNKNOWN)"
[ "$got" = "UNKNOWN" ] || fail "(a) expected UNKNOWN on gh API failure, got '$got'"

# ── (b) gh succeeds, empty check-runs + empty statuses -> NONE (genuine no-CI) ─────────────
export GH_STUB_RC="0"
export CHECKRUNS_JSON='{"check_runs":[]}'
export STATUSES_JSON='{"statuses":[]}'
SHA_B="b000000000000000000000000000000000000002"
got="$(ci_state "$FULL" "$SHA_B")"
echo "(b) gh ok, no checks/statuses -> ci_state=$got  (expect NONE)"
[ "$got" = "NONE" ] || fail "(b) expected NONE for a genuine no-CI commit, got '$got'"

# ── (c) gh succeeds, one completed FAILING check -> RED (classification still works) ───────
export GH_STUB_RC="0"
export CHECKRUNS_JSON='{"check_runs":[{"status":"completed","conclusion":"failure","name":"build"}]}'
export STATUSES_JSON='{"statuses":[]}'
SHA_C="c000000000000000000000000000000000000003"
got="$(ci_state "$FULL" "$SHA_C")"
echo "(c) gh ok, one failing check -> ci_state=$got  (expect RED)"
[ "$got" = "RED" ] || fail "(c) expected RED for a completed failing check, got '$got'"

# ── (d) CALLER proof: consider_pr() DEFERS on UNKNOWN (zero records, zero launches) ────────
# Override ci_state to force UNKNOWN; the poller's `st != RED` skip must fire before any
# ledger write or run launch. This is the load-bearing K2 invariant for ci-fixer.
: >"$LEDGER"; : >"$LAUNCHES"
ci_state() { printf 'UNKNOWN'; }
SHA_D="d000000000000000000000000000000000000004"
consider_pr "testrepo" "$FULL" "107" "$SHA_D"
recs="$( [ -f "$LEDGER" ] && wc -l <"$LEDGER" | tr -d ' ' || echo 0 )"
launches="$(wc -l <"$LAUNCHES" | tr -d ' ')"
echo "(d) UNKNOWN -> consider_pr: ledger records=$recs  launches=$launches  (expect 0/0)"
[ "$recs" -eq 0 ]     || fail "(d) UNKNOWN must not record a fixer entry, got $recs"
[ "$launches" -eq 0 ] || fail "(d) UNKNOWN must not launch a run, got $launches"

echo "PASS: ci_state distinguishes UNKNOWN (API fail) / NONE (no-CI) / RED, and consider_pr defers on UNKNOWN."
exit 0
