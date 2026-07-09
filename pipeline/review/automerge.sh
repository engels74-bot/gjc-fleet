#!/usr/bin/env bash
# automerge.sh — Workstream F. The bot-side AUTOMERGE lane's POLLER (timer-driven,
# guard-railed, SYNCHRONOUS). Same discipline as ci-fixer.sh / review-detector.sh: the
# systemd timer + this poller are the loop, GitHub + the ledger are the counters. There is
# NO detached handler — a merge happens inline, inside the per-repo lock.
#
# For each open PR authored by a configured automated author (renovate/dependabot) whose CI
# has concluded GREEN on HEAD and whose review policy has settled, merge it via
#   gh pr merge <pr> --squash --match-head-commit <sha>   (Opt A: bot-side, server-verified)
# and announce it. Native merge-queue is a deferred follow-up — NOT built here.
#
# ── Kill switches (ALL must allow, else exit 0 quietly) ────────────────────────────────────
#   1. AUTOMERGE_ENABLED=1            (from [automerge].enabled — DEFAULT 0/OFF)
#   2. no ~/.gjc-bot/automerge.disable marker file on the host
#   3. DRY_RUN unset/0               (DRY_RUN=1 => take NO actions, exit 0)
#   4. repo NOT in AUTOMERGE_EXCLUDE_REPOS   (per-repo, in the poll loop)
#   5. PR has NO `automerge-hold` label      (per-PR, in eligibility)
# Disabled / marker / DRY_RUN => exit 0 quietly (zero automerge records, zero merges).
#
# ── G-F1 gh capability guard (PM1 mitigation) ──────────────────────────────────────────────
# Before ANY merge this pass, feature-probe `gh pr merge --help` for the literal
# `--match-head-commit`. If ABSENT -> FAIL-CLOSED: emit exactly ONE automerge.escalation,
# refuse ALL merges this pass, NEVER call `gh pr merge`, record NO #try. (A behaviour probe,
# NOT a version-string compare — a repackaged/patched gh is judged by what it actually offers.)
#
# ── Eligibility (per open automated-author PR, OLDEST-FIRST, <=MAX_PER_POLL merges/repo/poll) ─
#   state==OPEN && !isDraft && mergeable==MERGEABLE && reviewDecision != CHANGES_REQUESTED
#   ci_state(HEAD) == GREEN            (NONE/RED never merge; UNKNOWN/PENDING defer, no #try)
#   HEAD-commit quiet period >= AUTOMERGE_MIN_HEAD_AGE_MINS  (else defer)
#   review policy SETTLED               (only for authors also in REVIEW_AUTOMATED_AUTHORS)
# Ledger short-circuits (TERMINAL, skip): #merged:<sha>, #blocked. #try is capped at
# AUTOMERGE_MAX_ATTEMPTS -> loud give-up ONCE (automerge.escalation + #blocked).
#
# ── Merge critical section (races closed inline; see the block below) ───────────────────────
#   flock -n review-<repo>.lock  +  a non-blocking PROBE of the global review.lock (either
#   busy => defer). INSIDE the lock: idempotent MERGED check -> re-fetch HEAD sha (moved =>
#   stale, defer, no #try) -> RE-CHECK ci_state (must still be GREEN) -> ledger_mark #try ->
#   `gh pr merge --match-head-commit <sha>`. Success => #merged:<sha> + an automerge embed.
#   ONLY a real `gh pr merge` attempt consumes #try.
#
# Races closed (and why each is safe):
#   * force-push between the CI check and the merge  -> server-side --match-head-commit REJECT
#     (gh errors, we treat it as stale and retry next poll; the burned #try was a real attempt).
#   * overlapping polls (timer fires mid-pass)       -> the self single-flight flock + the
#     per-repo lock + the append-only ledger + GitHub's own merge idempotency.
#   * stale-sha CI (HEAD advanced after our check)   -> re-fetch + re-check ci_state IN the lock.
#   * a rebased-away policy fix (force-push)          -> #policy-pushed containment defer (the
#     review lane's Workstream-D re-arm handles the fix; we simply wait).
#   * crash after merge, before the ledger write     -> next poll sees state==MERGED -> idempotent
#     #merged (no error, no second attempt).
set -uo pipefail

