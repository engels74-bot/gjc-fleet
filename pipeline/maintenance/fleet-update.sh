#!/usr/bin/env bash
# fleet-update.sh — nightly fleet tool-update lane orchestrator (Workstream G).
#
# Timer-driven (systemd/fleet-update.{service,timer}): quiesce the fleet, refresh the host
# toolchain (tool-update.sh) + hermes-agent (hermes-update.sh --apply, gateway restarted
# LAST), then verify and post ONE fleet-update summary embed. Default OFF; fully inert
# until [updates].tool_update_enabled is rendered on and the operator enables the timer.
#
# ── Kill switches (ALL must allow a real run) ─────────────────────────────────────────
#   1. TOOL_UPDATE_ENABLED=1     (from [updates].tool_update_enabled — DEFAULT 0/OFF => exit 0 quietly)
#   2. no ~/.gjc-bot/fleet-update.disable marker on the host
#   3. DRY_RUN unset/0           (DRY_RUN=1 => plan-only: log intents, mutate NOTHING)
#
# ── Quiesce ───────────────────────────────────────────────────────────────────────────
# Take the global gjc.lock AND review.lock BLOCKING WITH TIMEOUT (flock -w), and wait for
# zero live coordinator-mcp sessions. On timeout => DEFER to the next night: notice embed,
# exit 0 (never force). With both locks held: tool-update.sh -> hermes-update.sh --apply
# (gateway restarted last) -> release locks -> verify.sh -> one fleet-update summary embed.
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
REPO_ROOT="${GJC_FLEET_REPO_ROOT:-$(cd -- "$SCRIPTS_DIR/.." && pwd)}"
LOG="${FLEET_UPDATE_LOG:-$STATE_DIR/fleet-update.log}"
DRY_RUN="${DRY_RUN:-0}"

TOOL_UPDATE_ENABLED="${TOOL_UPDATE_ENABLED:-0}"
DISABLE_MARKER="${FLEET_UPDATE_DISABLE_MARKER:-$STATE_DIR/fleet-update.disable}"

GJC_LOCK="${GJC_LOCK:-$STATE_DIR/gjc.lock}"
REVIEW_LOCK="${REVIEW_LOCK:-$STATE_DIR/review.lock}"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"
JQ="${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}"
QUIESCE_TIMEOUT_MINS="${QUIESCE_TIMEOUT_MINS:-45}"
QUIESCE_TIMEOUT_SECS="${QUIESCE_TIMEOUT_SECS:-$(( QUIESCE_TIMEOUT_MINS * 60 ))}"
COORD_STATE_ROOT="${FLEET_UPDATE_COORD_STATE_ROOT:-$HOME/.hermes/.gjc/state/coordinator-mcp}"

TOOL_UPDATE_SH="${FLEET_TOOL_UPDATE_SH:-$SCRIPTS_DIR/maintenance/tool-update.sh}"
HERMES_UPDATE_SH="${FLEET_HERMES_UPDATE_SH:-$SCRIPTS_DIR/maintenance/hermes-update.sh}"
VERIFY_SH="${FLEET_VERIFY_SH:-$REPO_ROOT/bootstrap/verify.sh}"
TOOL_UPDATE_RESULTS="${TOOL_UPDATE_RESULTS:-$STATE_DIR/tool-update-results.tsv}"
export TOOL_UPDATE_RESULTS

FLEET_UPDATE_CHANNEL="${FLEET_UPDATE_CHANNEL:-${MERGE_GATE_CHANNEL:-}}"

# gjc/clawhip live outside the systemd PATH — own a complete one.
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

# Design-system Discord embed emitter (kind fleet-update — already in design-system.json).
# shellcheck source=../lib/discord-embed.sh
source "$SCRIPTS_DIR/lib/discord-embed.sh"

mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
log() { printf '%s [fleet-update] %s\n' "$(date -Is)" "$*" >>"$LOG"; printf '%s\n' "[fleet-update] $*"; }

emit_embed() {
  [ -n "$FLEET_UPDATE_CHANNEL" ] || { log "embed skipped: no channel configured"; return 0; }
  discord_embed --channel "$FLEET_UPDATE_CHANNEL" "$@" || log "embed send failed"
}

# gate — kill-switch #1 + #2. Returns 0 to proceed; logs + returns 1 to exit-0-quietly.
gate() {
  if [ "$TOOL_UPDATE_ENABLED" != "1" ]; then
    log "disabled (TOOL_UPDATE_ENABLED=$TOOL_UPDATE_ENABLED) — exiting quietly"; return 1
  fi
  if [ -e "$DISABLE_MARKER" ]; then
    log "disable marker present ($DISABLE_MARKER) — exiting quietly"; return 1
  fi
  return 0
}

