#!/usr/bin/env bash
# ci-fixer.sh — Phase B-3. The fix-until-green loop's POLLER (bounded, guard-railed).
#
# Timer-driven poll: for each open BOT-AUTHORED PR whose CI has concluded RED on HEAD,
# launch ONE bounded coding-engine run (ci-fixer-run.sh) to fix CI — then, when the caps
# are exhausted, give up ONCE loudly toward a human. Never merges, never force-pushes,
# never loops in-context: the systemd timer + this poller are the loop, `git log` and the
# ledger are the counters (same discipline as review-detector.sh / merge-gate.sh).
#
# ── Kill switches (ALL THREE must allow a run) ────────────────────────────────────────────
#   1. CI_FIXER_ENABLED=1        (from [ci_fixer].enabled — DEFAULT 0/OFF)
#   2. no ~/.gjc-bot/ci-fixer.disable marker file on the host
#   3. DRY_RUN unset/0           (DRY_RUN=1 => log intended actions, take NONE)
# Disabled or marker present => exit 0 quietly (zero fixer records).
#
# ── Scope ─────────────────────────────────────────────────────────────────────────────────
# Open PRs whose author login is a member of CI_FIXER_AUTHORS (default: the bot + renovate[bot]
# + dependabot[bot]; humans addable via config). The old BOT-AUTHORED-ONLY restriction existed
# because upstream bots force-push over fleet commits, clobbering a fix commit and churning the
# loop — that risk is now mitigated by Workstream C (rebaseWhen:conflicted) + D (containment/
# re-arm), so automated-author PRs are back in scope by default.
#
# ── PR state machine (per open bot PR, on HEAD sha) ───────────────────────────────────────
#   ci_state == GREEN|PENDING|NONE  -> skip (zero fixer records).
#   ci_state == UNKNOWN             -> defer (gh API failure, NOT no-CI): never a fix attempt.
#   ci_state == RED                 -> already gave up on this PR  -> skip.
#                                      caps exhausted (per-sha OR per-pr) -> give up ONCE.
#                                      backoff not elapsed          -> skip this poll.
#                                      review-<repo>.lock busy      -> defer (skip, no attempt).
#                                      else -> record an attempt + launch one bounded run.
#
# ── Caps + backoff (bound the loop) ───────────────────────────────────────────────────────
#   per-sha:  ledger_count "<full>#sha:<sha>#try"  <  CI_FIXER_MAX_PER_SHA   (default 2)
#   per-pr:   ledger_count "<full>#pr:<pr>#try"    <  CI_FIXER_MAX_PER_PR    (default 5)
#   backoff:  min wait since the last per-pr attempt = base * 2^(attempts_this_pr) minutes,
#             base = CI_FIXER_BACKOFF_BASE_MINS (default 10)  ->  10 / 20 / 40 / 80 …
# Hitting EITHER cap is TERMINAL: post a needs-human PR comment (ci_red_summary in a
# <details>, house style) + a loud ci-fix.escalation embed, dedup on "<full>#pr:<pr>#gaveup",
# then do nothing further for that PR.
#
# Ledger keys carry a fixed trailing "#try"/"#gaveup"/"#outcome:*" segment so a startswith
# count can never bleed across numeric ids (pr 1 vs pr 12) or across namespaces.
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
LEDGER="${CI_FIXER_LEDGER:-$STATE_DIR/ci-fixer.jsonl}"
DISABLE_MARKER="${CI_FIXER_DISABLE_MARKER:-$STATE_DIR/ci-fixer.disable}"
LOG="${CI_FIXER_LOG:-$STATE_DIR/ci-fixer.log}"
GH="${GH_BIN:-/home/linuxbrew/.linuxbrew/bin/gh}"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"
RUNNER="${CI_FIXER_RUN_BIN:-$SCRIPTS_DIR/review/ci-fixer-run.sh}"
GH_ROOT="${GJC_BOT_GH_ROOT:-$HOME/github/engels74-bot/fleet}"
GH_OWNER="${GJC_BOT_GH_OWNER:-engels74}"
BOT="${GJC_BOT_LOGIN:-engels74-bot}"

# Guardrail knobs (rendered from [ci_fixer] into gjc-bot.env).
CI_FIXER_ENABLED="${CI_FIXER_ENABLED:-0}"
MAX_PER_SHA="${CI_FIXER_MAX_PER_SHA:-2}"
MAX_PER_PR="${CI_FIXER_MAX_PER_PR:-5}"
BACKOFF_BASE_MINS="${CI_FIXER_BACKOFF_BASE_MINS:-10}"
# Author scoping (rendered from [ci_fixer].authors). Space-joined login list; a lone "-" is
# the A1 sentinel for the EMPTY set (rendered from `authors = []`) so the fixer touches no one.
CI_FIXER_AUTHORS="${CI_FIXER_AUTHORS:-$BOT renovate[bot] dependabot[bot]}"
DRY_RUN="${DRY_RUN:-0}"

