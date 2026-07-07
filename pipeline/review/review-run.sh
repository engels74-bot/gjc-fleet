#!/usr/bin/env bash
# review-run.sh — Phase G5 launcher for the AI Code Review Handler (Claude Code,
# headless). Fire-and-forgets the handler for one PR, holding review.lock for its
# whole lifetime, with clawhip agent.* narration. Called by review-detector.sh.
#
# The handler is the user's response engine, logic untouched (only the runtime-context
# path references were updated for the fleet/ clone layout, 2026-07-07); this
# launcher only fills its Config block (REPO/PR_ID/REVIEW_ID/models/guidelines) at
# runtime and runs it in an ISOLATED per-repo review checkout under
# ~/github/engels74-bot/fleet/review/<repo> (own .git → never contends with the gjc lane;
# under the bot's gitconfig includeIf → bot identity + push credentials).
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
GH_ROOT="${GJC_BOT_GH_ROOT:-$HOME/github/engels74-bot/fleet}"
GH_OWNER="${GJC_BOT_GH_OWNER:-engels74}"
REVIEW_ROOT="${REVIEW_CHECKOUT_ROOT:-$GH_ROOT/review}"
REVIEW_LOCK="$STATE_DIR/review.lock"
LOG="$STATE_DIR/review.log"
TEMPLATE="${HANDLER_TEMPLATE:-$SCRIPTS_DIR/review/ai-code-review-handler-original.md}"

CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
CLAWHIP="${CLAWHIP_BIN:-$HOME/.cargo/bin/clawhip}"
GIT="${GIT_BIN:-/usr/bin/git}"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"
TIMEOUT="${TIMEOUT_BIN:-/usr/bin/timeout}"
MODEL_PRIMARY="${REVIEW_MODEL_PRIMARY:-opus}"
MODEL_FAST="${REVIEW_MODEL_FAST:-sonnet}"
GUIDELINES="${REVIEW_GUIDELINES:-AGENTS.md}"
# shellcheck disable=SC2034  # documented config knob; not consumed in this script
NOTIFY_CHANNEL="${REVIEW_NOTIFY_CHANNEL:?set in ~/.gjc-bot/gjc-bot.env (rendered from fleet.toml) — numeric Discord IDs never ship in-repo}"
RUN_TIMEOUT="${REVIEW_RUN_TIMEOUT:-5400}"                        # 90 min hard cap
SELF="$(readlink -f "$0")"
# gjc/claude/clawhip live outside the systemd PATH — own a complete one.
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
log() { printf '%s [review-run] %s\n' "$(date -Is)" "$*" >>"$LOG"; }
narrate() {
  local st="$1"; shift
  # `clawhip agent failed` requires --error; supply a default when a caller omits it
  # (otherwise the CLI errors and the failure is silently swallowed by `|| true`).
  if [ "$st" = "failed" ] && [[ " $* " != *" --error "* ]]; then
    "$CLAWHIP" agent "$st" --name "${RUN_NAME:-review}" --session "${RUN_SESSION:-review}" --error "run failed" "$@" >/dev/null 2>&1 || true
  else
    "$CLAWHIP" agent "$st" --name "${RUN_NAME:-review}" --session "${RUN_SESSION:-review}" "$@" >/dev/null 2>&1 || true
  fi
}
GH_TOKEN="$(grep '^GITHUB_TOKEN=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2-)"
export GH_TOKEN

# Ensure an isolated review checkout for <repo> exists; print its path.
ensure_checkout() {
  local repo="$1"
  local dir="$REVIEW_ROOT/$repo"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$REVIEW_ROOT"
    "$GIT" clone --quiet "https://github.com/$GH_OWNER/$repo.git" "$dir" >>"$LOG" 2>&1 || { log "clone failed for $repo"; return 1; }
  fi
  # reset to a clean default state so the handler's Phase 0 starts fresh
  "$GIT" -C "$dir" fetch --quiet origin >>"$LOG" 2>&1 || true
  "$GIT" -C "$dir" checkout --quiet -f "$("$GIT" -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || echo main)" >>"$LOG" 2>&1 || true
  printf '%s' "$dir"
}

launcher() {
  local repo="" pr="" rid=""
  while [ $# -gt 0 ]; do case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --review) rid="$2"; shift 2 ;;
    *) log "launch: unknown arg '$1'"; shift ;;
  esac; done
  [ -n "$repo" ] && [ -n "$pr" ] || { log "launch: --repo and --pr required"; return 2; }
  # non-blocking single-flight pre-check (authoritative guarantee is _handler's flock)
  "$FLOCK" -n "$REVIEW_LOCK" true || { log "launch SKIPPED (busy): review.lock held; $repo#$pr"; return 75; }
  local dir; dir="$(ensure_checkout "$repo")" || return 1
  # fill the handler Config block (logic untouched)
  local filled
  filled="$STATE_DIR/review-prompt-${repo}-${pr}-$(date +%Y%m%d-%H%M%S)-$$.md"
  sed -e "s|^REPO: .*|REPO: \"$GH_OWNER/$repo\"|" \
      -e "s|^PR_ID: .*|PR_ID: \"$pr\"|" \
      -e "s|^REVIEW_ID: .*|REVIEW_ID: \"$rid\"|" \
      -e "s|^CODING_GUIDELINES: .*|CODING_GUIDELINES: \"$GUIDELINES\"|" \
      -e "s|^MODEL_PRIMARY: .*|MODEL_PRIMARY: \"$MODEL_PRIMARY\"|" \
      -e "s|^MODEL_FAST: .*|MODEL_FAST: \"$MODEL_FAST\"|" \
      -e "s|^NOTIFY_CHANNEL: .*|NOTIFY_CHANNEL: \"$NOTIFY_CHANNEL\"|" \
      "$TEMPLATE" > "$filled"
  log "launching handler: $repo#$pr review=$rid dir=$dir prompt=$filled"
  setsid "$SELF" _handler "$repo" "$pr" "$dir" "$filled" </dev/null >>"$LOG" 2>&1 &
  return 0
}

_handler() {
  local repo="$1" pr="$2" dir="$3" filled="$4"
  RUN_NAME="review-pr-$pr"; RUN_SESSION="review-pr-$pr"
  exec 9>"$REVIEW_LOCK"
  if ! "$FLOCK" -n 9; then log "_handler: review.lock BUSY — aborting $repo#$pr"; rm -f "$filled"; return 1; fi
  narrate started
  log "_handler start $repo#$pr (Claude Code headless) cwd=$dir"
  local rc=0
  ( cd "$dir" && "$TIMEOUT" "$RUN_TIMEOUT" "$CLAUDE" -p --dangerously-skip-permissions --model "$MODEL_PRIMARY" < "$filled" ) >>"$LOG" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then log "_handler OK $repo#$pr"; narrate finished
  elif [ "$rc" -eq 124 ]; then log "_handler TIMEOUT ${RUN_TIMEOUT}s $repo#$pr"; narrate failed --summary "timeout"
  else log "_handler FAILED rc=$rc $repo#$pr"; narrate failed --summary "rc=$rc"; fi
  rm -f "$filled"
  return "$rc"
}

case "${1:-}" in
  _handler) shift; _handler "$@" ;;
  ""|-h|--help) echo "usage: review-run.sh --repo <r> --pr <N> --review <review_id>" ;;
  *) launcher "$@" ;;
esac
