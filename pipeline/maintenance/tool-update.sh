#!/usr/bin/env bash
# tool-update.sh — headless port of the interactive `update-ai` manifest (Workstream G).
#
# CROSS-REFERENCE: this is the non-interactive twin of the `update-ai` shell function
# defined in ~/.zshrc (the `# >>> JOBS` block). Keep the job list here in sync with it;
# the zsh version is for a human at a prompt, this one runs headless from fleet-update.sh.
#
# Enumerates the FULL update manifest (uv, prek, bun upgrade, bun globals, bun global
# update, skills, ruff; brew_update/brew_upgrade guarded on `command -v brew`; the macOS
# `agy` job is guard-skipped on this Linux host). Each job guards on command existence,
# logs start/result to a per-run log under ~/.gjc-bot/logs/, and retries ~3x with backoff
# on rate-limit / network patterns (mirrors update-ai's `_ua_exec`).
#
# PIN RE-ASSERTION (CRITICAL): `bun update -g --latest` bumps gajae-code PAST the fleet
# pin. Re-asserting the clawhip + gajae-code pins via bootstrap/10-engines.sh is done in a
# `trap ... EXIT` (finally), so ANY exit path — success, mid-manifest failure, or an abort
# after `bun update -g` but before re-pin — restores the pins. It can NEVER strand gajae
# unpinned.
#
# DRY_RUN=1  => log intended jobs + "would re-assert pins" and run NOTHING mutating.
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
REPO_ROOT="${GJC_FLEET_REPO_ROOT:-$(cd -- "$SCRIPTS_DIR/.." && pwd)}"
LOGS_DIR="${GJC_BOT_LOGS:-$STATE_DIR/logs}"
DRY_RUN="${DRY_RUN:-0}"

ENGINES_SH="${TOOL_UPDATE_ENGINES_SH:-$REPO_ROOT/bootstrap/10-engines.sh}"
RETRIES="${TOOL_UPDATE_RETRIES:-3}"
BACKOFF_SECS="${TOOL_UPDATE_BACKOFF_SECS:-5}"

# Per-job result sink (name<TAB>status), consumed by fleet-update.sh for its summary table.
RESULTS="${TOOL_UPDATE_RESULTS:-$STATE_DIR/tool-update-results.tsv}"

# gjc/clawhip/bun/uv live outside the systemd PATH — own a complete one.
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

mkdir -p "$STATE_DIR" "$LOGS_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
RUN_LOG="${TOOL_UPDATE_RUN_LOG:-$LOGS_DIR/tool-update-$(date +%Y%m%dT%H%M%S).log}"
: >"$RESULTS" 2>/dev/null || true

log() { printf '%s [tool-update] %s\n' "$(date -Is)" "$*" | tee -a "$RUN_LOG" >/dev/null; printf '%s\n' "[tool-update] $*"; }
record() { printf '%s\t%s\n' "$1" "$2" >>"$RESULTS" 2>/dev/null || true; }

# _ua_exec <cmd...> — run a mutating command, retrying up to $RETRIES times with
# exponential backoff on rate-limit / transient-network output patterns (mirrors update-ai).
_ua_exec() {
  local tries="$RETRIES" delay="$BACKOFF_SECS" n=1 out rc
  while :; do
    out="$("$@" 2>&1)"; rc=$?
    printf '%s\n' "$out" >>"$RUN_LOG"
    [ "$rc" -eq 0 ] && return 0
    if [ "$n" -ge "$tries" ]; then return "$rc"; fi
    if printf '%s' "$out" | grep -qiE 'rate.?limit|too many requests|429|timed?[ -]?out|temporarily|etimedout|econnreset|network|connection reset|try again'; then
      log "retry $n/$tries after transient failure (sleep ${delay}s)"
      sleep "$delay"; delay=$(( delay * 2 )); n=$(( n + 1 )); continue
    fi
    return "$rc"
  done
}

# job <name> <guard_cmd> <cmd...> — guard on the tool existing, then (DRY_RUN-aware) run it.
job() {
  local name="$1" guard="$2"; shift 2
  if ! command -v "$guard" >/dev/null 2>&1; then
    log "$name: SKIP ($guard not found)"; record "$name" skip; return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "$name: DRY_RUN would run: $*"; record "$name" dry; return 0
  fi
  log "$name: start ($*)"
  if _ua_exec "$@"; then
    log "$name: ok"; record "$name" ok
  else
    log "$name: FAIL (rc=$?)"; record "$name" fail
  fi
}

# reassert_pins — the `finally`: restore the clawhip + gajae-code pins via 10-engines.sh.
# Runs on EVERY exit path (trap EXIT) so `bun update -g --latest` can never leave gajae
# unpinned, even on a mid-manifest failure/abort.
reassert_pins() {
  if [ "$DRY_RUN" = "1" ]; then
    log "pins: DRY_RUN would re-assert clawhip + gajae-code pins (bootstrap/10-engines.sh)"
    return 0
  fi
  log "pins: re-asserting clawhip + gajae-code via $ENGINES_SH"
  if "$ENGINES_SH" >>"$RUN_LOG" 2>&1; then
    log "pins: re-asserted OK"; record "pins" ok
  else
    log "pins: re-assert FAILED"; record "pins" fail
  fi
}
# EXIT covers normal/error exits; INT/TERM/HUP cover a signalled abort (fleet-update kill or
# systemd shutdown) mid-`bun update -g --latest`, so gajae-code is NEVER left unpinned.
trap reassert_pins EXIT INT TERM HUP

log "run log: $RUN_LOG"

# ── manifest (order matters: bun jobs bump gajae past the pin; the EXIT trap re-pins) ──
job uv           uv    uv self update
job prek         prek  prek self update
job bun_upgrade  bun   bun upgrade
job bun_globals  bun   bun install -g \
  @augmentcode/auggie @google/gemini-cli @sourcegraph/amp \
  @agentclientprotocol/claude-agent-acp @agentclientprotocol/codex-acp \
  @zed-industries/codex-acp oh-my-claude-sisyphus oh-my-codex agent-browser
job bun_glob_update bun bun update -g --latest
job skills       bunx  bunx skills update -g
job ruff         curl  bash -c 'curl -LsSf https://astral.sh/ruff/install.sh | sh'
job brew_update  brew  brew update
job brew_upgrade brew  brew upgrade
# agy: macOS-only (/Users/dkp/... path) — guard-skipped on this Linux host.
if [ "$(uname -s)" = "Darwin" ]; then
  job agy agy agy update
else
  log "agy: SKIP (macOS-only job on non-Darwin host)"; record agy skip
fi

log "manifest complete (pins re-asserted on EXIT)"