# Discord routing — reuse the already-rendered numeric IDs (numeric IDs never live in the
# repo). Started/result narration -> events; the loud give-up -> approvals (where merge-gate
# and the review policy already escalate). Resolved WITHOUT `:?` so the script stays
# sourceable for the guardrail test; emptiness is guarded at send time.
CI_FIX_CHANNEL="${CI_FIX_NOTIFY_CHANNEL:-${REVIEW_NOTIFY_CHANNEL:-}}"
CI_FIX_ESCALATE_CHANNEL="${CI_FIX_ESCALATE_CHANNEL:-${MERGE_GATE_CHANNEL:-}}"

# gjc/claude/clawhip live outside the systemd PATH — own a complete one.
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

# Shared JSONL ledger helpers (per-file flock) for caps / backoff / give-up bookkeeping.
# shellcheck source=pipeline/lib/ledger.sh
source "$SCRIPTS_DIR/lib/ledger.sh"
# Shared CI-state classifier (single source of truth for ci_state; identical to merge-gate).
# shellcheck source=pipeline/lib/gh-ci.sh
source "$SCRIPTS_DIR/lib/gh-ci.sh"
# House-style GitHub-Flavored-Markdown composition (docs/46 skeletons).
# shellcheck source=pipeline/lib/github-md.sh
source "$SCRIPTS_DIR/lib/github-md.sh"
# Design-system Discord embed emitter (kinds ci-fix / ci-fix.escalation).
# shellcheck source=pipeline/lib/discord-embed.sh
source "$SCRIPTS_DIR/lib/discord-embed.sh"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
log() { printf '%s [ci-fixer] %s\n' "$(date -Is)" "$*" >>"$LOG"; }
GH_TOKEN="$(grep '^GITHUB_TOKEN=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2-)"
export GH_TOKEN

# REPOS auto-scales to every cloned bot repo (fan-out = just clone the repos), matching
# merge-gate.sh / review-detector.sh; `review` and gjc worktrees are never targets.
list_bot_repos() { ( shopt -s nullglob; for d in "$GH_ROOT"/*/; do d="${d%/}"; b="${d##*/}"; case "$b" in review|*.gajae-code-worktrees) continue ;; esac; [ -d "$d/.git" ] && printf '%s ' "$b"; done ); }
REPOS="${CI_FIXER_REPOS:-$(list_bot_repos)}"

# is_ci_fixer_author <login> -> 0 if <login> is in CI_FIXER_AUTHORS. Glob-safe: globbing is
# disabled while splitting so bracketed logins like "renovate[bot]" match literally (space- OR
# comma-joined lists both accepted). Mirrors review-detector.sh's is_automated_author().
is_ci_fixer_author() {
  local a="$1" x rc=1 list
  # Sentinel: a lone "-" means the empty author set (rendered from `authors = []`).
  # Return non-match unconditionally so the fixer touches no one.
  [ "$CI_FIXER_AUTHORS" = "-" ] && return 1
  list="$(printf '%s' "$CI_FIXER_AUTHORS" | tr ',' ' ')"
  set -f
  for x in $list; do [ "$x" = "$a" ] && { rc=0; break; }; done
  set +f
  return "$rc"
}

# ── kill-switch gate ──────────────────────────────────────────────────────────────────────
# Returns 0 (proceed) only when enabled AND no disable marker; otherwise logs + fails.
gate_open() {
  if [ "$CI_FIXER_ENABLED" != "1" ]; then log "disabled (CI_FIXER_ENABLED=$CI_FIXER_ENABLED) — exiting"; return 1; fi
  if [ -e "$DISABLE_MARKER" ]; then log "disable marker present ($DISABLE_MARKER) — exiting"; return 1; fi
  return 0
}

# emit_embed <channel> <args...> — send iff the channel is configured; never fatal.
emit_embed() {
  local channel="$1"; shift
  [ -n "$channel" ] || { log "embed skipped: no channel configured"; return 0; }
  discord_embed --channel "$channel" "$@" || log "embed send failed"
}

# give_up <full> <pr> <sha> — TERMINAL: post a needs-human PR comment (ci_red_summary in a
# capped <details>, house style) + a loud ci-fix.escalation embed. Dedup on the #gaveup key
# so a PR escalates AT MOST ONCE regardless of how many polls observe the exhausted cap.
give_up() {
  local full="$1" pr="$2" sha="$3" summary body
  local gkey="${full}#pr:${pr}#gaveup"
  if ledger_seen "$LEDGER" "$gkey"; then log "give-up already recorded for $full#$pr — skipping duplicate notice"; return 0; fi
  if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN would GIVE UP (caps exhausted): $full#$pr sha=$sha"; ledger_mark "$LEDGER" "$gkey"; return 0; fi
  summary="$(ci_red_summary "$full" "$sha")"
  # House-style needs-human comment (docs/46 escalation skeleton): heading + claim/decision +
  # the failing-check list inside a capped <details> + a single footer. No ids/paths/tokens
  # ride the body beyond the failing-check NAMES that ci_red_summary already sanitises.
  body="$(
    gmd_h3 "Needs a human — CI still failing"
    printf '\n**Claim:** Automated CI-fix attempts are exhausted for this pull request.\n\n'
    printf '**Decision:** Stopped retrying. The fix-until-green loop hit its attempt cap without a green CI; a maintainer should take a look.\n\n'
    gmd_details "Failing checks on the current commit" "$summary"
    gmd_footer "ci-fix"
  )"
  "$GH" pr comment "$pr" -R "$full" --body "$body" >/dev/null 2>&1 || log "give-up comment failed $full#$pr"
  emit_embed "$CI_FIX_ESCALATE_CHANNEL" --kind ci-fix.escalation --repo "$full" --status gaveup \
    --number "$pr" --stage ci-fix --url "https://github.com/$full/pull/$pr" \
    --message "$(printf '%b' "${full}#${pr} — CI still RED after ${MAX_PER_PR} attempts (max ${MAX_PER_SHA}/sha)\nThe fix-until-green loop gave up; a human should take over.")"
  ledger_mark "$LEDGER" "$gkey"
  log "GAVE UP $full#$pr sha=$sha (caps exhausted)"
}

