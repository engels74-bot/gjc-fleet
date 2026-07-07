#!/usr/bin/env bash
#
# gjc-worktree-janitor.sh — crash-net for orphaned gjc launch worktrees.
# Phase G1 artifact (see ~/documentation/hermes-phase-g-plan.md).
#
# gjc's coordinator uses a deterministic launch worktree path
# (<repo>.gajae-code-worktrees/main-<hash>). A mutating run leaves that worktree
# checked out on its NEW branch; the next delegation expects a detached HEAD there
# and aborts with worktree_target_mismatch, jamming autonomous runs. gjc's
# graceful session_shutdown is the fast-path; this janitor is the net for the
# SIGHUP / SIGTERM / crash cases it misses.
#
# A launch worktree is removed ONLY when ALL of these hold:
#   (i)   the global single-flight lock (~/.gjc-bot/gjc.lock) is FREE — i.e. no
#         live gjc run is in progress. This janitor holds the lock for the whole
#         pass, so a run cannot start mid-scan (closes the timer race).
#   (ii)  no live tmux pane is CWD-inside the worktree (pane_current_path AND the
#         pane pid's /proc/<pid>/cwd).
#   (iii) it is on a BRANCH (not detached HEAD) AND older than the grace period.
#
# It NEVER touches the main checkout or any detached-HEAD worktree. Idempotent.
# Set DRY_RUN=1 to log decisions without removing anything.
#
# Reversibility: only removes orphaned throwaway launch worktrees — never source,
# never remote branches, never the main checkout.

set -euo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
GH_ROOT="${GJC_BOT_GH_ROOT:-$HOME/github/engels74-bot/fleet}"
LOCK="$STATE_DIR/gjc.lock"
LOG="$STATE_DIR/janitor.log"
GRACE_SECONDS="${JANITOR_GRACE_SECONDS:-600}"   # 10 minutes
DRY_RUN="${DRY_RUN:-0}"
GIT="${GIT_BIN:-/usr/bin/git}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

log() { printf '%s [janitor] %s\n' "$(date -Is)" "$*" >>"$LOG"; }

# Resolve a usable tmux binary. systemd's minimal PATH does NOT include the
# linuxbrew bin where tmux lives on this host, so fall back through known paths.
# Best-effort supplement only — occupancy is primarily a PATH-independent /proc
# cwd scan (below), which needs no tmux at all.
TMUX_BIN=""
for _c in "${TMUX_BIN_OVERRIDE:-}" "$(command -v tmux 2>/dev/null || true)" \
          /home/linuxbrew/.linuxbrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
  if [ -n "$_c" ] && [ -x "$_c" ]; then TMUX_BIN="$_c"; break; fi
done

# Emit one absolute path per line for every path "occupied" by a live process.
# Primary: a PATH-independent scan of every readable /proc/<pid>/cwd (catches the
# gjc run, an editor, or an idle shell sitting inside a worktree). Supplement:
# tmux pane_current_path (best-effort, only if a tmux binary resolved).
occupied_paths() {
  local pid cwd
  for pid in /proc/[0-9]*; do
    cwd="$(readlink -f "$pid/cwd" 2>/dev/null || true)"
    [ -n "$cwd" ] && printf '%s\n' "$cwd"
  done
  if [ -n "$TMUX_BIN" ]; then
    "$TMUX_BIN" list-panes -a -F '#{pane_current_path}' 2>/dev/null || true
  fi
}

# path_is_occupied <worktree_path> <occupied_list_file>
path_is_occupied() {
  local wt="$1" list="$2" p
  wt="${wt%/}"
  while IFS= read -r p; do
    p="${p%/}"
    [ -z "$p" ] && continue
    [ "$p" = "$wt" ] && return 0
    case "$p/" in
      "$wt"/*) return 0 ;;
    esac
  done <"$list"
  return 1
}

# evaluate_worktree <repo> <wt_path> <detached?> <now_epoch> <occ_file>
evaluate_worktree() {
  local repo="$1" wt="$2" detached="$3" now="$4" occ="$5"
  [ -n "$wt" ] || return 0
  # Only ever consider worktrees inside a gjc launch bucket:
  #   <repo>.gajae-code-worktrees/*
  # Covers the INTERACTIVE lane's deterministic main-<hash> (jam source) AND the
  # AUTOMATED lane's unique run-*/issue-* worktrees. Guards below still leave a
  # clean detached main-<hash> for reuse.
  case "$wt" in
    *.gajae-code-worktrees/*) : ;;
    *) return 0 ;;
  esac
  if [ "$detached" = "1" ]; then
    log "skip: detached HEAD, leaving $wt"
    return 0
  fi
  if path_is_occupied "$wt" "$occ"; then
    log "skip: live tmux pane CWD inside $wt"
    return 0
  fi
  local mtime age
  mtime="$(stat -c %Y "$wt" 2>/dev/null || echo "$now")"
  age=$(( now - mtime ))
  if [ "$age" -lt "$GRACE_SECONDS" ]; then
    log "skip: too young (${age}s < ${GRACE_SECONDS}s) $wt"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN would remove branch launch worktree (age ${age}s): $wt"
    return 0
  fi
  if "$GIT" -C "$repo" worktree remove --force "$wt" 2>>"$LOG"; then
    "$GIT" -C "$repo" worktree prune 2>>"$LOG" || true
    log "removed orphaned launch worktree (age ${age}s): $wt"
  else
    log "ERROR: failed to remove $wt"
  fi
}

main() {
  # (i) Global single-flight lock. If a live gjc run holds it, skip the whole pass.
  exec {lockfd}>"$LOCK"
  if ! flock -n "$lockfd"; then
    log "skip-all: gjc.lock is held (a live gjc run is in progress)"
    exit 0
  fi
  # We now hold gjc.lock for the pass -> no run can start while we scan/remove.

  OCC="$(mktemp)"; trap 'rm -f "${OCC:-}"' EXIT
  occupied_paths >"$OCC" || true

  local now; now="$(date +%s)"
  shopt -s nullglob
  local repo wt detached line
  for repo in "$GH_ROOT"/*/; do
    repo="${repo%/}"
    case "$repo" in
      *.gajae-code-worktrees) continue ;;   # container dir, not a repo
    esac
    "$GIT" -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue

    wt=""; detached=0
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) wt="${line#worktree }"; detached=0 ;;
        "detached")   detached=1 ;;
        "branch "*)   detached=0 ;;
        "")           evaluate_worktree "$repo" "$wt" "$detached" "$now" "$OCC"
                      wt=""; detached=0 ;;
      esac
    done < <("$GIT" -C "$repo" worktree list --porcelain 2>/dev/null)
    if [ -n "$wt" ]; then evaluate_worktree "$repo" "$wt" "$detached" "$now" "$OCC"; fi
  done
  return 0
}

main "$@"