STATE_DIR="${GJC_BOT_STATE:-$HOME/.gjc-bot}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
LEDGER="${AUTOMERGE_LEDGER:-$STATE_DIR/automerge.jsonl}"
DISABLE_MARKER="${AUTOMERGE_DISABLE_MARKER:-$STATE_DIR/automerge.disable}"
LOG="${AUTOMERGE_LOG:-$STATE_DIR/automerge.log}"
GH="${GH_BIN:-/home/linuxbrew/.linuxbrew/bin/gh}"
JQ="${JQ_BIN:-/home/linuxbrew/.linuxbrew/bin/jq}"
FLOCK="${FLOCK_BIN:-/usr/bin/flock}"
GH_ROOT="${GJC_BOT_GH_ROOT:-$HOME/github/engels74-bot/fleet}"
GH_OWNER="${GJC_BOT_GH_OWNER:-engels74}"
REVIEW_LOCK="$STATE_DIR/review.lock"
# Policy ledger is OWNED by the review lane (review-detector.sh / review-policy-decide.sh);
# automerge only READS it (consumed / escalated / policy-pushed markers) to gate settlement.
POLICY_LEDGER="${REVIEW_POLICY_LEDGER:-$STATE_DIR/review-policy.jsonl}"

# Guardrail knobs (rendered from [automerge] into gjc-bot.env — render wiring is a SEPARATE
# consolidated pass; here we just read env with defaults so the lane is self-contained + OFF).
AUTOMERGE_ENABLED="${AUTOMERGE_ENABLED:-0}"
# Author scoping (rendered from [automerge].authors). Space-joined login list; a lone "-" is
# the sentinel for the EMPTY set (rendered from `authors = []`) so the lane touches no one.
AUTOMERGE_AUTHORS="${AUTOMERGE_AUTHORS:-renovate[bot] dependabot[bot]}"
AUTOMERGE_METHOD="${AUTOMERGE_METHOD:-squash}"
AUTOMERGE_MIN_HEAD_AGE_MINS="${AUTOMERGE_MIN_HEAD_AGE_MINS:-10}"
AUTOMERGE_REVIEW_WAIT_MINS="${AUTOMERGE_REVIEW_WAIT_MINS:-30}"
AUTOMERGE_MAX_ATTEMPTS="${AUTOMERGE_MAX_ATTEMPTS:-3}"
AUTOMERGE_MAX_PER_POLL="${AUTOMERGE_MAX_PER_POLL:-1}"
AUTOMERGE_EXCLUDE_REPOS="${AUTOMERGE_EXCLUDE_REPOS:-}"
DRY_RUN="${DRY_RUN:-0}"
# Only merge methods gh accepts; anything else falls back to squash (never inject a flag).
case "$AUTOMERGE_METHOD" in squash|merge|rebase) : ;; *) AUTOMERGE_METHOD="squash" ;; esac

# Policy-settlement gating consults the SAME automated-author set the review policy lane uses
# (renovate/dependabot). Authors NOT in this set skip straight to CI-only gating. Resolved
# WITHOUT `:?` so the script stays sourceable for the guardrail tests.
REVIEW_AUTOMATED_AUTHORS="${REVIEW_AUTOMATED_AUTHORS:-renovate[bot] dependabot[bot]}"

# Discord routing — reuse the already-rendered numeric ID (numeric IDs never live in the repo).
# Both the merged announcement and the loud give-up go to MERGE_GATE_CHANNEL (#gjc-approvals),
# where merge-gate and the review policy already escalate. Resolved WITHOUT `:?` so the script
# stays sourceable; emptiness is guarded at send time.
MERGE_GATE_CHANNEL="${MERGE_GATE_CHANNEL:-}"

# gjc/clawhip live outside the systemd PATH — own a complete one.
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

