#!/usr/bin/env bash
# gjc-run.sh — single execution entrypoint for gjc (Phase G, refined per the live
# gateway probe: print-mode + a UNIQUE per-run worktree, which is JAM-FREE by
# construction — see PHASE-G-FINDINGS.md "LIVE PROBE RESULTS").
#
# Roles (dispatched by the first argument):
#   launch  -> AUTOMATED launcher (fire-and-forget). Called by the Hermes triage
#              turn. Non-blocking single-flight pre-check + janitor crash-net,
#              fetch the issue (read-only), create a unique per-run worktree, write
#              the coding prompt, then DETACH a background execution and return
#              immediately (never blocks the Hermes turn).
#   _exec   -> INTERNAL background execution (do not call directly). Holds the
#              in-run flock for the run's whole lifetime (single-flight, released on
#              process death), narrates via `clawhip agent started/finished/failed`,
#              runs `gjc -p @promptfile` inside the worktree under a timeout, then
#              removes the worktree.
#   <flags> -> INTERACTIVE-lane in-tmux wrapper (used only when the coordinator
#              rewire is enabled; currently HELD by user). flock + agent.* + gjc.
#
# Single-flight is the IN-RUN flock (fire-and-forget means a launcher-held lock
# can't span the run). Narration is self-emitted (GJC_SESSION_ROUTER=clawhip emits
# only tmux.*, never agent.*).
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
GH_ROOT="${GJC_BOT_GH_ROOT:-$HOME/github/engels74-bot/fleet}"
GH_OWNER="${GJC_BOT_GH_OWNER:-engels74}"
LOCK="$STATE_DIR/gjc.lock"
LOG="$STATE_DIR/gjc-run.log"

GJC_REAL="${GJC_REAL_BIN:-$HOME/.bun/bin/gjc}"
GH="${GH_BIN:-/home/linuxbrew/.linuxbrew/bin/gh}"
CLAWHIP="${CLAWHIP_BIN:-$HOME/.cargo/bin/clawhip}"
JANITOR="${JANITOR_BIN:-$SCRIPTS_DIR/maintenance/gjc-worktree-janitor.sh}"
GIT="${GIT_BIN:-/usr/bin/git}"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"
TIMEOUT="${TIMEOUT_BIN:-/usr/bin/timeout}"
RUN_TIMEOUT="${GJC_RUN_TIMEOUT:-1800}"
SELF="$(readlink -f "$0")"

# gjc is a bun script (shebang runs `env bun`) and narration uses clawhip (cargo);
# systemd service PATHs don't include ~/.bun/bin or ~/.cargo/bin (runbook "CRITICAL
# PATH GOTCHA"). Own a complete PATH so the run works regardless of caller env.
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
log() { printf '%s [gjc-run] %s\n' "$(date -Is)" "$*" >>"$LOG"; }
narrate() {
  local st="$1"; shift
  # `clawhip agent failed` requires --error; supply a default when a caller omits it
  # (otherwise the CLI errors and the failure is silently swallowed by `|| true`).
  if [ "$st" = "failed" ] && [[ " $* " != *" --error "* ]]; then
    "$CLAWHIP" agent "$st" --name "${RUN_NAME:-gjc-run}" --session "${RUN_SESSION:-gjc-run}" --error "run failed" "$@" >/dev/null 2>&1 || true
  else
    "$CLAWHIP" agent "$st" --name "${RUN_NAME:-gjc-run}" --session "${RUN_SESSION:-gjc-run}" "$@" >/dev/null 2>&1 || true
  fi
}
slugify() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-*//; s/-*$//' | cut -c1-40; }