# launch_fix <repo> <full> <pr> <sha> — fire the detached bounded run + a ci-fix "started"
# embed. The attempt was ALREADY recorded (BOTH #try keys, one ts) and caps + backoff already
# confirmed by consider_pr WHILE it held review-<repo>.lock (K4 atomicity); that lock has since
# been RELEASED so the detached run can re-acquire it BLOCKING. DRY_RUN is likewise handled in
# consider_pr (would-launch logged, nothing recorded), so this path only runs for real launches.
launch_fix() {
  local repo="$1" full="$2" pr="$3" sha="$4"
  local attempt rc; attempt="$(ledger_count "$LEDGER" "${full}#pr:${pr}#try")"
  log "launching ci-fix run: $full#$pr sha=$sha attempt=$attempt"
  "$RUNNER" --repo "$repo" --number "$pr" --sha "$sha" --stage ci-fix; rc=$?
  if [ "$rc" -ne 0 ]; then
    # The detached run never launched (e.g. ensure_checkout failed). The attempt is
    # still recorded (in consider_pr) so a persistently-failing launch escalates via the
    # give-up cap instead of retrying forever, but do NOT announce a "started" run that
    # isn't: the operator would otherwise wait on an outcome that never arrives.
    log "runner failed to launch for $full#$pr (rc=$rc) — skipping 'started' embed"
    return 1
  fi
  emit_embed "$CI_FIX_CHANNEL" --kind ci-fix --repo "$full" --status started \
    --number "$pr" --stage ci-fix --url "https://github.com/$full/pull/$pr" \
    --message "$(printf '%b' "${full}#${pr} — CI RED; launching fix attempt ${attempt}/${MAX_PER_PR}")"
}

# backoff_elapsed <full> <pr> <attempts> — 0 iff enough time has passed since the last per-pr
# attempt (or there is none yet). min wait = BACKOFF_BASE_MINS * 2^min(attempts,10) minutes.
backoff_elapsed() {
  local full="$1" pr="$2" attempts="$3" last last_epoch now min_wait exp
  last="$(ledger_last_ts "$LEDGER" "${full}#pr:${pr}#try")"
  [ -n "$last" ] || return 0                       # never attempted -> free to go
  last_epoch="$(date -d "$last" +%s 2>/dev/null)" || return 0
  now="$(date +%s)"
  # Cap the shift exponent so a raised MAX_PER_PR (or an unexpectedly large attempt
  # count) can't overflow 64-bit arithmetic and wrap min_wait negative -> back-to-back
  # launches. 2^10 * BACKOFF_BASE_MINS is already a multi-day ceiling.
  exp=$(( attempts > 10 ? 10 : attempts ))
  min_wait=$(( BACKOFF_BASE_MINS * 60 * (1 << exp) ))
  [ $(( now - last_epoch )) -ge "$min_wait" ]
}

