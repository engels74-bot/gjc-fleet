#!/usr/bin/env bash
# tmux-reap.test.sh — Workstream I proof for the janitor's age-based tmux
# coordinator-session reaper (gjc-worktree-janitor.sh), driven fully offline.
#
# NEVER touches real tmux sessions or the real coordinator state dir: the janitor
# is sourced (JANITOR_NO_MAIN=1) and reap_tmux_sessions() is called directly with
# DRY_RUN=1, a STUBBED tmux binary (fake `tmux ls`), a STUBBED gjc-reap.sh, and
# the coordinator-state glob repointed at a $TMP fixture tree. Cases:
#
#   (a) eligible (state=completed, live=false, updated_at 2h ago) -> DRY_RUN "would reap", gjc-reap NOT called
#   (b) NOT eligible (live=true | state=running | updated_at 1min ago)          -> not reaped
#   (c) SCHEMA GUARD: state file missing a required field (no `live`)           -> SKIPPED (fail-safe)
#   (d) reaper OFF (enable knob unset/0), even with an eligible session         -> zero reap activity
#   (e) NO state file: too young -> skip; older than 24h fallback -> would reap  (conservative provenance)
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
JANITOR="$HERE/../gjc-worktree-janitor.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

JQ="$(command -v jq || echo /home/linuxbrew/.linuxbrew/bin/jq)"
[ -x "$JQ" ] || fail "jq not found at $JQ"

# ── fixture layout ───────────────────────────────────────────────────────────
COORD="$TMP/coord"                              # fake coordinator-mcp root
SS="$COORD/hermes-bot/mover-status/session-states"
mkdir -p "$SS"
SESS_FILE="$TMP/sessions.txt"                    # what the fake `tmux ls` emits
REAP_CALLS="$TMP/reap-calls.log"                 # gjc-reap stub records invocations here
: >"$SESS_FILE"; : >"$REAP_CALLS"

# Fake tmux: `ls -F <fmt>` -> emit our fixture session list; everything else no-op.
cat >"$TMP/tmux-stub.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "ls" ]; then cat "$SESS_FILE" 2>/dev/null || true; exit 0; fi
exit 0
EOF
chmod 755 "$TMP/tmux-stub.sh"

# Fake gjc-reap.sh: MUST never be invoked in these DRY_RUN cases; record if it is.
cat >"$TMP/reap-stub.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$REAP_CALLS"
exit 0
EOF
chmod 755 "$TMP/reap-stub.sh"

# ── isolate ALL state + tool bindings under \$TMP, then source the janitor ─────
export JANITOR_NO_MAIN="1"                        # do not run the live worktree pass
export DRY_RUN="1"                                # log intent, take no action
export GJC_BOT_STATE="$TMP"                       # LOG + state dir under $TMP
export TMUX_BIN_OVERRIDE="$TMP/tmux-stub.sh"      # janitor resolves this as TMUX_BIN
export JANITOR_COORD_STATE_ROOT="$COORD"          # glob our fixture tree, not the real one
export JANITOR_REAP_BIN="$TMP/reap-stub.sh"       # never the real gjc-reap.sh
export JQ_BIN="$JQ"
export JANITOR_TMUX_REAP_ENABLED="1"              # ON for (a)-(c),(e); flipped OFF in (d)
export JANITOR_TMUX_GRACE_SECONDS="1800"          # 30 min
export JANITOR_TMUX_NOSTATE_SECONDS="86400"       # 24 h

# shellcheck source=/dev/null
source "$JANITOR"
set +e                                            # janitor sets -e while sourcing; relax for the harness

LOG="$TMP/janitor.log"
ISO() { date -u -d "$1" +%Y-%m-%dT%H:%M:%S.000Z; }   # ISO-8601(ms,Z) N ago, e.g. ISO '2 hours ago'

