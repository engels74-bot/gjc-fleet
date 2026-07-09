#!/usr/bin/env bash
# lib/gh-ci.sh — shared GitHub CI-state helpers for gjc-bot pipeline scripts.
#
# Source this file, then call `ci_state` / `ci_red_summary`. This is the SINGLE
# SOURCE OF TRUTH for "has this ref's CI concluded green/red/pending?": both the
# advisory merge gate (merge-gate.sh:31) and the ci-fixer poller SOURCE this file and
# classify identically — there is no separate copy anywhere to drift from.
# `ci_state` returns UNKNOWN when the GitHub API itself fails (after one retry), so a
# transient 5xx / secondary-rate-limit is NEVER mistaken for a genuine "no CI" (NONE);
# callers DEFER on UNKNOWN instead of acting. `ci_red_summary` is a human-readable
# companion for GitHub <details> blocks.
#
# Sourceable with NO side effects: only function + constant definitions, guarded
# against double-source. NEVER interpolates tokens or filesystem paths into output.
#
# File-wide SC2016 disable: every single-quoted string below is a jq PROGRAM where
# `$c`, `$s`, `$x`, `$rows` are jq variables (not shell vars) — expansion would be a
# bug. (merge-gate.sh and ci-fixer.sh both SOURCE this file, so there is ONE shared
# classifier; the earlier "byte-identical copy inside merge-gate" note is obsolete.)
# shellcheck disable=SC2016

# Double-source guard (idempotent; safe to source from multiple libs/scripts).
[ -n "${_GJC_GH_CI_SH:-}" ] && return 0
_GJC_GH_CI_SH=1

# Tool binaries — env-overridable, identical defaults to the pipeline scripts.
# `:=` leaves any value a sourcing script already set (behaviour-neutral).
: "${GH:=${GH_BIN:-/home/linuxbrew/.linuxbrew/bin/gh}}"
: "${JQ:=${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}}"

# ci_state <full_repo> <sha> -> GREEN|RED|PENDING|NONE|UNKNOWN (check-runs + commit statuses)
# UNKNOWN == the GitHub API call failed (after one retry): distinct from NONE (genuine no-CI).
ci_state() {
  local repo="$1" sha="$2" checks statuses total red pending
  local raw_checks raw_statuses rc_checks rc_statuses
  # Capture each gh call's RAW stdout AND its own exit code separately (no pipe into jq —
  # a pipe would mask gh's rc behind jq's). jq parsing happens afterwards on the captures.
  raw_checks="$("$GH" api "repos/$repo/commits/$sha/check-runs?per_page=100" --paginate 2>/dev/null)"; rc_checks=$?
  raw_statuses="$("$GH" api "repos/$repo/commits/$sha/status" 2>/dev/null)"; rc_statuses=$?
  # Retry ONCE after a short backoff on ANY transient gh failure (5xx / secondary rate limit).
  if [ "$rc_checks" -ne 0 ] || [ "$rc_statuses" -ne 0 ]; then
    sleep 2
    raw_checks="$("$GH" api "repos/$repo/commits/$sha/check-runs?per_page=100" --paginate 2>/dev/null)"; rc_checks=$?
    raw_statuses="$("$GH" api "repos/$repo/commits/$sha/status" 2>/dev/null)"; rc_statuses=$?
  fi
  # Still failing after the retry -> UNKNOWN (API error, NOT "no CI"). Callers must defer.
  if [ "$rc_checks" -ne 0 ] || [ "$rc_statuses" -ne 0 ]; then printf 'UNKNOWN'; return; fi
  # BOTH gh calls succeeded: parse now, then compute total. total==0 is a GENUINE no-CI (NONE).
  checks="$(printf '%s' "$raw_checks" | "$JQ" -s '[.[].check_runs[]?]' 2>/dev/null)"
  statuses="$raw_statuses"
  [ -n "$checks" ] || checks='[]'; [ -n "$statuses" ] || statuses='{"statuses":[]}'
  total="$(( $(printf '%s' "$checks" | "$JQ" 'length' 2>/dev/null || echo 0) + $(printf '%s' "$statuses" | "$JQ" '[.statuses[]?]|length' 2>/dev/null || echo 0) ))"
  [ "$total" -eq 0 ] && { printf 'NONE'; return; }
  red="$("$JQ" -n --argjson c "$checks" --argjson s "$statuses" '([$c[]|select(.status=="completed" and ((.conclusion//"") as $x|($x!="success" and $x!="skipped" and $x!="neutral")))]|length)+([$s.statuses[]?|select(.state=="failure" or .state=="error")]|length)' 2>/dev/null)"
  pending="$("$JQ" -n --argjson c "$checks" --argjson s "$statuses" '([$c[]|select((.status//"")|test("queued|in_progress|waiting|requested|pending"))]|length)+([$s.statuses[]?|select(.state=="pending")]|length)' 2>/dev/null)"
  if [ "${red:-0}" -gt 0 ]; then printf 'RED'; elif [ "${pending:-0}" -gt 0 ]; then printf 'PENDING'; else printf 'GREEN'; fi
}

# ci_red_summary <full_repo> <sha> -> concise plain-text list of the FAILING checks
# for that sha, one bullet per check, suitable to drop inside a GitHub <details>
# block. Reads GitHub only (same auth path as ci_state). Emits NO tokens, IDs, or
# filesystem paths — just check names + their conclusion/state. Capped to keep the
# artifact small; the failing-check predicate mirrors ci_state's "red" set exactly.
ci_red_summary() {
  local repo="$1" sha="$2" checks statuses
  checks="$("$GH" api "repos/$repo/commits/$sha/check-runs?per_page=100" --paginate 2>/dev/null | "$JQ" -s '[.[].check_runs[]?]' 2>/dev/null)"
  statuses="$("$GH" api "repos/$repo/commits/$sha/status" 2>/dev/null)"
  [ -n "$checks" ] || checks='[]'; [ -n "$statuses" ] || statuses='{"statuses":[]}'
  "$JQ" -rn --argjson c "$checks" --argjson s "$statuses" '
    ( [ $c[] | select(.status=="completed" and ((.conclusion//"") as $x | ($x!="success" and $x!="skipped" and $x!="neutral")))
              | "- \(.name // "check"): \(.conclusion // "failure")" ]
    + [ $s.statuses[]? | select(.state=="failure" or .state=="error")
              | "- \(.context // "status"): \(.state)" ] ) as $rows
    | if ($rows|length)==0 then "No failing checks reported for this commit."
      else ($rows[0:25] | join("\n"))
           + (if ($rows|length)>25 then "\n… (\($rows|length-25) more)" else "" end)
      end
  ' 2>/dev/null || printf 'CI summary unavailable.'
}
