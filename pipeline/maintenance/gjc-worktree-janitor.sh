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

# ── tmux coordinator-session reaper (Workstream I) ───────────────────────────
# HARD-OFF by default. This script runs LIVE from the repo on a 2-minute timer,
# so the reaper MUST be fully inert unless explicitly enabled. The enable knob is
# UNSET in the live env until a later workstream wires [janitor].tmux_reap_enabled
# through render; with it unset/0 this pass does nothing at all.
TMUX_REAP_ENABLED="${JANITOR_TMUX_REAP_ENABLED:-0}"
TMUX_GRACE_SECONDS="${JANITOR_TMUX_GRACE_SECONDS:-1800}"        # 30 min (from [janitor].tmux_grace_mins)
# A gjc-coordinator-* tmux session with NO matching state file is unknown
# provenance -> reaped only past a MUCH larger fallback (conservative).
TMUX_NOSTATE_SECONDS="${JANITOR_TMUX_NOSTATE_SECONDS:-86400}"   # 24 hours
COORD_STATE_ROOT="${JANITOR_COORD_STATE_ROOT:-$HOME/.hermes/.gjc/state/coordinator-mcp}"
JQ="${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
# gjc-reap.sh RE-INVOKES the janitor at its end; pass JANITOR_BIN=/bin/true when
# we call it so it does NOT recurse back into us.
GJC_REAP_BIN="${JANITOR_REAP_BIN:-$SCRIPTS_DIR/run/gjc-reap.sh}"

# ── log-prune (K3) ───────────────────────────────────────────────────────────
LOGS_DIR="${JANITOR_LOGS_DIR:-$STATE_DIR/logs}"                 # per-run engine logs (created by a later workstream)
LOG_RETENTION_DAYS="${JANITOR_LOG_RETENTION_DAYS:-14}"
LANE_LOG_MAX_BYTES="${JANITOR_LANE_LOG_MAX_BYTES:-10485760}"    # 10 MiB size cap for shared lane logs
LANE_LOG_KEEP_LINES="${JANITOR_LANE_LOG_KEEP_LINES:-5000}"

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

# find_coord_state_file <session> — print the coordinator-mcp state file for a
# session, searched across all <bot>/<repo> dirs. Empty output if none exists.
find_coord_state_file() {
  local session="$1" f
  shopt -s nullglob
  for f in "$COORD_STATE_ROOT"/*/*/session-states/"$session".json; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 0
}

# do_tmux_reap <session> <detail> — DRY_RUN logs the intent and takes NO action;
# otherwise invokes gjc-reap.sh with JANITOR_BIN=/bin/true (recursion break).
do_tmux_reap() {
  local name="$1" detail="$2"
  if [ "$DRY_RUN" = "1" ]; then
    log "tmux-reap: DRY_RUN would reap $name: $detail"
    return 0
  fi
  log "tmux-reap: reaping $name: $detail"
  JANITOR_BIN=/bin/true "$GJC_REAP_BIN" "$name" >>"$LOG" 2>&1 \
    || log "tmux-reap: ERROR gjc-reap failed for $name"
}

# consider_tmux_session <name> <created_epoch> <now_epoch> — decide + (dry-run) reap ONE session.
# Reaps IFF: state ∈ {completed,stale} AND live==false AND updated_at older than the grace window.
# Fail-safe: any missing/null/unparseable required field, or an unreadable state file, SKIPS.
consider_tmux_session() {
  local name="$1" created="$2" now="$3"
  local sf state live updated upd_epoch age

  sf="$(find_coord_state_file "$name")"

  # Unknown provenance (no state file): reap only past the large fallback window.
  if [ -z "$sf" ]; then
    case "$created" in
      ''|*[!0-9]*) log "tmux-reap: skip $name: no state file and unparseable created ts"; return 0 ;;
    esac
    age=$(( now - created ))
    if [ "$age" -lt "$TMUX_NOSTATE_SECONDS" ]; then
      log "tmux-reap: skip $name: no state file, too young (${age}s < ${TMUX_NOSTATE_SECONDS}s)"
      return 0
    fi
    do_tmux_reap "$name" "no-state age=${age}s"
    return 0
  fi

  # Schema-presence guard: any absent/null/unparseable required field -> SKIP.
  state="$("$JQ" -r '.state // empty' "$sf" 2>/dev/null || true)"
  live="$("$JQ" -r 'if has("live") and (.live != null) then (.live|tostring) else empty end' "$sf" 2>/dev/null || true)"
  updated="$("$JQ" -r '.updated_at // empty' "$sf" 2>/dev/null || true)"
  if [ -z "$state" ] || [ -z "$live" ] || [ -z "$updated" ]; then
    log "tmux-reap: skip $name: state file missing required field(s) (state='$state' live='$live' updated_at='$updated')"
    return 0
  fi

  [ "$live" = "false" ] || { log "tmux-reap: skip $name: live=$live"; return 0; }
  case "$state" in
    completed|stale) : ;;
    *) log "tmux-reap: skip $name: state=$state"; return 0 ;;
  esac

  upd_epoch="$(date -d "$updated" +%s 2>/dev/null || true)"
  case "$upd_epoch" in
    ''|*[!0-9]*) log "tmux-reap: skip $name: unparseable updated_at '$updated'"; return 0 ;;
  esac
  age=$(( now - upd_epoch ))
  if [ "$age" -lt "$TMUX_GRACE_SECONDS" ]; then
    log "tmux-reap: skip $name: too young (${age}s < ${TMUX_GRACE_SECONDS}s)"
    return 0
  fi

  do_tmux_reap "$name" "state=$state live=$live age=${age}s"
}