# write_state <session> <json>
write_state() { printf '%s' "$2" >"$SS/$1.json"; }
# set_sessions <line...> — each arg is a "name created_epoch" tmux ls row
set_sessions() { printf '%s\n' "$@" >"$SESS_FILE"; }
reset() { : >"$LOG"; : >"$REAP_CALLS"; rm -f "$SS"/*.json 2>/dev/null; : >"$SESS_FILE"; }
would_reap() { local n; n="$(grep -c "would reap $1" "$LOG" 2>/dev/null)" || true; echo "${n:-0}"; }
reap_calls() { local n; n="$(grep -c "$1" "$REAP_CALLS" 2>/dev/null)" || true; echo "${n:-0}"; }

NOW="$(date +%s)"; OLD_CREATED=$(( NOW - 200000 ))   # created ~2.3d ago (irrelevant when state file present)

echo "===== tmux coordinator-session reaper assertions (DRY_RUN) ====="

# ── (a) eligible -> DRY_RUN "would reap", gjc-reap NOT actually called ─────────
reset
S="gjc-coordinator-aaaa1111"
write_state "$S" "{\"state\":\"completed\",\"live\":false,\"updated_at\":\"$(ISO '2 hours ago')\",\"session_id\":\"$S\"}"
set_sessions "$S $OLD_CREATED"
reap_tmux_sessions
wr="$(would_reap "$S")"; rc="$(reap_calls "$S")"
echo "(a) would_reap=$wr  reap_calls=$rc  (expect 1/0)"
[ "$wr" -eq 1 ] || fail "(a) eligible session should log a DRY_RUN would-reap, got $wr"
[ "$rc" -eq 0 ] || fail "(a) DRY_RUN must NOT invoke gjc-reap, got $rc calls"

# ── (b) NOT eligible: live=true, state=running, updated_at 1min ago ────────────
for kind in live_true state_running too_young; do
  reset
  S="gjc-coordinator-bbbb${kind:0:4}"
  case "$kind" in
    live_true)     json="{\"state\":\"completed\",\"live\":true,\"updated_at\":\"$(ISO '2 hours ago')\"}" ;;
    state_running) json="{\"state\":\"running\",\"live\":false,\"updated_at\":\"$(ISO '2 hours ago')\"}" ;;
    too_young)     json="{\"state\":\"completed\",\"live\":false,\"updated_at\":\"$(ISO '1 minute ago')\"}" ;;
  esac
  write_state "$S" "$json"
  set_sessions "$S $OLD_CREATED"
  reap_tmux_sessions
  wr="$(would_reap "$S")"; rc="$(reap_calls "$S")"
  echo "(b/$kind) would_reap=$wr  reap_calls=$rc  (expect 0/0)"
  [ "$wr" -eq 0 ] || fail "(b/$kind) must NOT be reaped, got would_reap=$wr"
  [ "$rc" -eq 0 ] || fail "(b/$kind) must NOT invoke gjc-reap, got $rc"
done

# ── (c) SCHEMA GUARD: eligible-looking but missing `live` -> SKIPPED ───────────
reset
S="gjc-coordinator-cccc2222"
write_state "$S" "{\"state\":\"completed\",\"updated_at\":\"$(ISO '2 hours ago')\"}"   # no `live` field
set_sessions "$S $OLD_CREATED"
reap_tmux_sessions
wr="$(would_reap "$S")"; rc="$(reap_calls "$S")"
missing="$(grep -c "missing required field" "$LOG" 2>/dev/null)" || true; missing="${missing:-0}"
echo "(c) would_reap=$wr  reap_calls=$rc  missing-field-logs=$missing  (expect 0/0/>=1)"
[ "$wr" -eq 0 ]      || fail "(c) missing-field session must be SKIPPED, got would_reap=$wr"
[ "$rc" -eq 0 ]      || fail "(c) missing-field session must not invoke gjc-reap, got $rc"
[ "$missing" -ge 1 ] || fail "(c) expected a schema-guard skip log line"

# ── (d) reaper OFF (enable knob unset/0) -> zero activity even for an eligible session ─
reset
S="gjc-coordinator-dddd3333"
write_state "$S" "{\"state\":\"completed\",\"live\":false,\"updated_at\":\"$(ISO '2 hours ago')\"}"
set_sessions "$S $OLD_CREATED"
TMUX_REAP_ENABLED="0"                              # simulate JANITOR_TMUX_REAP_ENABLED unset
reap_tmux_sessions
# shellcheck disable=SC2034  # read by the sourced reaper (reap_tmux_sessions) in case (e)
TMUX_REAP_ENABLED="1"                              # restore for any later cases
lines="$(wc -l <"$LOG" | tr -d ' ')"; rc="$(reap_calls "$S")"
echo "(d) log-lines=$lines  reap_calls=$rc  (expect 0/0 — fully inert)"
[ "$lines" -eq 0 ] || fail "(d) reaper OFF must log nothing, got $lines lines"
[ "$rc" -eq 0 ]    || fail "(d) reaper OFF must not invoke gjc-reap, got $rc"

# ── (e) NO state file: too young -> skip; older than 24h fallback -> would reap ─
reset
S="gjc-coordinator-eeee4444"                       # young, no state file
set_sessions "$S $(( NOW - 3600 ))"                # created 1h ago (< 24h fallback)
reap_tmux_sessions
wr_young="$(would_reap "$S")"
reset
S2="gjc-coordinator-eeee5555"                      # old, no state file
set_sessions "$S2 $(( NOW - 200000 ))"             # created ~2.3d ago (> 24h fallback)
reap_tmux_sessions
wr_old="$(would_reap "$S2")"; rc_old="$(reap_calls "$S2")"
echo "(e) no-state young would_reap=$wr_young  |  no-state old would_reap=$wr_old reap_calls=$rc_old  (expect 0 | 1/0)"
[ "$wr_young" -eq 0 ] || fail "(e) no-state young session must be skipped, got $wr_young"
[ "$wr_old" -eq 1 ]   || fail "(e) no-state old session must hit the fallback would-reap, got $wr_old"
[ "$rc_old" -eq 0 ]   || fail "(e) no-state old (DRY_RUN) must not invoke gjc-reap, got $rc_old"

echo "PASS: eligibility, live/state/age gates, schema-guard fail-safe, OFF-default inertness, and no-state fallback all hold."
exit 0
