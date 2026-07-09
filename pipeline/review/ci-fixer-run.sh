#!/usr/bin/env bash
# ci-fixer-run.sh — Phase B-3 launcher for the CI-fix handler (headless, run through the
# fleet's configured coding engine — gjc by default, or legacy claude; see lib/engine.sh).
# Fire-and-forgets ONE bounded fix run for one CI-RED bot PR, then records the OUTCOME in
# the shell (never the LLM). Called by ci-fixer.sh once its caps + backoff allow an attempt.
#
# Cloned from review-run.sh's launcher + `setsid "$SELF" _handler …` structure, with two
# deliberate B-3 differences (disclosed):
#
#   1. PER-REPO lock, held BLOCKING. review-run.sh's _handler takes a GLOBAL review.lock
#      NON-BLOCKING (`flock -n 9`) and aborts if busy. Here the _handler takes the per-repo
#      lock review-<repo>.lock and BLOCKS on it (`flock 9`, no -n): a queued ci-fix run for
#      the same repo waits its turn instead of dropping the attempt the poller already
#      recorded. Different repos still run fully in parallel (per-repo, not global).
#   2. Outcome recording lives in the SHELL: the wrapper snapshots the PR head sha via
#      `git ls-remote` before and after the handler and classifies fixed / unchanged / stale,
#      then writes an outcome ledger record + a ci-fix result embed. The engine only makes
#      the commit + push; it does not own the truth of whether CI advanced.
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
GH_OWNER="${GJC_BOT_GH_OWNER:-engels74}"
# GH_ROOT + REVIEW_ROOT (the isolated-checkout root) are defaulted by review-checkout.sh below.
LEDGER="${CI_FIXER_LEDGER:-$STATE_DIR/ci-fixer.jsonl}"
LOG="${CI_FIXER_LOG:-$STATE_DIR/ci-fixer.log}"
TEMPLATE="${CI_FIX_HANDLER_TEMPLATE:-$SCRIPTS_DIR/review/ci-fix-handler.md}"

CLAWHIP="${CLAWHIP_BIN:-$HOME/.cargo/bin/clawhip}"
GIT="${GIT_BIN:-/usr/bin/git}"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"
# Coding engine for the fix run: "gjc" (default; inherits gjc's backend/models) or "claude"
# (legacy headless). Rendered from [review].engine into the pipeline env — the CI-fix lane
# shares the review lane's engine choice (one cutover decision for the fleet).
REVIEW_ENGINE="${REVIEW_ENGINE:-gjc}"
MODEL_PRIMARY="${REVIEW_MODEL_PRIMARY:-opus}"
MODEL_FAST="${REVIEW_MODEL_FAST:-sonnet}"
GUIDELINES="${REVIEW_GUIDELINES:-AGENTS.md}"
RUN_TIMEOUT="${CI_FIX_RUN_TIMEOUT:-3600}"                        # 60 min hard cap (engine_run)
# Result narration -> events (same channel the poller's "started" embed uses).
CI_FIX_CHANNEL="${CI_FIX_NOTIFY_CHANNEL:-${REVIEW_NOTIFY_CHANNEL:-}}"
SELF="$(readlink -f "$0")"
# gjc/claude/clawhip live outside the systemd PATH — own a complete one.
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

# shellcheck source=pipeline/lib/engine.sh
source "$SCRIPTS_DIR/lib/engine.sh"
# shellcheck source=pipeline/review/review-checkout.sh
source "$SCRIPTS_DIR/review/review-checkout.sh"
# shellcheck source=pipeline/lib/ledger.sh
source "$SCRIPTS_DIR/lib/ledger.sh"
# shellcheck source=pipeline/lib/discord-embed.sh
source "$SCRIPTS_DIR/lib/discord-embed.sh"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
log() { printf '%s [ci-fixer-run] %s\n' "$(date -Is)" "$*" >>"$LOG"; }
GH_TOKEN="$(grep '^GITHUB_TOKEN=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2-)"
export GH_TOKEN

