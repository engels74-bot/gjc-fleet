#!/usr/bin/env bash
# review-detector.sh — Phase G5. ZERO-LLM. Polls open bot PRs for a NEW
# augmentcode[bot] review that CARRIES SUGGESTIONS and launches the AI Code Review
# Handler (via review-run.sh) exactly once per fresh review-arrival. augmentcode[bot]
# reviews every PR automatically (on open and on an `augment review` re-trigger);
# the detector's job is timing + suggestion-gating.
#
# Matching (positive): review.user.login == "augmentcode[bot]" AND body matches
#   "<N> suggestion(s) posted" AND NOT "No suggestions at this time".
# Excludes structurally: it only inspects augmentcode[bot] *formal reviews* — never
# the handler's own engels74-bot replies or its `augment review` trigger comments.
#
# De-dup: reviews.jsonl (seen review-ids, own flock) — recorded on EVERY poll (not
# only at launch), so the handler's exit at "No suggestions" can't cause a spurious
# re-launch. One handler at a time via review.lock; if held, a running handler is
# already driving the loop internally, so we mark-seen and don't relaunch.
set -uo pipefail

STATE_DIR="${REPO_BOT_STATE:-$HOME/.repo-bot}"
SCRIPTS_DIR="${REPO_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
SEEN="${REVIEW_SEEN:-$STATE_DIR/reviews.jsonl}"
SEEN_LOCK="$STATE_DIR/reviews.lock"
REVIEW_LOCK="$STATE_DIR/review.lock"
LOG="$STATE_DIR/review.log"
GH="${GH_BIN:-/home/linuxbrew/.linuxbrew/bin/gh}"
JQ="${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"
RUNNER="${REVIEW_RUN_BIN:-$SCRIPTS_DIR/review/review-run.sh}"
GH_ROOT="${REPO_BOT_GH_ROOT:-$HOME/github/engels74-bot}"
GH_OWNER="${REPO_BOT_GH_OWNER:-engels74}"
BOT="${REPO_BOT_LOGIN:-engels74-bot}"
REVIEWER="${REVIEW_REVIEWER:-augmentcode[bot]}"
# REPOS auto-scales to every cloned bot repo (G7 fan-out = just clone the repos).
list_bot_repos() { ( shopt -s nullglob; for d in "$GH_ROOT"/*/; do d="${d%/}"; b="${d##*/}"; case "$b" in review|*.gajae-code-worktrees) continue ;; esac; [ -d "$d/.git" ] && printf '%s ' "$b"; done ); }
REPOS="${REVIEW_REPOS:-$(list_bot_repos)}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true; touch "$SEEN"
log() { printf '%s [review-detect] %s\n' "$(date -Is)" "$*" >>"$LOG"; }
GH_TOKEN="$(grep '^GITHUB_TOKEN=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2-)"
export GH_TOKEN

seen()      { "$FLOCK" "$SEEN_LOCK" "$JQ" -e --arg k "$1" 'select(.key==$k)' "$SEEN" >/dev/null 2>&1; }
mark_seen() { "$FLOCK" "$SEEN_LOCK" bash -c "$JQ -nc --arg k '$1' --arg t '$(date -Is)' '{key:\$k,ts:\$t}' >> '$SEEN'"; }

for repo in $REPOS; do
  for pr in $("$GH" pr list -R "$GH_OWNER/$repo" --state open --author "$BOT" --json number --jq '.[].number' 2>/dev/null); do
    review="$("$GH" api "repos/$GH_OWNER/$repo/pulls/$pr/reviews" --paginate 2>/dev/null \
              | "$JQ" -sc --arg u "$REVIEWER" '[.[][]? | select(.user.login==$u)] | last // empty' 2>/dev/null)"
    [ -n "$review" ] && [ "$review" != "null" ] || continue
    rid="$(printf '%s' "$review" | "$JQ" -r '.id')"
    rbody="$(printf '%s' "$review" | "$JQ" -r '.body // ""')"
    key="${repo}#${pr}#${rid}"

    seen "$key" && continue          # already observed this review-id
    mark_seen "$key"                 # record on every poll, not just at launch

    if printf '%s' "$rbody" | grep -qiE '[0-9]+ suggestion' && ! printf '%s' "$rbody" | grep -qi 'no suggestions at this time'; then
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN would launch handler: $repo#$pr review $rid — '$(printf '%s' "$rbody" | head -c 50)'"
        continue
      fi
      if "$FLOCK" -n "$REVIEW_LOCK" true; then
        log "launching handler: $repo#$pr review $rid — '$(printf '%s' "$rbody" | head -c 50)'"
        "$RUNNER" --repo "$repo" --pr "$pr" --review "$rid" || log "runner returned rc=$? for $repo#$pr"
      else
        log "handler BUSY (review.lock held) — $repo#$pr review $rid handled by the running session"
      fi
    else
      log "no-op: $repo#$pr review $rid carries no suggestions"
    fi
  done
done
exit 0