# ---- AUTOMATED launcher (fire-and-forget) -----------------------------------
launcher() {
  local repo="" issue="" branch="" channel=""
  # shellcheck disable=SC2034  # channel is accepted for CLI compatibility but not consumed
  while [ $# -gt 0 ]; do case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    *) log "launch: unknown arg '$1'"; shift ;;
  esac; done
  [ -n "$repo" ] && [ -n "$issue" ] || { log "launch: --repo and --issue required"; return 2; }
  local repopath="$GH_ROOT/$repo"
  [ -d "$repopath" ] || { log "launch: repo not found $repopath"; return 2; }

  # 1. non-blocking single-flight pre-check (authoritative guarantee is _exec's flock).
  #    rc 75 (EX_TEMPFAIL) tells a caller "busy, retry later" vs rc 0 "launched".
  if ! "$FLOCK" -n "$LOCK" true; then
    log "launch SKIPPED (busy): gjc.lock held; repo=$repo issue=$issue"
    return 75
  fi
  # 2. pre-run janitor crash-net
  "$JANITOR" >/dev/null 2>&1 || true
  # 3. fetch the issue (read-only) for the branch slug + prompt
  GH_TOKEN="$(grep '^GITHUB_TOKEN=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2-)"
  export GH_TOKEN
  local title body
  title="$("$GH" issue view "$issue" -R "$GH_OWNER/$repo" --json title --jq .title 2>/dev/null)"
  body="$("$GH" issue view "$issue" -R "$GH_OWNER/$repo" --json body --jq .body 2>/dev/null)"
  [ -n "$branch" ] || branch="issue-${issue}-$(slugify "$title")"
  [ "$branch" = "issue-${issue}-" ] && branch="issue-${issue}"
  # 4. create a UNIQUE per-run worktree from origin/<default>
  "$GIT" -C "$repopath" fetch --quiet origin 2>/dev/null || true
  local default; default="$("$GIT" -C "$repopath" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"; [ -n "$default" ] || default=main
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)-$$"
  local wt="${repopath}.gajae-code-worktrees/run-${stamp}"
  local session="gjc-${repo}-issue${issue}"
  if ! "$GIT" -C "$repopath" worktree add --force -B "$branch" "$wt" "origin/$default" >>"$LOG" 2>&1; then
    log "launch: worktree add failed repo=$repo branch=$branch"; return 1
  fi
  # 5. write the coding prompt (deterministic unique path; cleaned by _exec)
  local pf="$STATE_DIR/prompt-${session}-${stamp}.md"
  {
    printf 'You are the %s-bot automation working in repository %s.\n' "$GH_OWNER" "$repo"
    printf 'Resolve GitHub issue #%s.\n\nTitle: %s\n\nBody:\n%s\n\n' "$issue" "$title" "$body"
    printf 'Make the MINIMAL change that resolves it, following the repository AGENTS.md / conventions.\n'
    printf 'The current branch is %s. Commit your change there with a clear message, push the branch to origin with -u, then open a pull request against the default branch (%s).\n' "$branch" "$default"
    printf 'Do NOT modify unrelated files.\n\n'
    printf 'Write the PR body in the fleet GitHub house style (docs/46-github-house-style.md): ATX headings only, language-tagged code fences, a task-list Validation checklist, EXACTLY one attribution footer, and NO infrastructure noise (no session names, lock/spool paths, filesystem paths, tokens, or internal ids). Use EXACTLY this issue-fix skeleton, filling the <...> placeholders:\n\n'
    printf '## Summary\n\n<one or two sentences: what was broken and the minimal change that fixes it>\n\nFixes #%s\n\n' "$issue"
    # SC2016: the backticks below are LITERAL markdown code spans for the skeleton, not command
    # substitution — no expansion is intended.
    # shellcheck disable=SC2016
    printf '## Changes\n\n- `<path/to/file>`: <what changed and why>\n\n'
    # shellcheck disable=SC2016
    printf '## Validation\n\n- [x] `<exact command you ran>` — <passed / result>\n\n'
    printf 'End the PR body with EXACTLY this one attribution footer literal (nothing after it):\n\n'
    printf -- '---\n<sub>🤖 gjc fleet · issue-fix</sub>\n\n'
    printf 'Print the PR URL when done.\n'
  } >"$pf"
  # 6. DETACH the background execution and return immediately (fire-and-forget)
  log "launch OK repo=$repo issue=$issue branch=$branch wt=$wt session=$session"
  setsid "$SELF" _exec "$wt" "$repopath" "$pf" "$session" </dev/null >>"$LOG" 2>&1 &
  return 0
}

# ---- INTERNAL background execution ------------------------------------------
_exec() {
  local wt="$1" repopath="$2" pf="$3" session="$4"
  RUN_NAME="$session"; RUN_SESSION="$session"
  exec 9>"$LOCK"
  if ! "$FLOCK" -n 9; then
    log "_exec: gjc.lock BUSY — aborting $session (concurrent run won)"
    "$GIT" -C "$repopath" worktree remove --force "$wt" 2>/dev/null; rm -f "$pf"
    return 1
  fi
  narrate started
  log "_exec start session=$session wt=$wt"
  local rc=0
  ( cd "$wt" && "$TIMEOUT" "$RUN_TIMEOUT" "$GJC_REAL" -p --no-pty "@$pf" ) >>"$LOG" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then log "_exec OK session=$session"; narrate finished
  elif [ "$rc" -eq 124 ]; then log "_exec TIMEOUT ${RUN_TIMEOUT}s session=$session"; narrate failed --summary "timeout ${RUN_TIMEOUT}s"
  else log "_exec FAILED rc=$rc session=$session"; narrate failed --summary "rc=$rc"; fi
  "$GIT" -C "$repopath" worktree remove --force "$wt" 2>>"$LOG" || true
  "$GIT" -C "$repopath" worktree prune 2>>"$LOG" || true
  rm -f "$pf"
  log "_exec cleaned worktree session=$session"
  return "$rc"
}

# ---- INTERACTIVE-lane in-tmux wrapper (HELD; used when coordinator rewire on) --
wrapper() {
  RUN_NAME="${GJC_RUN_NAME:-gjc-run}"; RUN_SESSION="${GJC_RUN_SESSION:-gjc-run}"
  exec 9>"$LOCK"
  if ! "$FLOCK" -n 9; then log "wrapper: gjc.lock BUSY"; narrate failed --summary busy; return 1; fi
  log "wrapper acquired lock: $GJC_REAL $*"; narrate started
  local rc=0; "$TIMEOUT" "$RUN_TIMEOUT" "$GJC_REAL" "$@"; rc=$?
  [ "$rc" -eq 0 ] && { log "wrapper OK"; narrate finished; } || { log "wrapper rc=$rc"; narrate failed --summary "rc=$rc"; }
  return "$rc"
}

case "${1:-}" in
  launch) shift; launcher "$@" ;;
  _exec)  shift; _exec "$@" ;;
  ""|-h|--help)
    cat <<'USAGE'
usage:
  gjc-run.sh launch --repo <repo> --issue <N> [--branch <b>] [--channel <id>]
      Automated fire-and-forget: unique worktree + headless `gjc -p` + auto-cleanup.
  gjc-run.sh <gjc flags...>
      Interactive in-tmux wrapper (single-flight + narration). Used by the
      coordinator rewire (currently held).
USAGE
    ;;
  *) wrapper "$@" ;;
esac
