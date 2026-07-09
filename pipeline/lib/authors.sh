#!/usr/bin/env bash
# lib/authors.sh — shared PR-author matching for gjc-bot pipeline lanes
# (review-detector's policy lane, ci-fixer, automerge, merge-gate carve-out).
#
# WHY normalisation exists: config (fleet.toml) lists automated authors in the
# HUMAN-READABLE GitHub-App form `renovate[bot]` / `dependabot[bot]` — the login you
# see in the PR UI. But the host's `gh` surfaces the SAME App accounts through the
# REST author.login as `app/renovate` / `app/dependabot` (verified live:
# `gh pr view <n> --json author` -> {"is_bot":true,"login":"app/renovate"}). A raw
# string compare of `renovate[bot]` against `app/renovate` is FALSE, so bot PRs would
# match NO lane. We therefore compare on a NORMALISED form: strip a leading `app/`
# prefix AND a trailing `[bot]` suffix from BOTH sides before comparing. This keeps the
# readable `renovate[bot]` form in config while matching whatever `gh` actually emits.
# A REAL account like `engels74-bot` (no `app/`, ends in `-bot` NOT `[bot]`) is
# unchanged by normalisation and keeps matching itself exactly.
#
# Sourceable with NO side effects: only function definitions, guarded against
# double-source. Pure bash — no external tools, no filesystem, no tokens.

# Double-source guard (idempotent; safe to source from multiple libs/scripts).
[ -n "${_GJC_AUTHORS_SH:-}" ] && return 0
_GJC_AUTHORS_SH=1

# normalize_author <login> -> print <login> with a leading `app/` prefix and a
# trailing `[bot]` suffix removed. `app/renovate`->`renovate`, `renovate[bot]`->
# `renovate`, `engels74-bot`->`engels74-bot` (unchanged — `-bot` is not `[bot]`).
# The brackets are escaped so `[bot]` is matched LITERALLY, not as a `b|o|t` class.
normalize_author() {
  local s="$1"
  s="${s#app/}"
  s="${s%\[bot\]}"
  printf '%s' "$s"
}

# author_matches <login> <list-value> -> 0 iff <login> matches any whitespace/comma-
# separated token x in <list-value>. Two match modes, and the distinction is a SECURITY
# boundary once auto-approve/auto-merge is on (the author check is the trust gate):
#   1. VERBATIM  — <login> == x exactly. Covers real accounts (`engels74-bot`) and any
#                  login already in the exact config form.
#   2. NORMALISED — strip `app/`+`[bot]` from both, compare — but ONLY when the OBSERVED
#                  <login> itself carries a GitHub-App marker (`app/` prefix or `[bot]`
#                  suffix). So `app/renovate` (what `gh` emits) matches config `renovate[bot]`,
#                  while a BARE, claimable human username like `renovate` can NEVER satisfy a
#                  bracketed config token. GitHub usernames cannot contain `[`/`]` and App
#                  slugs are globally unique, so the marker is un-squattable — restoring the
#                  safety the old exact-`renovate[bot]` compare had for free.
# The `-` sentinel (whole value == "-") is the EMPTY author set (rendered from `authors = []`)
# and never matches. Glob-safe: globbing is disabled while splitting so bracketed logins match
# literally (space- OR comma-joined lists both accepted).
author_matches() {
  local login="$1" list="$2" x rc=1 split
  [ "$list" = "-" ] && return 1
  split="$(printf '%s' "$list" | tr ',' ' ')"
  set -f
  for x in $split; do
    [ "$login" = "$x" ] && { rc=0; break; }                        # verbatim
    case "$login" in
      app/*|*'[bot]')                                              # observed login has an App marker
        [ "$(normalize_author "$login")" = "$(normalize_author "$x")" ] && { rc=0; break; } ;;
    esac
  done
  set +f
  return "$rc"
}
