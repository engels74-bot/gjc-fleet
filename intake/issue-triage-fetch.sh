#!/usr/bin/env bash
# issue-triage-fetch.sh — READ-ONLY fetch of recent open issues for the weekly
# triage agent job (Phase G3 Job 2; auto-scaled to all repos at G7). Emits a
# combined JSON array (each issue tagged with .repo) to stdout, which Hermes
# injects into the triage agent's prompt. NEVER mutates — only `gh issue list`.
# The triage agent is given no GitHub tools, so "no mutations" is structural.
set -uo pipefail

GH="${GH_BIN:-/home/linuxbrew/.linuxbrew/bin/gh}"
JQ="${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}"
GH_ROOT="${REPO_BOT_GH_ROOT:-$HOME/github/engels74-bot}"
GH_OWNER="${REPO_BOT_GH_OWNER:-engels74}"
GH_TOKEN="$(grep '^GITHUB_TOKEN=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2-)"
export GH_TOKEN
SINCE="$(date -d '7 days ago' +%F 2>/dev/null || date +%F)"

# Auto-scales to every cloned bot repo (excl. review/ + gjc worktrees).
list_bot_repos() { ( shopt -s nullglob; for d in "$GH_ROOT"/*/; do d="${d%/}"; b="${d##*/}"; case "$b" in review|*.gajae-code-worktrees) continue ;; esac; [ -d "$d/.git" ] && printf '%s ' "$b"; done ); }
REPOS="${TRIAGE_REPOS:-$(list_bot_repos)}"

emit() {
  for r in $REPOS; do
    # Some issue bodies carry raw control bytes that break jq. Strip them
    # ([:cntrl:] class; escaped \n/\t inside JSON strings are 2 chars, untouched).
    "$GH" issue list -R "$GH_OWNER/$r" --state open --search "created:>=$SINCE" \
      --json number,title,url,labels,createdAt --limit 30 2>/dev/null \
      | LC_ALL=C tr -d '[:cntrl:]' \
      | "$JQ" -c --arg r "$r" 'map(.repo=$r)' 2>/dev/null
  done
}
emit | "$JQ" -s 'add // []' 2>/dev/null || echo '[]'