# Shared JSONL ledger helpers (per-file flock) for #try / #merged / #blocked bookkeeping.
# shellcheck source=pipeline/lib/ledger.sh
source "$SCRIPTS_DIR/lib/ledger.sh"
# Shared author matching (normalises `app/renovate` vs `renovate[bot]`; see the file).
# shellcheck source=pipeline/lib/authors.sh
source "$SCRIPTS_DIR/lib/authors.sh"
# Shared CI-state classifier (single source of truth for ci_state; identical to merge-gate).
# shellcheck source=pipeline/lib/gh-ci.sh
source "$SCRIPTS_DIR/lib/gh-ci.sh"
# Design-system Discord embed emitter (kinds automerge / automerge.escalation).
# shellcheck source=pipeline/lib/discord-embed.sh
source "$SCRIPTS_DIR/lib/discord-embed.sh"
# Shared review helpers: latest_suggestion_review + head_contains (policy-settlement gating).
# Sourced AFTER GH/JQ/GH_OWNER above so its `:=` defaults never override them.
# shellcheck source=pipeline/review/review-shared.sh
source "$SCRIPTS_DIR/review/review-shared.sh"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
log() { printf '%s [automerge] %s\n' "$(date -Is)" "$*" >>"$LOG"; }
GH_TOKEN="$(grep '^GITHUB_TOKEN=' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2-)"
export GH_TOKEN