# count_live_coord — number of coordinator-mcp session-state files that are (or might be) live.
# FAIL-SAFE toward DEFERRING: a missing/renamed/unparseable `live` field counts as LIVE (true),
# so a future hermes schema change makes quiesce wait/defer rather than proceed over an active run.
count_live_coord() {
  local n=0 f live
  shopt -s nullglob
  for f in "$COORD_STATE_ROOT"/*/*/session-states/*.json; do
    live="$("$JQ" -r 'if has("live") and (.live != null) then (.live|tostring) else "true" end' "$f" 2>/dev/null || echo true)"
    [ "$live" = "true" ] && n=$(( n + 1 ))
  done
  printf '%s' "$n"
}

# defer <reason> — quiesce timed out: emit a notice embed and exit 0 (never force).
defer() {
  local reason="$1"
  log "DEFER to next night: $reason"
  emit_embed --kind fleet-update --status deferred \
    --message "Nightly fleet update DEFERRED to next window: $reason (quiesce timeout ${QUIESCE_TIMEOUT_MINS}m). No update ran."
  exit 0
}

# quiesce — take gjc.lock + review.lock (flock -w) and wait for zero live coordinator
# sessions, all within QUIESCE_TIMEOUT_SECS. DEFERs (exit 0) on any timeout. On success
# the locks stay held via the exec'd fds ($GLOCK_FD/$RLOCK_FD) for the caller.
GLOCK_FD=""
RLOCK_FD=""
quiesce() {
  log "quiesce: acquiring gjc.lock + review.lock (flock -w ${QUIESCE_TIMEOUT_SECS}s) and waiting for idle coordinators"
  exec {GLOCK_FD}>"$GJC_LOCK"
  if ! "$FLOCK" -w "$QUIESCE_TIMEOUT_SECS" "$GLOCK_FD"; then defer "gjc.lock still held (a live gjc run is in progress)"; fi
  exec {RLOCK_FD}>"$REVIEW_LOCK"
  if ! "$FLOCK" -w "$QUIESCE_TIMEOUT_SECS" "$RLOCK_FD"; then defer "review.lock still held (a live review handler is running)"; fi

  local deadline live now
  deadline=$(( $(date +%s) + QUIESCE_TIMEOUT_SECS ))
  while :; do
    live="$(count_live_coord)"
    [ "$live" = "0" ] && break
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then defer "$live coordinator session(s) still live"; fi
    log "quiesce: $live live coordinator session(s) — waiting"
    sleep 30
  done
  log "quiesce: locks held, coordinators idle — proceeding"
}

release_locks() {
  [ -n "$GLOCK_FD" ] && eval "exec ${GLOCK_FD}>&-" 2>/dev/null || true
  [ -n "$RLOCK_FD" ] && eval "exec ${RLOCK_FD}>&-" 2>/dev/null || true
  log "released gjc.lock + review.lock"
}

# results_table — render the per-job ok/fail lines from tool-update's TSV + the appended
# hermes/verify rows into a compact embed-tail table.
results_table() {
  [ -f "$TOOL_UPDATE_RESULTS" ] || { printf '(no results)'; return 0; }
  local name status line=""
  while IFS=$'\t' read -r name status; do
    [ -n "$name" ] || continue
    line="$line- ${name}: ${status}"$'\n'
  done <"$TOOL_UPDATE_RESULTS"
  printf '%s' "$line"
}

# plan_only — DRY_RUN=1: log every intended step, execute nothing mutating.
plan_only() {
  log "DRY_RUN plan-only — no mutation"
  log "DRY_RUN would quiesce: take gjc.lock + review.lock (flock -w ${QUIESCE_TIMEOUT_SECS}s) + wait for idle coordinators; DEFER on timeout"
  log "DRY_RUN would run: tool-update ($TOOL_UPDATE_SH)"
  log "DRY_RUN would run: hermes-update ($HERMES_UPDATE_SH --apply) — gateway restarted last"
  log "DRY_RUN would run: verify ($VERIFY_SH)"
  log "DRY_RUN would emit: one fleet-update summary embed (per-job ok/fail table)"
}

main() {
  gate || exit 0

  if [ "$DRY_RUN" = "1" ]; then
    plan_only
    exit 0
  fi

  quiesce   # DEFERs (exit 0) on timeout; otherwise returns with locks held

  local tu_status hu_status vf_status
  log "running tool-update: $TOOL_UPDATE_SH"
  if "$TOOL_UPDATE_SH"; then tu_status=ok; else tu_status=fail; fi

  log "running hermes-update --apply: $HERMES_UPDATE_SH"
  if "$HERMES_UPDATE_SH" --apply; then hu_status=ok; else hu_status=fail; fi
  printf 'hermes\t%s\n' "$hu_status" >>"$TOOL_UPDATE_RESULTS" 2>/dev/null || true

  release_locks

  log "running verify: $VERIFY_SH"
  if "$VERIFY_SH"; then vf_status=ok; else vf_status=fail; fi
  printf 'verify\t%s\n' "$vf_status" >>"$TOOL_UPDATE_RESULTS" 2>/dev/null || true

  local table
  table="$(results_table)"
  log "summary: tool-update=$tu_status hermes=$hu_status verify=$vf_status"
  emit_embed --kind fleet-update --status "$( [ "$tu_status" = ok ] && [ "$hu_status" = ok ] && [ "$vf_status" = ok ] && echo ok || echo failed )" \
    --message "Nightly fleet update complete.
${table}"
}

# Sourceable for tests (FLEET_UPDATE_NO_MAIN=1); run the full orchestrator otherwise.
[ "${FLEET_UPDATE_NO_MAIN:-0}" = "1" ] || main "$@"
