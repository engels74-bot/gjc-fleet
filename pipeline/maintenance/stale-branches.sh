#!/usr/bin/env bash
# stale-branches.sh — REPORT-ONLY nightly scan for merged bot branches older than a
# threshold. It NEVER deletes anything. Prints a Discord-ready report to stdout, and
# prints NOTHING when there is nothing to report (so the Hermes no_agent cron job
# stays silent on empty). Phase G3 artifact.
#
# Scope auto-extends: it scans every git repo under ~/github/engels74-bot/fleet/
# (the fleet clone root), so a newly cloned fleet repo is covered with no change here.
set -uo pipefail

GH_ROOT="${GJC_BOT_GH_ROOT:-$HOME/github/engels74-bot/fleet}"
THRESHOLD_DAYS="${STALE_BRANCH_DAYS:-14}"
GIT="${GIT_BIN:-/usr/bin/git}"
NOW="$(date +%s)"
CUTOFF=$(( THRESHOLD_DAYS * 86400 ))

lines=()
shopt -s nullglob
for repo in "$GH_ROOT"/*/; do
  repo="${repo%/}"
  case "$repo" in *.gajae-code-worktrees) continue ;; esac
  "$GIT" -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue

  # Refresh the remote view quietly (prune deleted branches). Best-effort.
  "$GIT" -C "$repo" fetch --prune --quiet 2>/dev/null || true

  # Default branch: origin/HEAD -> origin/<default>, fallback main.
  default="$("$GIT" -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -n "$default" ] || default=main
  reponame="$(basename "$repo")"

  # Remote branches whose tip is merged into origin/<default>.
  while IFS= read -r br; do
    case "$br" in *'->'*) continue ;; esac          # skip 'origin/HEAD -> origin/main'
    br="${br#origin/}"
    [ -z "$br" ] && continue
    case "$br" in HEAD|"$default") continue ;; esac
    last="$("$GIT" -C "$repo" log -1 --format=%ct "origin/$br" 2>/dev/null || echo "$NOW")"
    age=$(( NOW - last ))
    if [ "$age" -ge "$CUTOFF" ]; then
      days=$(( age / 86400 ))
      lines+=("• ${reponame}/${br} — merged, last commit ${days}d ago")
    fi
  done < <("$GIT" -C "$repo" branch -r --merged "origin/$default" 2>/dev/null | sed 's/^[* ]*//')
done

# SILENT when there is nothing to report.
[ "${#lines[@]}" -eq 0 ] && exit 0

printf '🧹 Stale merged bot branches (≥%sd old, report-only — nothing was deleted):\n' "$THRESHOLD_DAYS"
printf '%s\n' "${lines[@]}"
printf '\nReview and delete manually if desired — this job never deletes.\n'