# consider_pr <repo> <full> <pr> <sha> — the guardrail decision for one open bot PR. Pure
# ledger/lock logic on top of ci_state(); the network-touching bits (ci_state, gh, embeds,
# the run launch) are the only impure calls, all individually stubbable for the test.
consider_pr() {
  local repo="$1" full="$2" pr="$3" sha="$4" st lock rc
  st="$(ci_state "$full" "$sha")"
  if [ "$st" != "RED" ]; then log "skip $full#$pr: CI=$st (sha=$sha)"; return 0; fi

  # Already terminal for this PR? Nothing further (even on a new sha) — a human owns it now.
  if ledger_seen "$LEDGER" "${full}#pr:${pr}#gaveup"; then log "skip $full#$pr: already gave up"; return 0; fi

  # K4 count-then-mark ATOMICITY: hold review-<repo>.lock across the cap COUNTS *and* the #try
  # MARKING so two overlapping polls can never both read "under cap" and double-launch. The
  # acquire is NON-BLOCKING: a busy lock means a fix run already owns this repo, so we DEFER
  # (record NOTHING, no launch — a busy repo never burns a cap slot). Because the detached run
  # RE-acquires this SAME lock BLOCKING, we MARK here then RELEASE (close fd 9 by leaving the
  # subshell) BEFORE launching — holding it across the handler's lifetime would deadlock.
  lock="$STATE_DIR/review-${repo}.lock"
  (
    "$FLOCK" -n 9 || exit 75                                     # busy -> defer
    local count_sha count_pr
    count_sha="$(ledger_count "$LEDGER" "${full}#sha:${sha}#try")"
    count_pr="$(ledger_count "$LEDGER" "${full}#pr:${pr}#try")"
    # Caps (either exhausted) -> terminal give-up (once).
    if [ "$count_sha" -ge "$MAX_PER_SHA" ] || [ "$count_pr" -ge "$MAX_PER_PR" ]; then
      log "$full#$pr caps exhausted (sha $count_sha/$MAX_PER_SHA, pr $count_pr/$MAX_PER_PR) — giving up"
      give_up "$full" "$pr" "$sha"
      exit 10
    fi
    # Exponential backoff since the last per-pr attempt.
    if ! backoff_elapsed "$full" "$pr" "$count_pr"; then
      log "skip $full#$pr: backoff not elapsed (attempt ${count_pr}, base ${BACKOFF_BASE_MINS}m)"
      exit 11
    fi
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY_RUN would launch ci-fix run + record attempt: $full#$pr sha=$sha"
      exit 12
    fi
    # Record the attempt (BOTH keys) under the lock, then release + launch OUTSIDE the subshell.
    ledger_mark "$LEDGER" "${full}#pr:${pr}#try"
    ledger_mark "$LEDGER" "${full}#sha:${sha}#try"
    exit 0
  ) 9>"$lock"
  rc=$?
  case "$rc" in
    75) log "defer $full#$pr: review-${repo}.lock busy"; return 0 ;;
    0)  launch_fix "$repo" "$full" "$pr" "$sha" ;;
    *)  return 0 ;;                                              # 10 give-up / 11 backoff / 12 dry-run (all logged in-lock)
  esac
}

main() {
  # K5 self single-flight: one poll pass at a time. The systemd timer can fire while a slow
  # pass is still walking repos; a second overlapping poller would double-count/-launch.
  # Non-blocking: on contention log + exit 0 cleanly (the running pass owns this tick). Inside
  # main() so the CI_FIXER_NO_MAIN=1 sourced test path is unaffected.
  exec 200>"$STATE_DIR/ci-fixer-poll.lock"; "$FLOCK" -n 200 || { log "previous pass still running"; exit 0; }
  gate_open || exit 0
  local repo full pr login sha
  for repo in $REPOS; do
    full="$GH_OWNER/$repo"
    while IFS=$'\t' read -r pr login; do
      [ -n "$pr" ] || continue
      is_ci_fixer_author "$login" || continue
      sha="$("$GH" pr view "$pr" -R "$full" --json headRefOid --jq '.headRefOid' 2>/dev/null)"
      [ -n "$sha" ] || { log "skip $full#$pr: no HEAD sha"; continue; }
      consider_pr "$repo" "$full" "$pr" "$sha"
    done < <("$GH" pr list -R "$full" --state open --json number,author --jq '.[] | [.number, .author.login] | @tsv' 2>/dev/null)
  done
  exit 0
}

# Sourceable for tests (CI_FIXER_NO_MAIN=1); run the poll loop otherwise.
[ "${CI_FIXER_NO_MAIN:-0}" = "1" ] || main