emit_embed() {
  [ -n "$CI_FIX_CHANNEL" ] || { log "embed skipped: no channel configured"; return 0; }
  discord_embed --channel "$CI_FIX_CHANNEL" "$@" || log "embed send failed"
}

# pr_head_sha <full> <pr> — the PR head sha straight from the remote (engine-neutral, no
# branch name needed): refs/pull/<pr>/head tracks the PR head and advances on every push.
pr_head_sha() {
  local full="$1" pr="$2"
  "$GIT" ls-remote "https://github.com/$full.git" "refs/pull/$pr/head" 2>>"$LOG" | awk '{print $1}' | head -1
}

launcher() {
  local repo="" pr="" sha="" stage="ci-fix"
  while [ $# -gt 0 ]; do case "$1" in
    --repo)   repo="$2"; shift 2 ;;
    --number) pr="$2"; shift 2 ;;
    --sha)    sha="$2"; shift 2 ;;
    --stage)  stage="$2"; shift 2 ;;
    *) log "launch: unknown arg '$1'"; shift ;;
  esac; done
  [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$sha" ] || { log "launch: --repo, --number and --sha required"; return 2; }
  local full="$GH_OWNER/$repo"
  # ensure_checkout is NOT called here: it mutates the shared fleet/review/<repo> tree (git fetch
  # + checkout -f) and MUST run under the per-repo lock (K1). _handler runs it after locking.
  # attempt number (this per-pr try was already recorded by the poller before launch).
  local attempt; attempt="$(ledger_count "$LEDGER" "${full}#pr:${pr}#try")"
  # fill the handler Config block (sed on `^KEY: ` lines, mirroring review-run.sh).
  local filled
  filled="$STATE_DIR/ci-fix-prompt-${repo}-${pr}-$(date +%Y%m%d-%H%M%S)-$$.md"
  sed -e "s|^REPO: .*|REPO: \"$full\"|" \
      -e "s|^PR_ID: .*|PR_ID: \"$pr\"|" \
      -e "s|^HEAD_SHA: .*|HEAD_SHA: \"$sha\"|" \
      -e "s|^CI_FIX_ATTEMPT: .*|CI_FIX_ATTEMPT: \"$attempt\"|" \
      -e "s|^CODING_GUIDELINES: .*|CODING_GUIDELINES: \"$GUIDELINES\"|" \
      -e "s|^MODEL_PRIMARY: .*|MODEL_PRIMARY: \"$MODEL_PRIMARY\"|" \
      -e "s|^MODEL_FAST: .*|MODEL_FAST: \"$MODEL_FAST\"|" \
      "$TEMPLATE" > "$filled"
  log "launching ci-fix handler: $full#$pr sha=$sha attempt=$attempt prompt=$filled stage=$stage"
  setsid "$SELF" _handler "$repo" "$pr" "$sha" "$filled" </dev/null >>"$LOG" 2>&1 &
  return 0
}

