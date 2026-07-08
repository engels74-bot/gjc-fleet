#!/usr/bin/env bash
# lib/github-md.sh — GitHub-Flavored-Markdown composition helpers for gjc-bot
# artifacts (PR comments, review bodies, <details> blocks).
#
# Source this file, then call gmd_h3 / gmd_fence / gmd_details / gmd_footer.
#
# ┌─ HARD RULE (sanitiser) ────────────────────────────────────────────────────┐
# │ These helpers must NEVER emit secrets/tokens, numeric IDs (PR/run/session),  │
# │ or lock/spool/state FILESYSTEM PATHS into GitHub-bound text. This is         │
# │ enforced BY CONSTRUCTION: every helper below only formats the exact argument │
# │ text the caller passes — none of them read the environment, tokens, $HOME,   │
# │ or any state path. The caller is responsible for never PASSING such values;  │
# │ the helpers add nothing sensitive of their own. Keep it that way: do not add │
# │ a helper here that interpolates env vars, `$STATE_DIR`, `$*_LOCK`, IDs, etc. │
# └────────────────────────────────────────────────────────────────────────────┘
#
# Sourceable with NO side effects: only function + constant definitions, guarded
# against double-source.
#
# File-wide SC2016 disable: the single-quoted printf formats below contain LITERAL
# markdown code-fence backticks (```), not shell command substitution — the `%s`
# args are the only expansions and they are already passed as separate arguments.
# shellcheck disable=SC2016

# Double-source guard (idempotent; safe to source from multiple libs/scripts).
[ -n "${_GJC_GITHUB_MD_SH:-}" ] && return 0
_GJC_GITHUB_MD_SH=1

# gmd_h3 <text> -> an ATX H3 heading.
gmd_h3() {
  printf '### %s\n' "${1-}"
}

# gmd_fence <lang> <content> -> a language-tagged fenced code block.
gmd_fence() {
  local lang="${1-}" content="${2-}"
  printf '```%s\n%s\n```\n' "$lang" "$content"
}

# gmd_details <summary> <content> -> a <details> block whose content is inside a
# fenced code block, BYTE/LINE-CAPPED to keep artifacts small. Caps default to
# 1000 bytes / 15 lines (override via GMD_DETAILS_MAX_BYTES / GMD_DETAILS_MAX_LINES);
# when a cap trips, a plain note recording the cap is appended inside the block.
gmd_details() {
  local summary="${1-}" content="${2-}"
  local cap_bytes="${GMD_DETAILS_MAX_BYTES:-1000}" cap_lines="${GMD_DETAILS_MAX_LINES:-15}"
  local body="$content" note="" nlines nbytes
  nlines="$(printf '%s\n' "$content" | wc -l)"
  if [ "$nlines" -gt "$cap_lines" ]; then
    body="$(printf '%s\n' "$content" | head -n "$cap_lines")"
    note="… (truncated to first $cap_lines lines)"
  fi
  nbytes="$(printf '%s' "$body" | wc -c)"
  if [ "$nbytes" -gt "$cap_bytes" ]; then
    body="$(printf '%s' "$body" | head -c "$cap_bytes")"
    note="… (truncated to first $cap_bytes bytes)"
  fi
  printf '<details><summary>%s</summary>\n\n```\n%s\n```\n' "$summary" "$body"
  [ -n "$note" ] && printf '%s\n' "$note"
  printf '</details>\n'
}

# gmd_footer <stage> <trigger_url> -> exactly ONE standard attribution footer for a
# top-level artifact. <trigger_url> is optional; omit/empty to drop the link.
gmd_footer() {
  local stage="${1-}" url="${2-}"
  if [ -n "$url" ]; then
    printf -- '\n---\n<sub>🤖 gjc fleet · %s · <a href="%s">trigger</a></sub>\n' "$stage" "$url"
  else
    printf -- '\n---\n<sub>🤖 gjc fleet · %s</sub>\n' "$stage"
  fi
}
