#!/usr/bin/env bash
# hermes-update.sh — track-latest hermes-agent updater for the fleet (Workstream G).
#
# Hermes is NOT ref-pinned by bootstrap/10-engines.sh (that only reports drift); it
# TRACKS LATEST, health-gated, with rollback owned HERE. `hermes update` itself pulls
# latest git + reinstalls deps but has no ref-pinning/rollback — this wrapper records
# the previous ref, restarts the gateway, health-checks it, and rolls back on failure.
#
#   hermes-update.sh --check    report only (hermes update --check); mutates nothing.
#   hermes-update.sh --apply    update -> restart gateway -> health-gate; rollback + escalate on failure.
#
# DRY_RUN=1  => log EVERY intended action and execute NONE of the mutating commands
#               (no `hermes update`, no restart, no git checkout, no pip install).
#
# Health gate (mirrors bootstrap/verify.sh:50-56):
#   systemctl --user is-active --quiet hermes-gateway.service
#   AND  ~/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway status
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
LOG="${HERMES_UPDATE_LOG:-$STATE_DIR/fleet-update.log}"
DRY_RUN="${DRY_RUN:-0}"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_CHECKOUT="${HERMES_CHECKOUT:-$HERMES_HOME/hermes-agent}"
VENV_PY="${HERMES_VENV_PY:-$HERMES_CHECKOUT/venv/bin/python}"
PIP="${HERMES_VENV_PIP:-$HERMES_CHECKOUT/venv/bin/pip}"
HERMES_BIN="${HERMES_BIN:-hermes}"
SYSTEMCTL="${SYSTEMCTL_BIN:-systemctl}"
GIT="${GIT_BIN:-/usr/bin/git}"

PREV_REF_FILE="${HERMES_PREV_REF_FILE:-$STATE_DIR/state/hermes-prev-ref}"
DEPLOYED_REF_FILE="${HERMES_DEPLOYED_REF_FILE:-$STATE_DIR/state/hermes-deployed-ref}"

# Discord routing — reuse an already-rendered numeric channel id; resolved WITHOUT `:?`
# so the script stays sourceable and empty is guarded at send time.
FLEET_UPDATE_CHANNEL="${FLEET_UPDATE_CHANNEL:-${MERGE_GATE_CHANNEL:-}}"

# gjc/clawhip/hermes live outside the systemd PATH — own a complete one.
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

# Design-system Discord embed emitter (kind hermes-update — already in design-system.json).
# shellcheck source=../lib/discord-embed.sh
source "$SCRIPTS_DIR/lib/discord-embed.sh"

mkdir -p "$STATE_DIR" "$(dirname "$PREV_REF_FILE")" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
log() { printf '%s [hermes-update] %s\n' "$(date -Is)" "$*" >>"$LOG"; printf '%s\n' "[hermes-update] $*"; }

# emit_embed <discord_embed args...> — send iff a channel is configured; never fatal.
emit_embed() {
  [ -n "$FLEET_UPDATE_CHANNEL" ] || { log "embed skipped: no channel configured"; return 0; }
  discord_embed --channel "$FLEET_UPDATE_CHANNEL" "$@" || log "embed send failed"
}

# health_ok — gateway is-active AND the hermes_cli gateway status probe succeeds.
health_ok() {
  "$SYSTEMCTL" --user is-active --quiet hermes-gateway.service 2>/dev/null \
    && "$VENV_PY" -m hermes_cli.main gateway status >/dev/null 2>&1
}

# rollback <prev_ref> — restore the pre-update ref, reinstall, restart, re-health-check,
# and emit a hermes-update ESCALATION embed describing the outcome.
rollback() {
  local prev="$1"
  log "rolling back to ${prev:0:7}: git checkout + pip install -e + restart"
  "$GIT" -C "$HERMES_CHECKOUT" checkout "$prev" >>"$LOG" 2>&1 || log "rollback: git checkout FAILED"
  "$PIP" install -e "$HERMES_CHECKOUT" >>"$LOG" 2>&1 || log "rollback: pip install FAILED"
  "$SYSTEMCTL" --user restart hermes-gateway.service >>"$LOG" 2>&1 || log "rollback: gateway restart FAILED"
  if health_ok; then
    log "rollback restored ${prev:0:7} — gateway healthy again"
    emit_embed --kind hermes-update --status escalated \
      --message "Hermes update FAILED; rolled back to \`${prev:0:7}\` (gateway healthy). Manual investigation needed."
  else
    log "rollback FAILED — gateway still unhealthy at ${prev:0:7}"
    emit_embed --kind hermes-update --status escalated \
      --message "Hermes update FAILED and rollback to \`${prev:0:7}\` did NOT restore gateway health. URGENT manual intervention required."
  fi
}