# reap_tmux_sessions — age-based reaper for orphaned gjc-coordinator-* tmux sessions.
# HARD-OFF unless JANITOR_TMUX_REAP_ENABLED=1. Guards against no tmux binary / no server.
reap_tmux_sessions() {
  [ "$TMUX_REAP_ENABLED" = "1" ] || return 0     # default-OFF: fully inert
  [ -n "$TMUX_BIN" ] || return 0                  # no tmux binary resolved -> nothing to do
  local sessions
  sessions="$("$TMUX_BIN" ls -F '#{session_name} #{session_created}' 2>/dev/null || true)"
  [ -n "$sessions" ] || return 0                  # no server / no sessions -> nothing to do

  local now; now="$(date +%s)"
  local line name created
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%% *}"; created="${line##* }"
    case "$name" in gjc-coordinator-*) : ;; *) continue ;; esac
    consider_tmux_session "$name" "$created" "$now"
  done <<<"$sessions"
}

# prune_logs (K3) — bound engine + lane log disk use. Conservative, non-fatal.
prune_logs() {
  # Per-run engine logs: delete those older than the retention window. The dir is
  # created by a later workstream; absent -> no-op.
  if [ -d "$LOGS_DIR" ]; then
    local n
    n="$(find "$LOGS_DIR" -maxdepth 1 -type f -name '*-pr*-*.log' -mtime "+$LOG_RETENTION_DAYS" -print 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${n:-0}" -gt 0 ]; then
      find "$LOGS_DIR" -maxdepth 1 -type f -name '*-pr*-*.log' -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
      log "log-prune: deleted $n engine log(s) older than ${LOG_RETENTION_DAYS}d in $LOGS_DIR"
    fi
  fi

  # Shared lane logs: size-cap via keep-last-N-lines truncate-in-place (preserves
  # the inode so live appenders keep writing to the same file).
  local lane f sz tmpf
  for lane in review.log ci-fixer.log merge-gate.log; do
    f="$STATE_DIR/$lane"
    [ -f "$f" ] || continue
    sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    [ "${sz:-0}" -gt "$LANE_LOG_MAX_BYTES" ] || continue
    tmpf="$(mktemp "${f}.trim.XXXXXX" 2>/dev/null || true)"
    [ -n "$tmpf" ] || continue
    if tail -n "$LANE_LOG_KEEP_LINES" "$f" >"$tmpf" 2>/dev/null; then
      cat "$tmpf" >"$f" 2>/dev/null || true
      log "log-prune: size-capped $lane (was ${sz}B, kept last ${LANE_LOG_KEEP_LINES} lines)"
    fi
    rm -f "$tmpf" 2>/dev/null || true
  done
}

main() {
  # (i) Global single-flight lock. If a live gjc run holds it, skip the whole pass.
  exec {lockfd}>"$LOCK"
  if ! flock -n "$lockfd"; then
    log "skip-all: gjc.lock is held (a live gjc run is in progress)"
    exit 0
  fi
  # We now hold gjc.lock for the pass -> no run can start while we scan/remove.

  # (Workstream I) Age-based tmux coordinator-session reaper — BEFORE the worktree
  # pass. Default-OFF; fully inert unless JANITOR_TMUX_REAP_ENABLED=1.
  reap_tmux_sessions || true

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

  # (K3) Log-prune — bound engine + shared-lane log disk use. Non-fatal.
  prune_logs || true
  return 0
}

# Sourceable for tests (JANITOR_NO_MAIN=1); run the full janitor pass otherwise.
[ "${JANITOR_NO_MAIN:-0}" = "1" ] || main "$@"
