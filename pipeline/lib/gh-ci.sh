#!/usr/bin/env bash
# lib/gh-ci.sh — shared GitHub CI-state helpers for gjc-bot pipeline scripts.
#
# Source this file, then call `ci_state` / `ci_red_summary`. This is the single
# source of truth for "has this ref's CI concluded green/red/pending?" — the
# `ci_state` body is extracted VERBATIM from merge-gate.sh so the advisory merge
# gate and the future ci-fixer classify identically. `ci_red_summary` is a new
# human-readable companion for GitHub <details> blocks.
#
# Sourceable with NO side effects: only function + constant definitions, guarded
# against double-source. NEVER interpolates tokens or filesystem paths into output.
#
# File-wide SC2016 disable: every single-quoted string below is a jq PROGRAM where
# `$c`, `$s`, `$x`, `$rows` are jq variables (not shell vars) — expansion would be a
# bug, and this also keeps the extracted ci_state body byte-identical to merge-gate.
# shellcheck disable=SC2016

# Double-source guard (idempotent; safe to source from multiple libs/scripts).
[ -n "${_GJC_GH_CI_SH:-}" ] && return 0
_GJC_GH_CI_SH=1

# Tool binaries — env-overridable, identical defaults to the pipeline scripts.
# `:=` leaves any value a sourcing script already set (behaviour-neutral).
: "${GH:=${GH_BIN:-/home/linuxbrew/.linuxbrew/bin/gh}}"
: "${JQ:=${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}}"

# ci_state <full_repo> <sha> -> GREEN|RED|PENDING|NONE (check-runs + commit statuses)
ci_state() {
  local repo="$1" sha="$2" checks statuses total red pending
  checks="$("$GH" api "repos/$repo/commits/$sha/check-runs?per_page=100" --paginate 2>/dev/null | "$JQ" -s '[.[].check_runs[]?]' 2>/dev/null)"
  statuses="$("$GH" api "repos/$repo/commits/$sha/status" 2>/dev/null)"
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