# run_check — report-only. Prints hermes' own --check output; mutates nothing.
run_check() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN would run: hermes update --check (report only)"
    return 0
  fi
  "$HERMES_BIN" update --check
}

# run_apply — the full update -> restart -> health-gate flow (with rollback).
run_apply() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN would run: hermes update --check (report only); exit 0 if already current"
    log "DRY_RUN would verify: $HERMES_CHECKOUT working tree is clean (abort if dirty)"
    log "DRY_RUN would record prev-ref (git rev-parse HEAD) -> $PREV_REF_FILE"
    log "DRY_RUN would run: hermes update --yes"
    log "DRY_RUN would run: systemctl --user restart hermes-gateway.service"
    log "DRY_RUN would health-gate: is-active AND venv/bin/python -m hermes_cli.main gateway status"
    log "DRY_RUN would on-failure ROLLBACK: git checkout prev-ref + pip install -e + restart + re-check + hermes-update escalation embed"
    log "DRY_RUN would on-success: record deployed-ref -> $DEPLOYED_REF_FILE + hermes-update info embed (old->new short SHAs)"
    return 0
  fi

  # 1. Already current? hermes update --check is report-only.
  local check_out
  check_out="$("$HERMES_BIN" update --check 2>&1)" || true
  printf '%s\n' "$check_out" >>"$LOG"
  if printf '%s' "$check_out" | grep -qiE 'up[[:space:]-]?to[[:space:]-]?date|already (current|up)|no update'; then
    log "hermes already current — nothing to do"
    return 0
  fi

  # 2. Pre-flight: refuse if the checkout tree is dirty; record prev_ref.
  if [ -n "$("$GIT" -C "$HERMES_CHECKOUT" status --porcelain 2>/dev/null)" ]; then
    log "ABORT: $HERMES_CHECKOUT working tree is dirty — refusing to update"
    emit_embed --kind hermes-update --status escalated \
      --message "Hermes update aborted: checkout tree dirty (\`$HERMES_CHECKOUT\`). Manual cleanup required before the next attempt."
    return 1
  fi
  local prev_ref
  prev_ref="$("$GIT" -C "$HERMES_CHECKOUT" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$prev_ref" ]; then
    log "ABORT: cannot resolve current HEAD of $HERMES_CHECKOUT"
    return 1
  fi
  printf '%s\n' "$prev_ref" >"$PREV_REF_FILE"
  log "recorded prev-ref ${prev_ref:0:7} -> $PREV_REF_FILE"

  # 3. Apply -> restart gateway -> health-gate.
  log "applying: hermes update --yes"
  if ! "$HERMES_BIN" update --yes >>"$LOG" 2>&1; then
    log "hermes update --yes FAILED"
    rollback "$prev_ref"
    return 1
  fi
  log "restarting hermes-gateway.service"
  "$SYSTEMCTL" --user restart hermes-gateway.service >>"$LOG" 2>&1 || log "gateway restart returned non-zero"
  if health_ok; then
    local new_ref
    new_ref="$("$GIT" -C "$HERMES_CHECKOUT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf '%s\n' "$new_ref" >"$DEPLOYED_REF_FILE"
    log "hermes updated OK ${prev_ref:0:7} -> $new_ref (gateway healthy)"
    emit_embed --kind hermes-update --status ok \
      --message "Hermes updated \`${prev_ref:0:7}\` -> \`${new_ref}\` (gateway healthy)."
    return 0
  fi

  # 4. Health gate failed -> rollback + escalate.
  log "health gate FAILED after update"
  rollback "$prev_ref"
  return 1
}

MODE=""
case "${1:-}" in
  --check) MODE=check ;;
  --apply) MODE=apply ;;
  *) echo "usage: hermes-update.sh --check|--apply" >&2; exit 2 ;;
esac

if [ "$MODE" = "check" ]; then
  run_check
else
  run_apply
fi
