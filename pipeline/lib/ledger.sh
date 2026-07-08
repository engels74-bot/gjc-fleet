#!/usr/bin/env bash
# lib/ledger.sh — shared JSONL append-only ledger helpers for gjc-bot pipeline
# scripts (dedup / rate-limit / last-seen bookkeeping).
#
# Line shape matches the existing fleet ledgers (reviews.jsonl, merge-gate.jsonl):
# one JSON object per line, `{"key":"<key>","ts":"<iso8601>"}`, jq-built so keys are
# always safely escaped.
#
# PER-FILE locking: each ledger file <f> serialises on its OWN lock "<f>.lock". A
# single global lock would needlessly serialise unrelated ledgers — that is
# explicitly avoided here. Locks/parent dirs are created on demand, so a caller may
# point at a ledger that does not exist yet.
#
# Sourceable with NO side effects: only function + constant definitions, guarded
# against double-source.
#
# File-wide SC2016 disable: the single-quoted strings below are jq PROGRAMS where
# `$k`, `$t`, `$p` are jq variables (not shell vars) — shell expansion would be a bug.
# shellcheck disable=SC2016

# Double-source guard (idempotent; safe to source from multiple libs/scripts).
[ -n "${_GJC_LEDGER_SH:-}" ] && return 0
_GJC_LEDGER_SH=1

# Tool binaries — env-overridable, identical defaults to the pipeline scripts.
: "${JQ:=${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}}"
: "${FLOCK:=${FLOCK_BIN:-/usr/bin/flock}}"

# ledger_seen <file> <key> -> 0 if <key> already recorded, 1 otherwise.
# Fixed-string membership test under the file's own lock.
ledger_seen() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  "$FLOCK" "${file}.lock" grep -qF -- "$key" "$file"
}

# ledger_mark <file> <key> -> append {"key","ts"} once, under the file's own lock.
ledger_mark() {
  local file="$1" key="$2" line
  mkdir -p -- "$(dirname -- "$file")"
  line="$("$JQ" -nc --arg k "$key" --arg t "$(date -Is)" '{key:$k,ts:$t}')" || return 1
  ( "$FLOCK" 9 || exit 1; printf '%s\n' "$line" >>"$file" ) 9>"${file}.lock"
}

# ledger_count <file> <prefix> -> number of entries whose key STARTS WITH <prefix>.
ledger_count() {
  local file="$1" prefix="$2"
  [ -f "$file" ] || { printf '0'; return; }
  "$FLOCK" "${file}.lock" "$JQ" -rs --arg p "$prefix" \
    '[.[] | select((.key // "") | startswith($p))] | length' "$file" 2>/dev/null || printf '0'
}

# ledger_last_ts <file> <prefix> -> most-recent ts among entries whose key STARTS
# WITH <prefix> (empty if none). ISO-8601 with a fixed offset sorts chronologically,
# so `max` == newest.
ledger_last_ts() {
  local file="$1" prefix="$2"
  [ -f "$file" ] || return 0
  "$FLOCK" "${file}.lock" "$JQ" -rs --arg p "$prefix" \
    '[.[] | select((.key // "") | startswith($p)) | .ts] | max // empty' "$file" 2>/dev/null
}
