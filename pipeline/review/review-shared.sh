#!/usr/bin/env bash
# lib review-shared.sh — helpers shared by the review POLICY lane (review-detector.sh) and
# the force-push re-arm path (Workstream D). Sourced, never executed. Emits NO tokens, IDs,
# or filesystem paths — just GitHub-derived facts.
#
# Single source of truth for:
#   * latest_suggestion_review — moved here VERBATIM from review-detector.sh so the detector
#     and the re-arm path classify "does the newest augmentcode[bot] review carry suggestions"
#     identically (no second copy to drift from).
#   * head_contains            — force-push containment check via the GitHub compare API.
#   * pr_head_sha              — engine-neutral PR head sha straight from the remote.
#
# Sourceable with NO side effects: only function + constant definitions, guarded against
# double-source (same pattern as lib/ledger.sh and lib/gh-ci.sh).

# Double-source guard (idempotent; safe to source from multiple scripts).
[ -n "${_GJC_REVIEW_SHARED_SH:-}" ] && return 0
_GJC_REVIEW_SHARED_SH=1

# Tool binaries + identity — env-overridable, identical defaults to the pipeline scripts.
# `:=` leaves any value a sourcing script already set (behaviour-neutral for review-detector.sh,
# which defines these before sourcing this file).
: "${GH:=${GH_BIN:-/home/linuxbrew/.linuxbrew/bin/gh}}"
: "${JQ:=${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}}"
: "${GIT:=${GIT_BIN:-/usr/bin/git}}"
: "${GH_OWNER:=${GJC_BOT_GH_OWNER:-engels74}}"
: "${REVIEWER:=${REVIEW_REVIEWER:-augmentcode[bot]}}"

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

# pr_head_sha <full> <pr> — the PR head sha straight from the remote (engine-neutral, no
# branch name needed): refs/pull/<pr>/head tracks the PR head and advances on every push
# OR force-push. Mirrors ci-fixer-run.sh's helper.
pr_head_sha() {
  local full="$1" pr="$2"
  "$GIT" ls-remote "https://github.com/$full.git" "refs/pull/$pr/head" 2>>"${LOG:-/dev/null}" | awk '{print $1}' | head -1
}

# head_contains <full> <psha> <headsha> — is <psha> still an ANCESTOR of (contained in)
# <headsha>'s lineage? Reads GitHub compare `<psha>...<headsha>` (base=psha, head=headsha)
# `.status`. GitHub's `.status` is head-relative to the base:
#
#   identical         -> head == psha                                     -> return 0 (contained)
#   ahead             -> head is AHEAD of psha (psha is an ancestor)       -> return 0 (contained)
#   behind            -> head is BEHIND psha (psha not an ancestor of head)-> return 1 (NOT contained)
#   diverged          -> psha force-push-rebased away                      -> return 1 (NOT contained)
#   <empty>           -> API failure / unexpected                         -> return 2 (DISTINCT: DEFER)
#
# So a normal advance (renovate/CI adds a commit ON TOP of psha => `ahead`) keeps psha
# contained (return 0), while a force-push that rebases psha away (`diverged`) or a reset
# behind it (`behind`) reports NOT contained (return 1). The re-arm caller re-arms on 1,
# no-ops on 0, and DEFERs on 2 — matching the plan's "compare -> diverged/behind -> re-arm".
# Emits nothing.
head_contains() {
  local full="$1" psha="$2" headsha="$3" status
  status="$("$GH" api "repos/$full/compare/$psha...$headsha" 2>/dev/null | "$JQ" -r '.status // empty' 2>/dev/null)"
  case "$status" in
    identical|ahead)  return 0 ;;
    behind|diverged)  return 1 ;;
    *)                return 2 ;;
  esac
}