_handler() {
  local repo="$1" pr="$2" sha="$3" filled="$4"
  local full="$GH_OWNER/$repo"
  RUN_NAME="ci-fix-pr-$pr"; RUN_SESSION="ci-fix-pr-$pr"
  # B-3 lock: PER-REPO, BLOCKING (no -n). Queue behind any concurrent ci-fix run for the
  # SAME repo instead of dropping this already-recorded attempt; other repos are unaffected.
  local lock="$STATE_DIR/review-${repo}.lock"
  exec 9>"$lock"
  "$FLOCK" 9
  # K1: the shared-tree mutation (ensure_checkout = git fetch + checkout -f) runs HERE, under the
  # per-repo lock — outside it a concurrent review/ci-fix handler's checkout would corrupt this tree.
  local dir; dir="$(ensure_checkout "$repo")" || {
    log "_handler checkout FAILED $full#$pr"
    ledger_mark "$LEDGER" "${full}#pr:${pr}#outcome:unchanged"
    emit_embed --kind ci-fix --repo "$full" --status unchanged --number "$pr" --stage ci-fix \
      --url "https://github.com/$full/pull/$pr" \
      --message "$(printf '%b' "${full}#${pr} — CI-fix could not start: checkout failed")"
    rm -f "$filled"; return 1
  }
  "$CLAWHIP" agent started --name "$RUN_NAME" --session "$RUN_SESSION" >/dev/null 2>&1 || true
  log "_handler start $full#$pr (engine=$REVIEW_ENGINE headless) cwd=$dir sha=$sha"

  # Outcome truth in the SHELL: snapshot the PR head before + after the engine run.
  local before after rc=0
  before="$(pr_head_sha "$full" "$pr")"
  if [ -n "$before" ] && [ "$before" != "$sha" ]; then
    # The branch already moved before we even started — the poller's sha is stale. Do nothing.
    log "_handler STALE $full#$pr: head moved $sha -> $before before run"
    ledger_mark "$LEDGER" "${full}#pr:${pr}#outcome:stale"
    emit_embed --kind ci-fix --repo "$full" --status stale --number "$pr" --stage ci-fix \
      --url "https://github.com/$full/pull/$pr" \
      --message "$(printf '%b' "${full}#${pr} — CI-fix skipped: branch moved before the run started")"
    rm -f "$filled"; return 0
  fi

  ( cd "$dir" && engine_run "$REVIEW_ENGINE" "$filled" "$RUN_TIMEOUT" ) >>"$LOG" 2>&1
  rc=$?
  after="$(pr_head_sha "$full" "$pr")"

  # Outcome truth = did the PR head sha change during the run? A pushed fix commit advances
  # refs/pull/<pr>/head; an identical sha means nothing was pushed. Containment DIRECTION is
  # irrelevant here — ANY sha change means the engine pushed something. (Force-push containment
  # is the review-policy re-arm path's concern, via head_contains — not this outcome check.)
  local outcome status message
  if [ "$rc" -eq 124 ]; then
    outcome="timeout"; status="failed"; message="CI-fix run timed out after ${RUN_TIMEOUT}s"
  elif [ -n "$after" ] && [ -n "$before" ] && [ "$after" != "$before" ]; then
    outcome="fixed"; status="pushed"; message="pushed a fix commit — CI will re-run"
  else
    outcome="unchanged"; status="unchanged"; message="no commit pushed — CI still needs a human or another attempt"
  fi
  ledger_mark "$LEDGER" "${full}#pr:${pr}#outcome:${outcome}"
  log "_handler DONE $full#$pr rc=$rc outcome=$outcome (before=$before after=$after)"
  if [ "$outcome" = "fixed" ]; then
    "$CLAWHIP" agent finished --name "$RUN_NAME" --session "$RUN_SESSION" >/dev/null 2>&1 || true
  else
    "$CLAWHIP" agent failed --name "$RUN_NAME" --session "$RUN_SESSION" --error "$outcome" >/dev/null 2>&1 || true
  fi
  # Result embed: green-ish when the sha advanced; amber otherwise. The LOUD ci-fix.escalation
  # (caps exhausted) is owned solely by the poller (ci-fixer.sh) so a human is paged once.
  emit_embed --kind ci-fix --repo "$full" --status "$status" --number "$pr" --stage ci-fix \
    --url "https://github.com/$full/pull/$pr" \
    --message "$(printf '%b' "${full}#${pr} — ${message}")"
  rm -f "$filled"
  return "$rc"
}

case "${1:-}" in
  _handler) shift; _handler "$@" ;;
  ""|-h|--help) echo "usage: ci-fixer-run.sh --repo <r> --number <N> --sha <headsha> [--stage ci-fix]" ;;
  *) launcher "$@" ;;
esac
