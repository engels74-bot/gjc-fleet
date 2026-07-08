#!/usr/bin/env bash
# review-detector.sh — Phase G5 (+ B-2 policy lane). ZERO-LLM poller. Lists open bot PRs
# and reacts to a NEW augmentcode[bot] review that CARRIES SUGGESTIONS. Two lanes, routed
# by PR AUTHOR:
#
#   * author == the bot login (engels74-bot)      -> EXISTING lane (unchanged): launch the
#       AI Code Review Handler (review-run.sh) once per fresh suggestion-carrying review.
#   * author in REVIEW_AUTOMATED_AUTHORS           -> POLICY lane (B-2, one-review policy):
#       (renovate[bot]/dependabot[bot])            consume EXACTLY ONE review, then make a
#       bounded APPLY/DISMISS/ESCALATE decision on any later review.
#   * any other (human) author                     -> untouched.
#
# Matching (positive), both lanes: review.user.login == "augmentcode[bot]" AND body matches
#   "<N> suggestion(s) posted" AND NOT "No suggestions at this time".
#
# De-dup (both lanes): reviews.jsonl (seen review-ids, own flock). The EXISTING lane records
# on EVERY poll; the POLICY lane records a review-id only after it has actually consumed /
# decided it (see the deferred-mark invariant below).
#
# ── Deferred-mark invariant (HARD — P1 #10) ──────────────────────────────────────────────
# In the POLICY lane the per-PR `#consumed` marker MUST be written under review-<repo>.lock
# BEFORE that lock is released — never "whenever a launch happens". If review-<repo>.lock is
# busy we log `deferred (lock busy)` and retry next poll (do NOT mark consumed). Combined with
# a re-check of the review-id INSIDE the lock, this guarantees exactly-one consumption even
# with overlapping poll cycles. review-<repo>.lock is a SEPARATE lock from the handler's
# global review.lock, so serialising pollers never blocks a running handler.
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
SEEN="${REVIEW_SEEN:-$STATE_DIR/reviews.jsonl}"
SEEN_LOCK="$STATE_DIR/reviews.lock"
REVIEW_LOCK="$STATE_DIR/review.lock"
LOG="$STATE_DIR/review.log"
GH="${GH_BIN:-/home/linuxbrew/.linuxbrew/bin/gh}"
JQ="${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"
RUNNER="${REVIEW_RUN_BIN:-$SCRIPTS_DIR/review/review-run.sh}"
GH_ROOT="${GJC_BOT_GH_ROOT:-$HOME/github/engels74-bot/fleet}"
GH_OWNER="${GJC_BOT_GH_OWNER:-engels74}"
BOT="${GJC_BOT_LOGIN:-engels74-bot}"
REVIEWER="${REVIEW_REVIEWER:-augmentcode[bot]}"
# B-2 policy lane config (rendered from [review.policy] into gjc-bot.env).
POLICY_LEDGER="${REVIEW_POLICY_LEDGER:-$STATE_DIR/review-policy.jsonl}"
REVIEW_AUTOMATED_AUTHORS="${REVIEW_AUTOMATED_AUTHORS:-renovate[bot] dependabot[bot]}"
MAX_HANDLER_RUNS="${REVIEW_POLICY_MAX_HANDLER_RUNS:-2}"
DECIDE_BIN="${REVIEW_DECIDE_BIN:-$SCRIPTS_DIR/review/review-policy-decide.sh}"
# REPOS auto-scales to every cloned bot repo (G7 fan-out = just clone the repos).
list_bot_repos() { ( shopt -s nullglob; for d in "$GH_ROOT"/*/; do d="${d%/}"; b="${d##*/}"; case "$b" in review|*.gajae-code-worktrees) continue ;; esac; [ -d "$d/.git" ] && printf '%s ' "$b"; done ); }
REPOS="${REVIEW_REPOS:-$(list_bot_repos)}"
DRY_RUN="${DRY_RUN:-0}"

# Shared JSONL ledger helpers (per-file flock) for the policy lane bookkeeping.
# shellcheck source=pipeline/lib/ledger.sh
source "$SCRIPTS_DIR/lib/ledger.sh"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true; touch "$SEEN"
log() { printf '%s [review-detect] %s\n' "$(date -Is)" "$*" >>"$LOG"; }
GH_TOKEN="$(grep '^GITHUB_TOKEN=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2-)"
export GH_TOKEN

seen()      { "$FLOCK" "$SEEN_LOCK" "$JQ" -e --arg k "$1" 'select(.key==$k)' "$SEEN" >/dev/null 2>&1; }
mark_seen() { "$FLOCK" "$SEEN_LOCK" bash -c "$JQ -nc --arg k '$1' --arg t '$(date -Is)' '{key:\$k,ts:\$t}' >> '$SEEN'"; }

# is_automated_author <login> -> 0 if <login> is in REVIEW_AUTOMATED_AUTHORS. Glob-safe:
# globbing is disabled while splitting so bracketed logins like "renovate[bot]" match
# literally (space- OR comma-joined lists both accepted).
is_automated_author() {
  local a="$1" x rc=1 list
  list="$(printf '%s' "$REVIEW_AUTOMATED_AUTHORS" | tr ',' ' ')"
  set -f
  for x in $list; do [ "$x" = "$a" ] && { rc=0; break; }; done
  set +f
  return "$rc"
}

# latest_suggestion_review <repo> <pr> -> prints the LAST augmentcode[bot] review JSON iff
# it carries suggestions (same gate as the existing lane); empty otherwise.
latest_suggestion_review() {
  local repo="$1" pr="$2" review rbody
  review="$("$GH" api "repos/$GH_OWNER/$repo/pulls/$pr/reviews" --paginate 2>/dev/null \
            | "$JQ" -sc --arg u "$REVIEWER" '[.[][]? | select(.user.login==$u)] | last // empty' 2>/dev/null)"
  [ -n "$review" ] && [ "$review" != "null" ] || return 1
  rbody="$(printf '%s' "$review" | "$JQ" -r '.body // ""')"
  printf '%s' "$rbody" | grep -qiE '[0-9]+ suggestion' && ! printf '%s' "$rbody" | grep -qi 'no suggestions at this time' || return 1
  printf '%s' "$review"
}

# ── EXISTING lane (bot-authored PRs) — behaviour unchanged from Phase G5 ──────────────────
existing_lane() {
  local repo="$1" pr="$2" review rid rbody key
  review="$("$GH" api "repos/$GH_OWNER/$repo/pulls/$pr/reviews" --paginate 2>/dev/null \
            | "$JQ" -sc --arg u "$REVIEWER" '[.[][]? | select(.user.login==$u)] | last // empty' 2>/dev/null)"
  [ -n "$review" ] && [ "$review" != "null" ] || return 0
  rid="$(printf '%s' "$review" | "$JQ" -r '.id')"
  rbody="$(printf '%s' "$review" | "$JQ" -r '.body // ""')"
  key="${repo}#${pr}#${rid}"

  seen "$key" && return 0           # already observed this review-id
  mark_seen "$key"                  # record on every poll, not just at launch

  if printf '%s' "$rbody" | grep -qiE '[0-9]+ suggestion' && ! printf '%s' "$rbody" | grep -qi 'no suggestions at this time'; then
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY_RUN would launch handler: $repo#$pr review $rid — '$(printf '%s' "$rbody" | head -c 50)'"
      return 0
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
}

# ── POLICY lane (automated-author PRs) ───────────────────────────────────────────────────
# policy_first_consume <repo> <pr> <rid> — consume the FIRST suggestion-carrying review.
# Enforces the deferred-mark invariant: #consumed is written under review-<repo>.lock, after a
# re-check of the review-id inside the lock, BEFORE the lock is released. Lock busy -> deferred.
policy_first_consume() {
  local repo="$1" pr="$2" rid="$3" rc
  local lock="$STATE_DIR/review-${repo}.lock"
  (
    "$FLOCK" -n 9 || exit 75
    local key="${repo}#${pr}#${rid}" runs
    seen "$key" && exit 0                                   # another poller already consumed it
    runs="$(ledger_count "$POLICY_LEDGER" "${repo}#${pr}#consumed")"
    if [ "$runs" -lt "$MAX_HANDLER_RUNS" ]; then
      ledger_mark "$POLICY_LEDGER" "${repo}#${pr}#consumed"  # deferred-mark: written before release
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN policy would consume+launch: $repo#$pr review $rid (--suppress-trigger)"
      else
        log "policy consume: $repo#$pr review $rid — launching handler (--suppress-trigger)"
        "$RUNNER" --repo "$repo" --pr "$pr" --review "$rid" --suppress-trigger || log "runner rc=$? for $repo#$pr (policy consume)"
      fi
    else
      log "policy consume skipped: $repo#$pr at max handler runs ($runs/$MAX_HANDLER_RUNS)"
    fi
    mark_seen "$key"                                        # written before release
    # Test-only barrier to make the lock-window race deterministic; no effect in prod.
    [ -n "${POLICY_TEST_HOLD:-}" ] && { read -r _ <"$POLICY_TEST_HOLD" || true; }
    exit 0
  ) 9>"$lock"
  rc=$?
  [ "$rc" -eq 75 ] && log "policy consume deferred (lock busy): $repo#$pr review $rid"
  return 0
}

# policy_decide_path <repo> <pr> <rid> — a LATER review on an already-consumed PR. Runs the
# brain decision (review-policy-decide.sh), records #decision, and on APPLY relaunches the
# handler bounded by max_handler_runs (same deferred-mark discipline). Whole step is serialised
# under review-<repo>.lock with an in-lock review-id re-check so a review is decided once.
policy_decide_path() {
  local repo="$1" pr="$2" rid="$3" rc
  local lock="$STATE_DIR/review-${repo}.lock"
  (
    "$FLOCK" -n 9 || exit 75
    local key="${repo}#${pr}#${rid}" verdict label runs
    seen "$key" && exit 0                                   # another poller already decided it
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY_RUN policy would decide: $repo#$pr review $rid"
      mark_seen "$key"; exit 0
    fi
    verdict="$("$DECIDE_BIN" --repo "$repo" --pr "$pr" --review "$rid" 2>>"$LOG")"
    label="${verdict%%:*}"
    ledger_mark "$POLICY_LEDGER" "${repo}#${pr}#decision:${label}"
    log "policy decision: $repo#$pr review $rid -> $verdict"
    if [ "$label" = "APPLY" ]; then
      runs="$(ledger_count "$POLICY_LEDGER" "${repo}#${pr}#consumed")"
      if [ "$runs" -lt "$MAX_HANDLER_RUNS" ]; then
        ledger_mark "$POLICY_LEDGER" "${repo}#${pr}#consumed"
        log "policy APPLY: $repo#$pr review $rid — relaunching handler ($runs/$MAX_HANDLER_RUNS used, --suppress-trigger)"
        "$RUNNER" --repo "$repo" --pr "$pr" --review "$rid" --suppress-trigger || log "runner rc=$? for $repo#$pr (policy relaunch)"
      else
        log "policy APPLY recorded only: $repo#$pr at max handler runs ($runs/$MAX_HANDLER_RUNS)"
      fi
    fi
    mark_seen "$key"                                        # written before release
    exit 0
  ) 9>"$lock"
  rc=$?
  [ "$rc" -eq 75 ] && log "policy decide deferred (lock busy): $repo#$pr review $rid"
  return 0
}

# policy_lane <repo> <pr> — route an automated-author PR: first review -> consume,
# later reviews on an already-consumed PR -> decision path.
policy_lane() {
  local repo="$1" pr="$2" review rid key runs
  review="$(latest_suggestion_review "$repo" "$pr")" || { log "policy no-op: $repo#$pr latest review carries no suggestions"; return 0; }
  rid="$(printf '%s' "$review" | "$JQ" -r '.id')"
  key="${repo}#${pr}#${rid}"
  seen "$key" && return 0                                   # already consumed/decided this review
  runs="$(ledger_count "$POLICY_LEDGER" "${repo}#${pr}#consumed")"
  if [ "$runs" -eq 0 ]; then
    policy_first_consume "$repo" "$pr" "$rid"
  else
    policy_decide_path "$repo" "$pr" "$rid"
  fi
}

main() {
  local repo pr author
  for repo in $REPOS; do
    while IFS=$'\t' read -r pr author; do
      [ -n "$pr" ] || continue
      if [ "$author" = "$BOT" ]; then
        existing_lane "$repo" "$pr"
      elif is_automated_author "$author"; then
        policy_lane "$repo" "$pr"
      fi
    done < <("$GH" pr list -R "$GH_OWNER/$repo" --state open --json number,author \
               --jq '.[] | "\(.number)\t\(.author.login)"' 2>/dev/null)
  done
}

# Sourceable for tests (REVIEW_DETECTOR_NO_MAIN=1); run the poll loop otherwise.
[ "${REVIEW_DETECTOR_NO_MAIN:-0}" = "1" ] || { main; exit 0; }
