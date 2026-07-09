#!/usr/bin/env bash
# review-run.sh — Phase G5 launcher for the AI Code Review Handler (headless, run
# through the fleet's configured coding engine — gjc by default, or legacy claude;
# see lib/engine.sh). Fire-and-forgets the handler for one PR, holding review.lock
# for its whole lifetime, with clawhip agent.* narration. Called by review-detector.sh.
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

CLAWHIP="${CLAWHIP_BIN:-$HOME/.cargo/bin/clawhip}"
GIT="${GIT_BIN:-/usr/bin/git}"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"
# Coding engine for the handler run: "gjc" (default; inherits gjc's backend/models)
# or "claude" (legacy headless). Rendered from [review].engine into the pipeline env.
# The engine binary + timeout live in lib/engine.sh; MODEL_PRIMARY is consumed there
# ONLY on the claude path.
REVIEW_ENGINE="${REVIEW_ENGINE:-gjc}"
MODEL_PRIMARY="${REVIEW_MODEL_PRIMARY:-opus}"
MODEL_FAST="${REVIEW_MODEL_FAST:-sonnet}"
GUIDELINES="${REVIEW_GUIDELINES:-AGENTS.md}"
# shellcheck disable=SC2034  # documented config knob; not consumed in this script
NOTIFY_CHANNEL="${REVIEW_NOTIFY_CHANNEL:?set in ~/.gjc-bot/gjc-bot.env (rendered from fleet.toml) — numeric Discord IDs never ship in-repo}"
RUN_TIMEOUT="${REVIEW_RUN_TIMEOUT:-5400}"                        # 90 min hard cap
SELF="$(readlink -f "$0")"
# gjc/claude/clawhip live outside the systemd PATH — own a complete one.
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

# shellcheck source=pipeline/lib/engine.sh
source "$SCRIPTS_DIR/lib/engine.sh"

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
  local repo="" pr="" rid="" suppress="0"
  while [ $# -gt 0 ]; do case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --review) rid="$2"; shift 2 ;;
    # B-2 one-review policy: withhold Phase 7's `augment review` re-trigger, so an
    # automated-author PR's review is consumed exactly once instead of looping.
    --suppress-trigger) suppress="1"; shift ;;
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
      -e "s|^SUPPRESS_TRIGGER: .*|SUPPRESS_TRIGGER: \"$suppress\"|" \
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
  # K1 (Fork 5 Opt B): with the GLOBAL review.lock held (fd 9), ALSO take the PER-REPO
  # lock review-<repo>.lock BLOCKING on a distinct fd (8). This serialises the shared
  # fleet/review/<repo> working tree against ci-fixer-run.sh's _handler, which mutates the
  # same checkout under the SAME per-repo lock. Lock order is GLOBAL (fd 9) -> PER-REPO
  # (fd 8); it is deadlock-free BY CONSTRUCTION because ci-fixer-run NEVER acquires the
  # global review.lock, so the two lanes can never form a wait cycle. fd 8 stays open until
  # _handler returns, so the per-repo lock is held across the whole engine_run mutation window.
  local rlock="$STATE_DIR/review-${repo}.lock"
  exec 8>"$rlock"
  "$FLOCK" 8
  narrate started
  log "_handler start $repo#$pr (engine=$REVIEW_ENGINE headless) cwd=$dir"
  local rc=0
  ( cd "$dir" && engine_run "$REVIEW_ENGINE" "$filled" "$RUN_TIMEOUT" ) >>"$LOG" 2>&1
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