# REPOS auto-scales to every cloned bot repo (fan-out = just clone the repos), matching
# ci-fixer.sh / merge-gate.sh / review-detector.sh; `review` and gjc worktrees are never targets.
list_bot_repos() { ( shopt -s nullglob; for d in "$GH_ROOT"/*/; do d="${d%/}"; b="${d##*/}"; case "$b" in review|*.gajae-code-worktrees) continue ;; esac; [ -d "$d/.git" ] && printf '%s ' "$b"; done ); }
REPOS="${AUTOMERGE_REPOS:-$(list_bot_repos)}"

# is_automerge_author <login> -> 0 if <login> is in AUTOMERGE_AUTHORS. Delegates to
# author_matches (lib/authors.sh), which normalises the App-login mismatch (`gh` emits
# `app/renovate` while config lists `renovate[bot]`) and preserves the "-" empty-set
# sentinel + glob-safe token splitting. Mirrors ci-fixer.sh's is_ci_fixer_author().
is_automerge_author() {
  author_matches "$1" "$AUTOMERGE_AUTHORS"
}

# is_review_automated_author <login> -> 0 if <login> is in REVIEW_AUTOMATED_AUTHORS. Delegates
# to author_matches (same App-login normalisation as is_automerge_author) so renovate/dependabot
# PRs are still recognised here; decides whether an author needs review-policy settlement gating.
is_review_automated_author() {
  author_matches "$1" "$REVIEW_AUTOMATED_AUTHORS"
}

# is_excluded_repo <repo> -> 0 if <repo> (bare name) is in AUTOMERGE_EXCLUDE_REPOS (space list).
is_excluded_repo() {
  local a="$1" x
  [ -n "$AUTOMERGE_EXCLUDE_REPOS" ] || return 1
  set -f
  for x in $AUTOMERGE_EXCLUDE_REPOS; do [ "$x" = "$a" ] && { set +f; return 0; }; done
  set +f
  return 1
}

# emit_embed <channel> <args...> — send iff the channel is configured; never fatal.
emit_embed() {
  local channel="$1"; shift
  [ -n "$channel" ] || { log "embed skipped: no channel configured"; return 0; }
  discord_embed --channel "$channel" "$@" || log "embed send failed"
}

# ── kill-switch gate ──────────────────────────────────────────────────────────────────────
# Returns 0 (proceed) only when enabled AND no marker AND not DRY_RUN; otherwise logs + fails.
gate_open() {
  if [ "$AUTOMERGE_ENABLED" != "1" ]; then log "disabled (AUTOMERGE_ENABLED=$AUTOMERGE_ENABLED) — exiting"; return 1; fi
  if [ -e "$DISABLE_MARKER" ]; then log "disable marker present ($DISABLE_MARKER) — exiting"; return 1; fi
  if [ "$DRY_RUN" = "1" ]; then log "DRY_RUN set — taking no actions, exiting"; return 1; fi
  return 0
}

# capability_ok_or_escalate — G-F1 fail-closed probe. 0 iff `gh pr merge` offers
# --match-head-commit; otherwise emit ONE automerge.escalation (deduped per host-hour so a
# 10-min poll cannot spam), log, and return 1 so the caller refuses ALL merges this pass.
capability_ok_or_escalate() {
  "$GH" pr merge --help 2>&1 | grep -q -- '--match-head-commit' && return 0
  local bkey; bkey="#gh-probe-blocked:$(date +%Y%m%d%H)"
  if ! ledger_seen "$LEDGER" "$bkey"; then
    ledger_mark "$LEDGER" "$bkey"
    emit_embed "$MERGE_GATE_CHANNEL" --kind automerge.escalation --status blocked --stage automerge \
      --message "$(printf '%b' "gh pr merge lacks --match-head-commit — auto-merge FAIL-CLOSED.\nNo PRs will be merged this pass; upgrade gh on the host.")"
  fi
  log "capability guard FAILED: 'gh pr merge' has no --match-head-commit — refusing all merges this pass"
  return 1
}

# give_up <full> <pr> <reason> — TERMINAL: mark #blocked + emit ONE automerge.escalation. Dedup
# on the #blocked key so a PR escalates AT MOST ONCE regardless of how many polls observe the cap.
give_up() {
  local full="$1" pr="$2" reason="$3" bkey
  bkey="${full}#pr:${pr}#blocked"
  ledger_seen "$LEDGER" "$bkey" && { log "give-up already recorded for $full#$pr — skipping duplicate"; return 0; }
  ledger_mark "$LEDGER" "$bkey"
  emit_embed "$MERGE_GATE_CHANNEL" --kind automerge.escalation --repo "$full" --status blocked \
    --number "$pr" --stage automerge --url "https://github.com/$full/pull/$pr" \
    --message "$(printf '%b' "${full}#${pr} — auto-merge gave up after ${AUTOMERGE_MAX_ATTEMPTS} attempts.\n${reason}\nA human should merge or investigate.")"
  log "BLOCKED $full#$pr — $reason (attempt cap ${AUTOMERGE_MAX_ATTEMPTS})"
}

# ── impure seams (individually stubbable for the offline guardrail tests) ───────────────────
# refetch_head_sha <full> <pr> — the PR's current HEAD sha straight from GitHub.
refetch_head_sha() { "$GH" pr view "$2" -R "$1" --json headRefOid --jq '.headRefOid' 2>/dev/null; }
# pr_current_state <full> <pr> — OPEN|MERGED|CLOSED (idempotency: a crash-after-merge is MERGED).
pr_current_state() { "$GH" pr view "$2" -R "$1" --json state --jq '.state' 2>/dev/null; }
# head_commit_epoch <full> <sha> — the HEAD commit's committer epoch (for the quiet-period gate).
head_commit_epoch() {
  local d; d="$("$GH" api "repos/$1/commits/$2" --jq '.commit.committer.date' 2>/dev/null)"
  [ -n "$d" ] && date -d "$d" +%s 2>/dev/null || printf ''
}
# list_open_prs <full> — OLDEST-FIRST tsv rows: number, author, isDraft, mergeable, reviewDecision,
# labels(comma-joined). Overridable so the per-poll-cap test can drive it without emulating gh --jq.
# shellcheck disable=SC2016
list_open_prs() {
  "$GH" pr list -R "$1" --state open \
    --json number,author,isDraft,mergeable,reviewDecision,labels,createdAt \
    --jq 'sort_by(.createdAt)[] | [(.number|tostring), .author.login, (.isDraft|tostring), (.mergeable // "UNKNOWN"), (.reviewDecision // ""), ([.labels[]?.name] | join(","))] | @tsv' \
    2>/dev/null
}

# newest_policy_pushed_sha <repo> <pr> — the <sha> of the most-recent #policy-pushed:<sha>
# marker in the review policy ledger (empty if none). Same shape as review-detector.sh's copy;
# automerge only READS the policy ledger. startswith-prefix + max_by(.ts) then strip the prefix.
# shellcheck disable=SC2016
newest_policy_pushed_sha() {
  local repo="$1" pr="$2" prefix
  prefix="${repo}#${pr}#policy-pushed:"
  [ -f "$POLICY_LEDGER" ] || return 0
  "$FLOCK" "${POLICY_LEDGER}.lock" "$JQ" -rs --arg p "$prefix" \
    '[.[] | select((.key // "") | startswith($p))]
     | if length==0 then empty else (max_by(.ts).key | ltrimstr($p)) end' \
    "$POLICY_LEDGER" 2>/dev/null
}

# policy_settled <repo> <full> <pr> <login> <sha> <hepoch> — is the review policy SETTLED enough
# to auto-merge? Only automated-author (renovate/dependabot) PRs are policy-gated; others return
# 0 (CI-only). Return codes: 0 settled, 1 DEFER (re-check next poll), 2 TERMINAL (block).
#   #escalated in the policy lane          -> 2 (terminal block)
#   a #policy-pushed:<sha> NOT contained    -> 1 (diverged/behind or API fail: defer; D re-arms)
#   latest suggestion review not #consumed  -> 1 (defer until the review lane consumes it)
#   no suggestion review yet                -> settled only after AUTOMERGE_REVIEW_WAIT_MINS from
#                                              the head-commit age; else 1 (defer)
policy_settled() {
  local repo="$1" full="$2" pr="$3" login="$4" sha="$5" hepoch="$6" runs now
  is_review_automated_author "$login" || return 0                 # not policy-gated -> CI-only
  ledger_seen "$POLICY_LEDGER" "${repo}#${pr}#escalated" && return 2
  local psha; psha="$(newest_policy_pushed_sha "$repo" "$pr")"
  if [ -n "$psha" ]; then
    head_contains "$full" "$psha" "$sha"                          # 0 contained / 1 diverged|behind / 2 API fail
    [ "$?" -eq 0 ] || return 1                                    # not contained (or unknown) -> defer
  fi
  if latest_suggestion_review "$repo" "$pr" >/dev/null 2>&1; then
    runs="$(ledger_count "$POLICY_LEDGER" "${repo}#${pr}#consumed")"
    [ "${runs:-0}" -ge 1 ] || return 1                            # review present but not consumed -> defer
    return 0
  fi
  # No suggestion-carrying review yet: settle only after the review-wait window (from head age).
  now="$(date +%s)"
  if [[ "$hepoch" =~ ^[0-9]+$ ]] && [ $(( now - hepoch )) -ge $(( AUTOMERGE_REVIEW_WAIT_MINS * 60 )) ]; then
    return 0
  fi
  return 1
}

# attempt_merge <repo> <full> <pr> <sha> — the merge critical section. Runs entirely inside the
# per-repo lock (+ a probe of the global review.lock). Communicates its outcome to the caller via
# the exit code so the announcement (and per-poll counting) happen in the parent, lock released:
#   0  merged (real gh pr merge success)        75 lock busy (per-repo OR review handler) -> defer
#   76 HEAD moved in-lock (stale) -> defer       77 CI no longer GREEN in-lock -> defer
#   78 already MERGED (idempotent success)       79 gh pr merge failed (head-mismatch/other) -> retry
attempt_merge() {
  local repo="$1" full="$2" pr="$3" sha="$4" rc
  local lock="$STATE_DIR/review-${repo}.lock"
  (
    "$FLOCK" -n 9 || exit 75                                      # per-repo lock busy -> defer
    "$FLOCK" -n "$REVIEW_LOCK" true || exit 75                    # global review handler busy -> defer
    # Idempotent: a prior poll (or a crash after its merge) already merged this PR.
    if [ "$(pr_current_state "$full" "$pr")" = "MERGED" ]; then
      ledger_mark "$LEDGER" "${full}#pr:${pr}#merged:${sha}"
      log "idempotent: $full#$pr already MERGED — recording #merged, no attempt"
      exit 78
    fi
    # HEAD must not have advanced since we validated CI on <sha> (force-push race).
    local rfsha; rfsha="$(refetch_head_sha "$full" "$pr")"
    if [ -z "$rfsha" ] || [ "$rfsha" != "$sha" ]; then
      log "defer $full#$pr: HEAD moved in-lock ($sha -> ${rfsha:-<none>}) — retry next poll"
      exit 76
    fi
    # Re-check CI on the exact sha we are about to merge (stale-sha CI race).
    local st; st="$(ci_state "$full" "$sha")"
    if [ "$st" != "GREEN" ]; then log "defer $full#$pr: CI=$st in-lock (was GREEN) — retry next poll"; exit 77; fi
    # This is a REAL attempt: record #try BEFORE the merge so a head-mismatch reject still burns it.
    ledger_mark "$LEDGER" "${full}#pr:${pr}#try"
    if "$GH" pr merge "$pr" -R "$full" "--$AUTOMERGE_METHOD" --match-head-commit "$sha" --delete-branch=false >>"$LOG" 2>&1; then
      ledger_mark "$LEDGER" "${full}#pr:${pr}#merged:${sha}"
      log "MERGED $full#$pr sha=$sha (--$AUTOMERGE_METHOD --match-head-commit)"
      exit 0
    fi
    log "merge attempt FAILED $full#$pr sha=$sha (head-mismatch reject or gh error) — retry next poll"
    exit 79
  ) 9>"$lock"
  rc=$?
  return "$rc"
}

# consider_pr <repo> <full> <pr> <login> <draft> <mergeable> <rdec> <has_hold> <sha> <hepoch>
# The full guardrail decision for one open automated-author PR. Returns 0 IFF a REAL merge
# happened this call (so the caller can count it toward AUTOMERGE_MAX_PER_POLL); 1 otherwise.
consider_pr() {
  local repo="$1" full="$2" pr="$3" login="$4" draft="$5" mergeable="$6" rdec="$7" has_hold="$8" sha="$9" hepoch="${10}"
  local now try ps rc

  # Terminal ledger short-circuits.
  if [ "$(ledger_count "$LEDGER" "${full}#pr:${pr}#merged")" -ge 1 ]; then log "skip $full#$pr: already merged"; return 1; fi
  if ledger_seen "$LEDGER" "${full}#pr:${pr}#blocked"; then log "skip $full#$pr: blocked (terminal)"; return 1; fi

  # Attempt cap -> loud give-up ONCE.
  try="$(ledger_count "$LEDGER" "${full}#pr:${pr}#try")"
  if [ "${try:-0}" -ge "$AUTOMERGE_MAX_ATTEMPTS" ]; then
    give_up "$full" "$pr" "CI stayed reachable but the merge never landed after ${try} attempts."
    return 1
  fi

  # Static eligibility (from the PR list fields).
  [ "$has_hold" = "1" ] && { log "defer $full#$pr: automerge-hold label present"; return 1; }
  [ "$draft" = "true" ] && { log "defer $full#$pr: draft"; return 1; }
  [ "$mergeable" = "MERGEABLE" ] || { log "defer $full#$pr: mergeable=$mergeable"; return 1; }
  [ "$rdec" = "CHANGES_REQUESTED" ] && { log "defer $full#$pr: reviewDecision=CHANGES_REQUESTED"; return 1; }

  # CI must be GREEN (NONE/RED never merge; UNKNOWN/PENDING defer). No #try on any of these.
  local st; st="$(ci_state "$full" "$sha")"
  [ "$st" = "GREEN" ] || { log "defer $full#$pr: CI=$st (sha=$sha)"; return 1; }

  # HEAD-commit quiet period.
  now="$(date +%s)"
  if ! { [[ "$hepoch" =~ ^[0-9]+$ ]] && [ $(( now - hepoch )) -ge $(( AUTOMERGE_MIN_HEAD_AGE_MINS * 60 )) ]; }; then
    log "defer $full#$pr: HEAD younger than ${AUTOMERGE_MIN_HEAD_AGE_MINS}m quiet period (epoch=${hepoch:-<none>})"
    return 1
  fi

  # Review-policy settlement (automated authors only).
  policy_settled "$repo" "$full" "$pr" "$login" "$sha" "$hepoch"; ps=$?
  case "$ps" in
    0) : ;;                                                       # settled -> proceed
    2) give_up "$full" "$pr" "Review policy ESCALATED this PR to a human."; return 1 ;;
    *) log "defer $full#$pr: review policy not settled yet"; return 1 ;;
  esac

  # Merge critical section.
  attempt_merge "$repo" "$full" "$pr" "$sha"; rc=$?
  case "$rc" in
    0)
      emit_embed "$MERGE_GATE_CHANNEL" --kind automerge --repo "$full" --status merged \
        --number "$pr" --stage automerge --url "https://github.com/$full/pull/$pr" \
        --message "$(printf '%b' "${full}#${pr} — auto-merged (--$AUTOMERGE_METHOD, CI green, policy settled)\nHEAD ${sha:0:12} verified server-side via --match-head-commit.")"
      log "announced merge $full#$pr"
      return 0 ;;
    78) log "idempotent merge recorded $full#$pr (no announcement)"; return 1 ;;
    *)  return 1 ;;                                               # 75/76/77/79 all logged in attempt_merge
  esac
}

