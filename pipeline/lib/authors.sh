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

# author_matches <login> <list-value> -> 0 iff normalize_author(<login>) equals
# normalize_author(x) for any whitespace/comma-separated token x in <list-value>.
# The `-` sentinel (whole value == "-") is the EMPTY author set (rendered from
# `authors = []`) and never matches. Glob-safe: globbing is disabled while splitting
# so bracketed logins like `renovate[bot]` match literally (space- OR comma-joined
# lists both accepted).
author_matches() {
  local login="$1" list="$2" x target rc=1 split
  [ "$list" = "-" ] && return 1
  target="$(normalize_author "$login")"
  split="$(printf '%s' "$list" | tr ',' ' ')"
  set -f
  for x in $split; do [ "$(normalize_author "$x")" = "$target" ] && { rc=0; break; }; done
  set +f
  return "$rc"
}
