#!/usr/bin/env bash
# gjc-reap.sh — kill a hung/stale gjc session (Phase G1 step 3).
#
# Invoked by a clawhip route on tmux.stale for the routed gjc session (and usable
# manually). It kills the session's ENTIRE pane process TREE — because
# `tmux kill-session` alone only signals the pane's top shell and ORPHANS the
# descendants (the in-session gjc-run.sh wrapper that holds gjc.lock survives,
# keeping the lock held). Killing the wrapper closes its held fd, releasing
# ~/.gjc-bot/gjc.lock. A janitor pass then clears any orphaned launch worktree.
# This is the second, independent stop paired with the wrapper's own `timeout`.
#
# Safety: only descendants of the named session's pane_pid(s) are touched
# (PID-based pgrep -P walk — never a string/pattern match), and the reaper never
# signals itself, its parent, or PID 1.
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
LOG="$STATE_DIR/gjc-run.log"
TMUX_BIN="${TMUX_BIN_OVERRIDE:-/home/linuxbrew/.linuxbrew/bin/tmux}"
JANITOR="${JANITOR_BIN:-$SCRIPTS_DIR/maintenance/gjc-worktree-janitor.sh}"

mkdir -p "$STATE_DIR"
log() { printf '%s [gjc-reap] %s\n' "$(date -Is)" "$*" >>"$LOG"; }

SELF_PID=$$; SELF_PPID=$PPID
safe_kill() { # safe_kill <SIG> <pid>
  local sig="$1" pid="$2"
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac      # numeric only
  [ "$pid" -gt 1 ] || return 0                       # never PID 0/1
  [ "$pid" = "$SELF_PID" ] && return 0
  [ "$pid" = "$SELF_PPID" ] && return 0
  kill -"$sig" "$pid" 2>/dev/null || true
}

# Print <root> and all its descendants (BFS), one PID per line.
collect_tree() {
  local queue=("$1") pid child
  while [ "${#queue[@]}" -gt 0 ]; do
    pid="${queue[0]}"; queue=("${queue[@]:1}")
    printf '%s\n' "$pid"
    while IFS= read -r child; do
      [ -n "$child" ] && queue+=("$child")
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  done
}

SESSION="${1:-${CLAWHIP_TMUX_SESSION:-${TMUX_SESSION:-}}}"
if [ -z "$SESSION" ]; then log "reap: no session specified (arg or CLAWHIP_TMUX_SESSION)"; exit 2; fi

if [ ! -x "$TMUX_BIN" ] || ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
  log "reap: session '$SESSION' not present (already gone); running janitor anyway"
  "$JANITOR" || true
  exit 0
fi

# Collect the full process tree BEFORE kill-session (afterwards children reparent
# to PID 1 and the tree is lost).
mapfile -t PANEPIDS < <("$TMUX_BIN" list-panes -t "$SESSION" -F '#{pane_pid}' 2>/dev/null || true)
ALL=()
for pp in "${PANEPIDS[@]}"; do
  [ -n "$pp" ] || continue
  while IFS= read -r p; do ALL+=("$p"); done < <(collect_tree "$pp")
done

# Kill leaf-first (reverse BFS order), TERM then KILL, then drop the session.
for (( i=${#ALL[@]}-1; i>=0; i-- )); do safe_kill TERM "${ALL[i]}"; done
"$TMUX_BIN" kill-session -t "$SESSION" 2>>"$LOG" || true
for (( i=${#ALL[@]}-1; i>=0; i-- )); do safe_kill KILL "${ALL[i]}"; done

log "reaped session '$SESSION' (killed ${#ALL[@]} tree pids -> in-session lock fd closed -> gjc.lock released)"

# Clear any orphaned launch worktree the killed run left behind.
"$JANITOR" || true