# process_repo <repo> <full> — walk one repo's open PRs OLDEST-FIRST, merging automated-author
# PRs up to AUTOMERGE_MAX_PER_POLL per poll. Field-gathering (gh) lives here; the pure decision
# is consider_pr's.
process_repo() {
  local repo="$1" full="$2" merged=0
  local pr login draft mergeable rdec labels has_hold sha hepoch
  while IFS=$'\t' read -r pr login draft mergeable rdec labels; do
    [ -n "$pr" ] || continue
    is_automerge_author "$login" || continue
    has_hold=0
    printf '%s' "$labels" | tr ',' '\n' | grep -qx 'automerge-hold' && has_hold=1
    sha="$(refetch_head_sha "$full" "$pr")"
    [ -n "$sha" ] || { log "skip $full#$pr: no HEAD sha"; continue; }
    hepoch="$(head_commit_epoch "$full" "$sha")"
    if consider_pr "$repo" "$full" "$pr" "$login" "$draft" "$mergeable" "$rdec" "$has_hold" "$sha" "$hepoch"; then
      merged=$(( merged + 1 ))
      if [ "$merged" -ge "$AUTOMERGE_MAX_PER_POLL" ]; then
        log "per-poll cap reached for $full ($merged/$AUTOMERGE_MAX_PER_POLL) — stopping this repo"
        break
      fi
    fi
  done < <(list_open_prs "$full")
}

main() {
  # K5 self single-flight: one poll pass at a time. The systemd timer can fire while a slow pass
  # is still walking repos; a second overlapping poller would race the ledger + double-merge.
  # Non-blocking: on contention log + exit 0 cleanly (the running pass owns this tick). Inside
  # main() so the AUTOMERGE_NO_MAIN=1 sourced test path is unaffected.
  exec 200>"$STATE_DIR/automerge-poll.lock"; "$FLOCK" -n 200 || { log "previous pass still running"; exit 0; }
  gate_open || exit 0
  capability_ok_or_escalate || exit 0                            # G-F1 fail-closed: refuse all merges
  local repo full
  for repo in $REPOS; do
    is_excluded_repo "$repo" && { log "skip repo $repo: in AUTOMERGE_EXCLUDE_REPOS"; continue; }
    full="$GH_OWNER/$repo"
    process_repo "$repo" "$full"
  done
  exit 0
}

# Sourceable for tests (AUTOMERGE_NO_MAIN=1); run the poll loop otherwise.
[ "${AUTOMERGE_NO_MAIN:-0}" = "1" ] || main
