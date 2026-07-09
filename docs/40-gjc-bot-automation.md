<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-09
sources:
  - ~/github/engels74-bot/gjc-fleet/pipeline/ (pipeline-stage layout: intake/ run/ review/
    maintenance/ lib/ — the flat ~/scripts/repo-bot/ path and the standalone gjc-bot-scripts
    repo are both DEAD/archived; systemd/ unit templates now live at the gjc-fleet repo root)
  - ~/.config/systemd/user/ (installed copies of the gjc-bot units, rendered from
    gjc-fleet/systemd/; ExecStart now points into pipeline/<stage>/)
  - ~/.hermes/scripts/ (real-file cron wrappers that exec the maintenance/ + intake/ scripts)
  - ~/.gjc-bot/ (ledgers, locks, logs, gjc-bot.env — runtime evidence)
  - ~/github/engels74-bot/gjc-fleet/render/ (renderer that produces gjc-bot.env from fleet.toml)
maintainer_notes: >
  Edit this file in isolation. Keep headings stable. Changelog is a single current-state
  rebaseline entry — rewrite this page to current state rather than appending; prior history
  lives in git. Line citations refer to the scripts in gjc-fleet/pipeline/ as re-verified
  2026-07-09 (post the drift fold-back + automation-upgrade effort: engine cutover to gjc,
  the K concurrency hardening, the D force-push re-arm, the automerge + fleet-update lanes,
  and the janitor tmux-reaper). Paths are given relative to the repo root
  ~/github/engels74-bot/gjc-fleet/, i.e. inside its pipeline/ subdir.
-->

# gjc-bot — the shell glue pipeline

> This layer is the spine of the automated system: it sequences
> **issue → triage → agent run → PR → review handling → merge gate**.
> The end-to-end walk-through with a sequence diagram lives in
> [60-data-flow-and-integration.md](60-data-flow-and-integration.md).

## Purpose

The **`pipeline/`** subdirectory of the **`gjc-fleet`** monorepo
(`~/github/engels74-bot/gjc-fleet/pipeline/` — formerly its own repo, `gjc-bot-scripts`, before the
2026-07-07 monorepo migration; before that, `gjc-bot`) is a set of Bash scripts + a shared `lib/`
that turn the three projects into an autonomous **GitHub-issue → PR → review → advisory-merge**
bot for six of engels74's application repos. The scripts are grouped by **pipeline stage**:

| Stage dir | Scripts |
|---|---|
| `intake/` | `issue-spool-adapter.sh`, `issue-triage-fetch.sh` |
| `run/` | `gjc-run.sh`, `gjc-reap.sh` |
| `review/` | `review-detector.sh`, `review-run.sh`, `merge-gate.sh`, `review-policy-decide.sh` (B-2 one-review policy), `ci-fixer.sh` + `ci-fixer-run.sh` (B-3 fix-until-green, default OFF), `automerge.sh` (F automerge lane, default OFF), `review-checkout.sh` (shared isolated-checkout helper), `review-shared.sh` (shared review helpers: `latest_suggestion_review`/`head_contains`/`pr_head_sha`), `ai-code-review-handler-original.md` + `ci-fix-handler.md` (templates), `tests/` (offline guardrail proofs) |
| `maintenance/` | `gjc-worktree-janitor.sh`, `stale-branches.sh`, `fleet-update.sh` (G nightly orchestrator, default OFF), `tool-update.sh` (headless update-ai port), `hermes-update.sh` (track-latest hermes updater) |
| `lib/` | `discord-embed.sh`, `engine.sh` (coding-engine dispatch), `gh-ci.sh` (CI-state classifier), `ledger.sh` (JSONL dedup/caps/backoff), `github-md.sh` (house-style GFM), `userctl.sh` |

The unit **templates** (`.service` / `.timer` / `.path`) that used to live in this repo's own
`systemd/` subdir now live at the `gjc-fleet` repo **root** `systemd/` — one level up from
`pipeline/` — since they're shared across the whole fleet (relay + clawhip + gjc-bot), not just
this pipeline.

> The prior flat path `~/scripts/repo-bot/` is **DEAD**, and so is the standalone `gjc-bot-scripts`
> repo (archived on GitHub, pointer README, history preserved via merge into `gjc-fleet`) — every
> script resolves its own repo root at runtime (see [Self-locating scripts](#self-locating-scripts)).

Two trigger fabrics drive it: **clawhip** (polls GitHub, emits events, writes the issue spool) and
**systemd** (path unit + timers that run the glue). Coding-work is shelled out through
`lib/engine.sh` `engine_run`, which dispatches on `[review].engine` (rendered `REVIEW_ENGINE`) —
**gjc** post-cutover (the active default; `gjc -p --no-pty "@prompt"`, inheriting gjc's own
Codex backend) with **headless `claude`** retained as a selectable legacy fallback engine.
Verdict-only work (triage, merge-gate, policy DECIDE) stays on the no-tools NanoGPT **brain** path.
clawhip (through gjc-relay) is the Discord narration bus. Hermes participates only via two cron
jobs (through real-file wrappers).

Conventions used below: `STATE_DIR` = `~/.gjc-bot` (renamed from `~/.repo-bot` on
2026-07-07, together with the `GJC_BOT_*` → `GJC_BOT_*` env-prefix rename, so the on-disk
identifiers now match the component name), `GH_ROOT` = `~/github/engels74-bot/fleet`
(the **fleet clone root** — since the 2026-07-07 fleet/ move, all pipeline-owned working copies
live in this subfolder, keeping the root of `~/github/engels74-bot/` to the bot's own `gjc-*`
projects), `SCRIPTS_DIR` = `gjc-fleet`'s `pipeline/` subdir root, bot login = `engels74-bot`. The six
**monitored** application repos are fixed in the clawhip config
(`~/.clawhip/config.toml [[monitors.git.repos]]`):
`easyhdr`, `mover-status`, `obzorarr`, `otpravkarr`, `perevoditarr`, `zondarr`. The script-side lanes
(review-detector, merge-gate, stale-branches, issue-triage-fetch, janitor) instead **auto-discover**
by globbing `GH_ROOT` for any `.git` repo (excluding `review/` and `*.gajae-code-worktrees`,
`review/review-detector.sh:34`). Scaling model: *clone an app repo into `fleet/` and it's in the
fleet.* Because the glob is scoped to `fleet/`, the discovered set is exactly the 6 monitored apps —
the infra repos (**`gjc-fleet`** — the monorepo holding this pipeline, the relay, and these docs —
and `gjc-server-tool`) sit one level up, outside the glob (before the fleet/ move they were swept
accidentally; see Open questions).

## Pipeline at a glance

```
GitHub issue opened
  │ clawhip git monitor (60 s poll)                       [30-clawhip.md]
  ├──► per-repo Discord channel (human notice)
  └──► ~/.gjc-bot/issue-spool.jsonl (localfile sink)
            │ systemd: issue-spool-adapter.path (on modify) + .timer (5 min backup)
            ▼
  issue-spool-adapter.sh ── parse → dedup ledger → gh re-fetch → LLM triage (no tools)
            │ ACTIONABLE
            ▼
  gjc-run.sh launch ── flock precheck → worktree add → prompt file → setsid _exec
            ▼
  gjc-run.sh _exec ── holds gjc.lock; timeout 1800 gjc -p --no-pty "@prompt"
            │            gjc commits, pushes, opens PR (Fixes #n) as engels74-bot
            ▼
  PR open ──► augmentcode[bot] auto-reviews (external service)
            │
            ├─ review-detector.sh (5 min timer, zero LLM) ── suggestions found?
            │     │  routed by PR AUTHOR:
            │     ├─ bot-authored (engels74-bot) → EXISTING lane
            │     │     review-run.sh ── isolated checkout; engine_run (gjc default,
            │     │                      timeout 5400) applies suggestions, pushes, replies
            │     └─ automated-author (renovate/dependabot) → POLICY lane (B-2)
            │           first review → consume once (--suppress-trigger);
            │           later review → brain DECIDE: APPLY / DISMISS / ESCALATE
            │
            ├─ ci-fixer.sh (10 min timer, DEFAULT OFF) ── bot PR CI RED on HEAD?
            │     caps + backoff + per-repo lock → ci-fixer-run.sh (engine_run) fixes CI;
            │     caps exhausted → give up once → #gjc-approvals
            │
            ├─ automerge.sh (10 min timer, DEFAULT OFF, canary pending) ── automated-author PR,
            │     CI green + review policy settled? → synchronous OLDEST-FIRST squash-merge via
            │     gh pr merge --match-head-commit (per-repo lock; in-lock head + CI re-check);
            │     else defer. NONE/RED never merge; UNKNOWN/PENDING defer.
            │
            └─ merge-gate.sh (10 min timer, BOT-authored only) ── CI green? → LLM verdict (no tools)
                     → PR comment MERGE_READY / REQUEST_CHANGES + Discord embed
                     → a HUMAN merges  (automated-author PRs carved out → automerge lane owns them)

Cleanup lanes: gjc-worktree-janitor (2 min timer; + age-based coordinator tmux-reaper & log-prune) ·
               gjc-reap.sh (wired into the janitor's tmux sweep — no longer manual-only) ·
               stale-branches.sh (hermes cron, report-only) · issue-triage-fetch.sh (hermes cron, read-only)
Nightly:      fleet-update.sh (03:30 timer, DEFAULT OFF) ── quiesce → tool-update → hermes-update →
              release → verify.sh → one summary embed
```

## Script-by-script

### intake/issue-spool-adapter.sh

Trigger: `issue-spool-adapter.path` (PathModified on `~/.gjc-bot/issue-spool.jsonl`) plus a 5-min
backup timer. Holds a global exclusive `flock` on `issues.lock` for the whole pass
(`intake/issue-spool-adapter.sh:75`), then re-reads the **entire spool** each run (self-correcting
when path triggers coalesce). Per `github.issue-opened` line: parse the compact
`<owner/repo>#<n> opened: <title>` lead (`:85-89`), short-circuit on ledger `issues.jsonl`
terminal states (`dispatched|skipped`, `:94`), re-fetch via
`gh api repos/<repo>/issues/<n>` (skips PRs and non-open issues, `:96-101`), then **triage**: a
**no-tools** NanoGPT chat completion (`BRAIN_MODEL=minimax/minimax-m3`, `:35,65-72`) returning one
line `ACTIONABLE:…` or `SKIP:…`. On ACTIONABLE → `run/gjc-run.sh launch --repo <r> --issue <n>`
(`:109`); rc 0 → ledger `dispatched`, rc 75 → `queued` (busy — *not* ledgered, so it retries),
other → `skipped launch-error`. Every outcome posts an embed to `#gjc-events` via `discord_embed`.

Injection-safety is structural: untrusted issue text only ever reaches a no-tools LLM, never a
shell or a tool-bearing agent. Secrets `GITHUB_TOKEN` / `NANOGPT_API_KEY` are grepped from
`~/.hermes/.env` at runtime (`:45,47`). It reaches its siblings through the self-located
`SCRIPTS_DIR`: `GJC_RUN` defaults to `$SCRIPTS_DIR/run/gjc-run.sh` (`:33`) and it sources
`$SCRIPTS_DIR/lib/discord-embed.sh` (`:42`).

### run/gjc-run.sh

Three roles by `$1` (`run/gjc-run.sh:1-167`):

- **`launch`** (`:62-115`) — automated fire-and-forget entry: non-blocking `flock -n gjc.lock`
  precheck (rc 75 = busy/requeue, `:78-81`), inline janitor pass, read-only `gh issue view`,
  branch slug `issue-<n>-<slug>`, then a **unique per-run worktree**
  `git worktree add --force -B <branch> <repo>.gajae-code-worktrees/run-<stamp> origin/<default>`
  where `<stamp>` = `<date>-<pid>` (`:93-98`), a deterministic prompt file in STATE_DIR instructing
  a minimal fix + commit + push + PR (`## Summary` / `Fixes #n` / `## Validation` / bot footer,
  `:102-110`), and `setsid $SELF _exec …` to detach (`:113`).
- **`_exec`** (`:118-140`) — the background run: reopens `gjc.lock` on fd 9 and holds it for the
  whole lifetime (single-flight that dies with the process), narrates
  `clawhip agent started`, runs `( cd $wt && timeout 1800 gjc -p --no-pty "@$pf" )` (`:130`,
  `GJC_RUN_TIMEOUT` default 1800), narrates `finished`/`failed` by exit code, then unconditionally
  `git worktree remove --force` + `prune` + rm prompt (`:135-137`).
- **`wrapper`** (`:143-151`) — a HELD interactive in-tmux lane (coordinator rewire), currently
  unused by design (see Open questions).

It exports a complete `PATH` prepending `~/.bun/bin` (gjc) and `~/.cargo/bin` (clawhip) because
systemd's PATH omits them (`:45`); binaries are pinned absolute:
`GJC_REAL=/home/cvps/.bun/bin/gjc`, `CLAWHIP=/home/cvps/.cargo/bin/clawhip`,
`GH=/home/linuxbrew/.linuxbrew/bin/gh`, `JANITOR=$SCRIPTS_DIR/maintenance/gjc-worktree-janitor.sh`
(`:32-38`). `narrate()` wraps `clawhip agent <state>` and force-injects `--error` for `failed`
(`:49-58`) — the CLI requires it, else failures were silently swallowed (bug fixed in the discord
wave).

### review/review-detector.sh

Timer every 5 min, **zero LLM** (`review/review-detector.sh:1-221`). Lists every open PR per repo
and **routes by PR author** (`main`, `:204-217`): the bot login (`engels74-bot`) → the **existing
lane**; a login in `REVIEW_AUTOMATED_AUTHORS` (default `renovate[bot] dependabot[bot]`) → the **B-2
policy lane**; any other (human) author → untouched.

- **Existing lane** (`existing_lane`, `:90-116`) — behaviour unchanged from Phase G5. Fetch the
  *last* `augmentcode[bot]` review (`:92-93`); record `repo#pr#reviewid` in `reviews.jsonl` on
  **every** poll (`:101` — so a "No suggestions" review can never re-launch later); launch only when
  the body matches `[0-9]+ suggestion` and NOT `no suggestions at this time` (`:102`). If
  `review.lock` is free → `review-run.sh --repo --pr --review <id>` (`:107-109`); if held, a handler
  is already active, so just mark seen. `RUNNER` defaults to `$SCRIPTS_DIR/review/review-run.sh`
  (`:38`).
- **Policy lane** (`policy_lane`, `:190-202`) — the one-review policy for automated-author PRs.
  First suggestion-carrying review → `policy_first_consume` (consume once, launch with
  `--suppress-trigger`); a later review on an already-consumed PR → `policy_decide_path` (brain
  verdict via `review-policy-decide.sh`). Both obey the **deferred-mark invariant** under the
  per-repo `review-<repo>.lock`. Full state machine in
  [One-review policy](#one-review-policy-automated-author-prs) below.

### review/review-run.sh

Launcher for the **AI Code Review Handler** — a headless coding-engine run (`review/review-run.sh:1-127`).
`launcher` (`:74-104`): non-blocking `review.lock` precheck (rc 75), `ensure_checkout` maintains an
**isolated** per-repo clone at `~/github/engels74-bot/fleet/review/<repo>` (own `.git`, never contends
with the gjc lane, `:61-72` — the canonical copy is now factored into
[`review/review-checkout.sh`](#reviewreview-checkoutsh)), `sed`-fills the Config block of the handler
template (REPO/PR_ID/REVIEW_ID/CODING_GUIDELINES/MODEL_PRIMARY=opus/MODEL_FAST=sonnet/NOTIFY_CHANNEL/
SUPPRESS_TRIGGER, `:92-100`; `CODING_GUIDELINES` defaults to `AGENTS.md`, `:34`), then `setsid _handler`.
The template path is `HANDLER_TEMPLATE=$SCRIPTS_DIR/review/ai-code-review-handler-original.md` (`:22`).
`_handler` (`:106-121`) holds `review.lock` on fd 9, narrates via clawhip, and runs the handler through
`engine_run "$REVIEW_ENGINE" "$filled" "$RUN_TIMEOUT"` (`:114`, `RUN_TIMEOUT` default 5400) — the shared
[`lib/engine.sh`](#shared-lib) dispatch: `REVIEW_ENGINE` defaults to **gjc** (`gjc -p --no-pty "@prompt"`,
inheriting gjc's own backend/models), with `claude` as the legacy headless fallback (`claude -p
--dangerously-skip-permissions --model "$MODEL_PRIMARY"`, MODEL_PRIMARY read only on that path). It
narrates by exit code (124 = timeout). The handler applies augmentcode's suggestions, pushes, and
replies on the PR as the bot; `--suppress-trigger` (from the B-2 policy lane) sets `SUPPRESS_TRIGGER=1`
so Phase 7 withholds the `augment review` re-trigger and records `Trigger: withheld (policy)`.

The template this script fills briefly went **missing on disk** on 2026-07-06 and has since been
restored as an architecture-native rewrite (see [Discrepancies #1](#discrepancies)); it was
live-verified with two clean handler runs on 2026-07-07.

### review/merge-gate.sh

Timer every 10 min; **advisory and comment-only** — never a formal GitHub review (self-review
422s), never an auto-merge (`review/merge-gate.sh:1-103`). Per open bot PR: compute CI state on the
HEAD sha via `ci_state` → GREEN/RED/PENDING/NONE (`:72`, now the shared
[`lib/gh-ci.sh`](#shared-lib) classifier — the same single-source-of-truth `ci-fixer` uses); only on
GREEN and not already gated for that sha (ledger `merge-gate.jsonl`, `:51-52,71,78`); take a
non-blocking `review.lock` so it never runs while a review handler is mutating the PR (`:74`); then a
**no-tools** NanoGPT review of the truncated diff → `MERGE_READY:` / `REQUEST_CHANGES:`
(inconclusive coerced to REQUEST_CHANGES, `:55-63,77`). Composes the PR comment via the house-style
[`lib/github-md.sh`](#shared-lib) helpers (`gmd_h3`/`gmd_footer`, `:87-92`) and posts it + a
`merge-gate.advisory` embed to `#gjc-approvals` (`:93-97`). Humans do the actual merge. (Note:
merge-gate does not define `SCRIPTS_DIR`; it sources `lib/discord-embed.sh`, `lib/gh-ci.sh`, and
`lib/github-md.sh` via an inline `cd "$(dirname)/.." && pwd` resolve, `:28-34`.)

### maintenance/gjc-worktree-janitor.sh

Crash-net for orphaned launch worktrees (`maintenance/gjc-worktree-janitor.sh:1-316`); timer every
2 min, plus called inline by `gjc-run.sh launch` and `gjc-reap.sh`. Takes `gjc.lock` for the whole
pass (`main`, `:270-277`) — if a live run holds it, the janitor skips entirely (closes the timer
race). Builds an occupancy set from `/proc/<pid>/cwd` scans + `tmux list-panes` (`occupied_paths`,
`:79-88`). Removes a worktree only when **all** hold: under `<repo>.gajae-code-worktrees/*`; on a
branch (detached-HEAD `main-<hash>` worktrees are left for gjc's interactive lane to reuse); no live
occupant; mtime age ≥ `GRACE_SECONDS=600` (`evaluate_worktree`, `:106-143`). `DRY_RUN=1` supported.
Live log confirms correct skip-detached-HEAD behavior.

**Coordinator tmux reaper (Workstream I).** BEFORE the worktree pass, `reap_tmux_sessions`
(`:220-237`) runs an age-based sweep of `gjc-coordinator-*` tmux sessions. For each,
`consider_tmux_session` (`:172-218`) reaps it **iff** its coordinator-mcp state file has
`state ∈ {completed,stale}` AND `live == false` AND `updated_at` older than `JANITOR_TMUX_GRACE_SECONDS`
(`[janitor].tmux_grace_mins`, default 30 min); a session with NO state file is reaped only past a
~24h fallback (`JANITOR_TMUX_NOSTATE_SECONDS`). **Schema-guard fail-safe:** any missing/null/
unparseable `state`/`live`/`updated_at` field, or an unreadable state file, SKIPs (`:196-199`) — a
future hermes schema change defers rather than mis-reaps. The reap itself calls `gjc-reap.sh` with
`JANITOR_BIN=/bin/true` (`do_tmux_reap`, `:158-167`) so its closing janitor pass does not recurse.
Gated on `[janitor].tmux_reap_enabled` (rendered `JANITOR_TMUX_REAP_ENABLED`, **default OFF** — fully
inert unless `=1`) + `DRY_RUN`. This is what **wires** the formerly-standalone `gjc-reap.sh` into a
trigger (resolving the old "reaper is unwired" question).

**Log-prune (K3).** After the worktree pass, `prune_logs` (`:239-268`) deletes per-run engine logs
under `~/.gjc-bot/logs/*-pr*-*.log` older than `JANITOR_LOG_RETENTION_DAYS` (default 14) and size-caps
the shared lane logs (`review.log`/`ci-fixer.log`/`merge-gate.log`) to the last
`JANITOR_LANE_LOG_KEEP_LINES` lines once they pass `JANITOR_LANE_LOG_MAX_BYTES` (default 10 MiB),
truncating in place so live appenders keep their inode. Conservative + non-fatal.

### run/gjc-reap.sh

Kills a hung gjc tmux session's **entire pane process tree** (PID-based BFS via `pgrep -P`, never
pattern matching), leaf-first TERM → `tmux kill-session` → KILL. Rationale: killing only the tmux
session orphans the in-session wrapper holding `gjc.lock`; killing the tree closes the held fd and
releases the lock. Ends with a janitor pass
(`JANITOR=$SCRIPTS_DIR/maintenance/gjc-worktree-janitor.sh`). **Now wired** into
`gjc-worktree-janitor.sh`'s age-based coordinator tmux sweep (Workstream I — see
[maintenance/gjc-worktree-janitor.sh](#maintenancegjc-worktree-janitorsh)); still usable
manually, and still the second stop (paired with `_exec`'s own `timeout`) for a hung run. The janitor
re-invokes it with `JANITOR_BIN=/bin/true` so the closing janitor pass does not recurse.

### intake/issue-triage-fetch.sh / maintenance/stale-branches.sh

Both are read-only report generators invoked by **hermes cron** through **real-file wrappers** in
`~/.hermes/scripts/` (hermes rejects symlinks for `--script`, so each wrapper is a genuine file that
`exec`s the real script; see [20-hermes-agent.md](20-hermes-agent.md#the-cron-subsystem) and
[Self-locating scripts](#self-locating-scripts)):
`intake/issue-triage-fetch.sh` emits a JSON array of the week's open issues across all discovered
repos (`:21-31`, Mon 09:00, fed to a no-tools LLM digest → `#gjc-events`);
`maintenance/stale-branches.sh` reports remote branches merged to the default branch whose tip is
≥14 days old (`:33-44`, daily 03:00 → `#gjc-approvals`) — it **never deletes**, and prints nothing
when clean so the cron stays silent.

### review/review-policy-decide.sh

The **zero-checkout decision step** of the B-2 one-review policy (`review/review-policy-decide.sh:1-152`),
called by the detector for a *later* review on an already-consumed automated-author PR. Feeds the
**brain** (`brain_decide`, `:64-80`) the review body + comments + a head-capped PR diff strictly as
DATA and returns exactly one stdout line — `APPLY:` / `DISMISS:` / `ESCALATE:` (anything
non-conforming or empty falls through to ESCALATE, fail-to-human, `:76-79`). `APPLY` → the detector
relaunches the handler (bounded); `DISMISS` → a visible house-style audit comment, reviewer threads
left untouched (`post_dismiss`, `:84-95`); `ESCALATE` → a needs-human PR comment + a de-duplicated
`review-policy` embed to `#gjc-approvals`, dedup on the `#escalated` ledger key so a PR escalates at
most once (`post_escalate`, `:99-121`). Reuses the already-rendered approvals channel
(`REVIEW_POLICY_CHANNEL` → `MERGE_GATE_CHANNEL`, `:39`); `decision_mode` is `brain` (`:35`). No git
checkout, no repo mutation beyond the one PR comment.

### review/ci-fixer.sh

The **fix-until-green poller** — bounded and guard-railed, **DEFAULT OFF** (`review/ci-fixer.sh:1-269`).
Timer every 10 min; K5 self single-flight on `ci-fixer-poll.lock` (`:252`). Three kill switches gate
every run (`gate_open`, `:117-121`; see [Fix-until-green](#fix-until-green-ci-fixer)). **Author scope
is `CI_FIXER_AUTHORS`** (`is_ci_fixer_author`, `:103-113`, applied at `:259`): the poller lists ALL open
PRs and gates on membership in that list — default `engels74-bot renovate[bot] dependabot[bot]`
(rendered from `[ci_fixer].authors`) — replacing the old hard "bot-authored only" `--author "$BOT"`
filter. The old restriction existed because upstream bots force-push over fleet commits; Workstream C
(`rebaseWhen:conflicted`) + D (containment re-arm) now make automated-author PRs safe, so they are back
in scope by default (a lone `-` sentinel = empty set = touches no one). Per PR on its HEAD sha,
`consider_pr` (`:199-245`) classifies via the shared `ci_state`: GREEN/PENDING/NONE → skip;
**UNKNOWN → defer** (gh API failure, never a fix attempt); RED → check caps (`max_per_sha=2`,
`max_per_pr=5`, `:220`), exponential backoff (`backoff_base_mins * 2^attempts`, `:182-194,226`), a
non-blocking `review-<repo>.lock` pre-check that ALSO count-then-marks both `#try` keys atomically
IN-lock (K4, `:214-238`), then `launch_fix` fires `ci-fixer-run.sh` (`:162-178`). Caps exhausted →
`give_up` posts a needs-human comment + a loud `ci-fix.escalation` embed to `#gjc-approvals`, **once**,
dedup on `#gaveup` (`:133-155`).

### review/ci-fixer-run.sh

Fire-and-forget launcher for **one** bounded CI-fix run (`review/ci-fixer-run.sh:1-159`), cloned from
`review-run.sh`'s launcher + `setsid _handler` structure with two disclosed B-3 differences.
`launcher` (`:72-100`) `ensure_checkout`s the isolated per-repo review clone, `sed`-fills the
`ci-fix-handler.md` Config block (REPO/PR_ID/HEAD_SHA/CI_FIX_ATTEMPT/CODING_GUIDELINES/models,
`:89-96`), then `setsid _handler`. `_handler` (`:102-153`) runs the handler through
`engine_run "$REVIEW_ENGINE" …` (`:127`, `RUN_TIMEOUT` default 3600) and derives the **outcome in the
shell** from a `git ls-remote refs/pull/<pr>/head` snapshot before/after the run
(`pr_head_sha`, `:67-70`) → `stale` (branch already moved before start), `fixed` (sha advanced),
`unchanged`, or `timeout` (rc 124) (`:117-138`) — the engine only commits/pushes, the shell owns the
truth. The `#outcome:*` ledger record + a `ci-fix` result embed follow. **Difference #1** (the
per-repo BLOCKING lock) is detailed in [Fix-until-green](#fix-until-green-ci-fixer).

### review/ci-fix-handler.md

The template `ci-fixer-run.sh` fills and hands to the coding engine (`review/ci-fix-handler.md`).
**One-shot per attempt**: Phase 0 asserts HEAD still equals `HEAD_SHA` or bails `RESULT: STALE`;
Phases 1-3 read the failing CI signals, make the **minimal** fix, and push **exactly one** commit
(never `--amend`, never `--force`); Phase 4 emits one `ci-fix` embed + a `RESULT:` line. Invariants:
no monitor/retry loop in-context (the systemd timer + `ci-fixer.sh` are the loop), **no** `augment
review` and **no** PR/issue comments or thread mutations (the only GitHub artifact is the commit),
GitHub state beats memory, and **engine-neutral** (works identically under gjc or legacy claude).

### review/review-checkout.sh

Shared isolated-checkout helper (`review/review-checkout.sh:1-49`). Its `ensure_checkout` (`:37-48`) is
the **canonical copy** of the per-repo review-clone logic (extracted verbatim from `review-run.sh`):
guarantees an isolated clone under `$REVIEW_ROOT/<repo>` with its own `.git`, reset to the default
branch, and prints its path. Sourceable with no side effects (double-source guard `:15-16`; provides a
`log()` only if the caller has not, `:32-34`). Now sourced by **both** `ci-fixer-run.sh` and
`review-run.sh` (the latter dropped its inline copy — `review-run.sh:57`), so the two engine lanes
share one `ensure_checkout`. Both callers run it **under the per-repo `review-<repo>.lock`** (K1), never
at launch time, because it mutates the shared `fleet/review/<repo>` tree.

### review/review-shared.sh

Helpers shared by the review policy lane and the Workstream-D force-push re-arm path
(`review/review-shared.sh:1-72`; sourced, never executed). Single source of truth for three
GitHub-derived facts (emits no tokens/IDs/paths): `latest_suggestion_review` (`:31-39`, moved here
verbatim from `review-detector.sh` so the detector and the re-arm path classify "newest augmentcode[bot]
review carries suggestions" identically); `pr_head_sha` (`:44-47`, engine-neutral head via
`git ls-remote refs/pull/<pr>/head`); and `head_contains <full> <psha> <headsha>` (`:64-72`), the
force-push containment check via the GitHub compare API — `identical|ahead ⇒ 0` (contained, no re-arm),
`behind|diverged ⇒ 1` (force-pushed away, re-arm), empty/other `⇒ 2` (API failure, DEFER). Reused by
`review-detector.sh` (D re-arm) and `automerge.sh` (policy-settlement defer).

### review/automerge.sh

The **AUTOMERGE lane's poller** — timer-driven, guard-railed, **SYNCHRONOUS** and **DEFAULT OFF**
(`review/automerge.sh:1-406`). Unlike review/ci-fix, there is **no detached handler**: a merge happens
inline, inside the per-repo lock; the systemd timer + this poller are the loop, GitHub + the ledger are
the counters. K5 self single-flight on `automerge-poll.lock` (`main`, `:392`).

**Kill switches (ALL must allow, else exit 0 quietly):** `AUTOMERGE_ENABLED=1` (from
`[merge].automerge_enabled`, default 0/OFF) **AND** no `~/.gjc-bot/automerge.disable` marker **AND**
`DRY_RUN` unset **AND** repo not in `AUTOMERGE_EXCLUDE_REPOS` **AND** the PR has no `automerge-hold`
label (`gate_open` `:166-171`, per-repo/per-PR checks in the loop). Author scope is `AUTOMERGE_AUTHORS`
(default `renovate[bot] dependabot[bot]`; `-` sentinel = empty set).

**G-F1 capability guard (fail-closed).** Before ANY merge this pass, `capability_ok_or_escalate`
(`:176-186`) **feature-probes `gh pr merge --help`** for the literal `--match-head-commit` (a behaviour
probe, not a version-string compare). If absent → fail-closed: emit exactly ONE `automerge.escalation`
embed (deduped per host-hour), refuse ALL merges this pass, NEVER call `gh pr merge`, record no `#try`.

**Eligibility (per open automated-author PR, OLDEST-FIRST, ≤`AUTOMERGE_MAX_PER_POLL` merges/repo/poll —
default 1, `:78,377-382`).** `consider_pr` (`:309-361`) gates on: terminal ledger short-circuits
(`#merged:<sha>`, `#blocked`); attempt cap `#try` < `AUTOMERGE_MAX_ATTEMPTS` (default 3) else loud
`give_up` once; no `automerge-hold`; not draft; `mergeable==MERGEABLE`; `reviewDecision !=
CHANGES_REQUESTED`; `ci_state(HEAD)==GREEN` (NONE/RED never merge, **UNKNOWN/PENDING defer** — no `#try`);
HEAD-commit quiet period ≥ `AUTOMERGE_MIN_HEAD_AGE_MINS` (default 10); and **review policy SETTLED**
(`policy_settled` `:243-263`, automated authors only) — reads the review-policy ledger: `#escalated` ⇒
terminal block; a `#policy-pushed:<sha>` not contained by the current head ⇒ defer (D re-arm owns the
fix); a suggestion review not yet `#consumed` ⇒ defer; no suggestion review yet ⇒ settle only after
`AUTOMERGE_REVIEW_WAIT_MINS` (default 30) from head age.

**Merge critical section** (`attempt_merge` `:271-304`, entirely inside the locks): take
`review-<repo>.lock` **non-blocking** + a non-blocking PROBE of the global `review.lock` (either busy ⇒
defer 75). IN-lock, in order: idempotent `state==MERGED` check (record `#merged`, no attempt);
**re-fetch HEAD sha** (moved ⇒ stale, defer, no real attempt); **re-check `ci_state`** (must still be
GREEN); `ledger_mark #try` **before** the merge (so a head-mismatch reject still burns the attempt); then
`gh pr merge <pr> --squash --match-head-commit <sha> --delete-branch=false`. Success ⇒ `#merged:<sha>` +
an `automerge` embed to `#gjc-approvals`. Server-side `--match-head-commit` is the race guard: a
force-push between the CI check and the merge is REJECTED by GitHub. `AUTOMERGE_METHOD` is validated to
`squash|merge|rebase` (never an injected flag). **`automerge_enabled` is still `false`** on the live host
— committed and wired, but canary-pending.

### maintenance/fleet-update.sh

The **nightly fleet-update orchestrator** (`maintenance/fleet-update.sh:1-182`; `systemd/fleet-update.
{service,timer}`, ~03:30, **DEFAULT OFF**). Kill switches: `TOOL_UPDATE_ENABLED=1` (from
`[updates].tool_update_enabled`, default 0/OFF) **AND** no `~/.gjc-bot/fleet-update.disable` marker
**AND** `DRY_RUN` unset (`gate` `:63-71`; `DRY_RUN=1` ⇒ `plan_only`, log intents, mutate nothing).

**Quiesce → update → verify** (`main` `:148-178`). `quiesce` (`:100-118`) takes the global `gjc.lock`
AND `review.lock` **blocking-with-timeout** (`flock -w`, held via exec'd fds) then waits for zero live
coordinator-mcp sessions (`count_live_coord` `:76-84`, **fail-safe:** a missing/unparseable `live`
field counts as LIVE so it defers rather than proceeds over an active run); any timeout ⇒ `defer`
(notice embed, exit 0 — never force) within `QUIESCE_TIMEOUT_MINS` (default 45). With both locks held:
run `tool-update.sh`, then `hermes-update.sh --apply` (gateway restarted LAST), release the locks, run
`bootstrap/verify.sh`, and emit ONE `fleet-update` summary embed with a per-job ok/fail table.

### maintenance/tool-update.sh

Headless port of the interactive `update-ai` manifest (`maintenance/tool-update.sh:1-123`; the
non-interactive twin of the `~/.zshrc` `update-ai` function). Enumerates the full manifest — `uv`,
`prek`, `bun upgrade`, bun globals, `bun update -g --latest`, skills, `ruff`; `brew_update`/
`brew_upgrade` guarded on `command -v brew`; the macOS `agy` job guard-skipped on Linux (`:102-120`).
Each `job` (`:65-79`) guards on tool existence, logs to a per-run log under `~/.gjc-bot/logs/`, records
`name<TAB>status` to a TSV for fleet-update's summary, and retries ~3× with exponential backoff on
rate-limit/network patterns (`_ua_exec` `:49-62`). **PIN RE-ASSERTION (critical):** because
`bun update -g --latest` bumps gajae-code/clawhip PAST the fleet pins, `reassert_pins` re-runs
`bootstrap/10-engines.sh` in a `trap ... EXIT INT TERM HUP` (`:84-98`) — so ANY exit path (success,
mid-manifest failure, signalled abort) restores the pins and can never strand gajae unpinned.

### maintenance/hermes-update.sh

Track-latest hermes-agent updater (`maintenance/hermes-update.sh:1-167`; `--check` report-only /
`--apply`). Hermes is not ref-pinned (bootstrap only reports drift) — this wrapper owns rollback.
`run_apply` (`:92-153`): `hermes update --check` gate (exit 0 if already current); abort if the
checkout tree is dirty (escalation embed); record prev-ref (`git rev-parse HEAD`) to
`~/.gjc-bot/state/hermes-prev-ref`; `hermes update --yes`; restart `hermes-gateway.service`; health-gate
(`is-active` AND `hermes_cli.main gateway status`, `health_ok` `:58-61`). On any failure → `rollback`
(`:65-80`): checkout prev-ref + `pip install -e` + restart + re-health-check + a `hermes-update`
escalation embed; on success → record deployed-ref + a `hermes-update` info embed. `bootstrap/10-engines.sh`'s
stub delegates here.

## LLM-invocation lanes: engine vs brain

The pipeline runs LLMs on **two distinct lanes**, and the split is a safety boundary, not an accident:

- **ENGINE lane** — coding-work invocations that read a repo, edit files, and push. These run via
  `lib/engine.sh` `engine_run`, dispatching on `[review].engine` (rendered to `REVIEW_ENGINE`):
  default **gjc** (`gjc -p --no-pty "@prompt"`, inheriting gjc's own backend/models), or the legacy
  headless **claude** (`claude -p --model "$MODEL_PRIMARY"`).
- **BRAIN lane** — **no-tools** VERDICT invocations that only read text and emit one classifier line.
  These stay on the NanoGPT `BRAIN_MODEL` path (default `minimax/minimax-m3`) and never touch a shell
  or a tool-bearing agent — the injection-safety boundary for untrusted issue/PR text.

| LLM invocation | Script | Lane | Backend |
|---|---|---|---|
| Issue triage (ACTIONABLE/SKIP) | `intake/issue-spool-adapter.sh` | **BRAIN** | NanoGPT no-tools |
| Merge-gate verdict (MERGE_READY/REQUEST_CHANGES) | `review/merge-gate.sh` | **BRAIN** | NanoGPT no-tools |
| Review-policy decision (APPLY/DISMISS/ESCALATE) | `review/review-policy-decide.sh` | **BRAIN** | NanoGPT no-tools |
| AI Code Review Handler (applies suggestions) | `review/review-run.sh` → `ai-code-review-handler-original.md` | **ENGINE** | `[review].engine` (gjc default) |
| CI-Fix Handler (fixes RED CI) | `review/ci-fixer-run.sh` | **ENGINE** | `[review].engine` (gjc default) |

**The CI-fix lane SHARES `REVIEW_ENGINE`** — it deliberately reads the *same* `[review].engine` knob,
so the fleet makes **one** engine cutover decision for both coding lanes rather than two.

**Cutover complete (live).** `REVIEW_ENGINE=gjc` is live and active on the review lane, validated via
the live review workflow. Recorded evidence: **mover-status#26** — gjc opened the PR, augmentcode posted
1 suggestion, the handler addressed it with a fix commit (`fix: address code review comments (PR #26,
iteration 1)`), and the re-review converged clean (2 handler runs, both `engine=gjc … _handler OK`); gjc
also produced augmentcode-approved (no-suggestion) PRs on **easyhdr#118** + **zondarr#189** that the
detector correctly no-op'd. Verified live alongside: **K1** (both the per-repo `review-<repo>.lock` and
the global `review.lock` held across the run), **K5** single-flight, a `gjc -p --no-pty` de-risk probe,
and `gjc-reap.sh` reaping 3 stale coordinator orphans. The strict pre-cutover rubric (≥3 handler runs
across ≥2 repos incl a failing-CI case) is superseded: gjc's clean easyhdr/zondarr PRs ran no handler
(a positive signal), and the engine is validated on the harder address-suggestions→fix→converge path.
The legacy `claude` engine stays selectable per host (`engine = "claude"` in `fleet.toml`)
as a deploy decision, never a code change. Nuance: `[review].model_primary`/`model_fast` (rendered
`MODEL_PRIMARY`/`MODEL_FAST`) apply ONLY to the `claude` engine path — under `engine=gjc` they are inert
because gjc inherits its own Codex backend (the live host keeps `opus`/`sonnet`, harmless under gjc).

## One-review policy (automated-author PRs)

The B-2 policy lane bounds how the fleet reacts to automated dependency-update PRs (renovate/
dependabot) so their endless review churn can't drive an unbounded handler loop. **Author routing**
(in `review-detector.sh`): `engels74-bot` → the existing lane (unchanged); a login in
`REVIEW_AUTOMATED_AUTHORS` → this policy lane; humans → untouched.

**State machine** (per automated-author PR, keyed on the latest suggestion-carrying `augmentcode[bot]`
review):

1. **NEW review + suggestions**, `#consumed == 0` → **FIRST-CONSUME**: mark `#consumed` (under lock),
   launch the handler **once** with `--suppress-trigger`.
2. **Later review** on an already-consumed PR → **DECIDE** (brain, `review-policy-decide.sh`):
   - **APPLY** → relaunch the handler **iff** `#consumed < max_handler_runs` (default 2); at the cap,
     record the decision only.
   - **DISMISS** → post a visible house-style audit comment; **reviewer threads left untouched**.
   - **ESCALATE** → `needs-human` PR comment + a `review-policy` embed to `#gjc-approvals` (and the
     `#escalated` ledger dedup); inconclusive/parse-fail verdicts fail *toward* ESCALATE.

**Deferred-mark invariant (HARD).** The `#consumed` marker is written under the per-repo
`review-<repo>.lock` — a lock **distinct from** the handler's global `review.lock` — *after* an in-lock
re-check of the review-id and *before* the lock is released, never "whenever a launch happens". If
`review-<repo>.lock` is busy the poller logs `deferred (lock busy)` and retries next poll (no mark).
Combined, this guarantees **exactly-one** consumption even with overlapping poll cycles, without a
serialising poller ever blocking a running handler (they take different locks). Proven offline by
`tests/policy-deferred-mark.test.sh`.

**`--suppress-trigger`.** So a consumed automated-author review isn't re-triggered into a loop, the
launcher sets `SUPPRESS_TRIGGER=1`; the handler's Phase 7 then withholds the `augment review`
re-trigger and records `Trigger: withheld (policy)`.

## Force-push resilience — policy re-arm (Workstream D)

Renovate/dependabot force-push their PR branches, so a policy-lane review (or ci-fix commit) the fleet
already acted on can be rebased away — the handler's fix would silently vanish while the policy lane, seeing
no new review, would never re-run. Workstream D closes that with a **containment-based re-arm**, all in
`review-detector.sh` (`policy_rearm_check`/`policy_rearm_launch`, `:229-282`) + the review handler.

**Snapshot + arm.** `review-run.sh`'s `_handler` (policy-lane runs, `suppress=1` only) snapshots the PR
head via `pr_head_sha` before/after `engine_run`; if the run advanced the head it records
`#policy-pushed:<after-sha>` in the review-policy ledger (`review-run.sh:138-151`).

**Detect + re-arm.** Each poll, `policy_rearm_check` reads the newest `#policy-pushed:<sha>` for the PR
and compares it to the current head via `review-shared.sh` `head_contains()` (GitHub compare API):
`identical`/`ahead` ⇒ contained ⇒ **no re-arm** (a normal CI/renovate commit ON TOP keeps the sha an
ancestor); `behind`/`diverged` ⇒ the sha was force-push-rebased away ⇒ **re-arm** (relaunch the handler
for the SAME review-id against the new head, `--suppress-trigger`); empty/API-failure ⇒ **DEFER** (never
guess). Re-arms are deduped per head lineage on a `#rearm:<head>` ledger key, capped by
`REVIEW_POLICY_MAX_REARMS` (default 2), and on the cap it **escalates once** (a `#rearm-exhausted` dedup
marker + a loud log line, `:273-278`). The re-arm launch obeys the same deferred-mark discipline under
`review-<repo>.lock` (in-lock dedup + cap re-check before release). `head_contains` is reused by
`automerge.sh` as its policy-settlement defer condition, so both lanes agree on containment.

## Fix-until-green (ci-fixer)

The B-3 lane makes a bounded, guard-railed attempt to turn a bot PR's RED CI green — **default OFF**,
and engineered so it can never livelock or spend unboundedly.

**Three kill switches (ALL THREE must allow a run):** `CI_FIXER_ENABLED=1` (from `[ci_fixer].enabled`,
default 0/OFF) **AND** no `~/.gjc-bot/ci-fixer.disable` marker file on the host **AND** `DRY_RUN` unset/0
(`DRY_RUN=1` logs intended actions, takes none). Disabled or marker present → exit 0 quietly, zero
records.

**Scope: membership in `CI_FIXER_AUTHORS`** (rendered from `[ci_fixer].authors`; default
`engels74-bot renovate[bot] dependabot[bot]`, a lone `-` = empty set). The poller lists ALL open PRs and
gates on author membership — replacing the old hard "bot-authored only" filter. Automated-author
(renovate/dependabot) PRs used to be excluded because upstream bots force-push over fleet commits and
would clobber a fix; that risk is now mitigated by Workstream C (`rebaseWhen:conflicted`) + D
(containment/re-arm), so they are back in scope by default. Human PRs outside the list are still never
touched. **CI-fixer stays default-OFF regardless** (the `CI_FIXER_ENABLED` kill switch).

**Per in-scope PR, on its HEAD sha:** `ci_state` GREEN/PENDING/NONE → skip; **UNKNOWN → defer** (gh API
failure, never a fix attempt); RED → if the PR already gave up → skip; else evaluate **caps**
(`max_per_sha=2`, `max_per_pr=5`) and **exponential backoff**
(`backoff_base_mins * 2^attempts_this_pr` minutes = 10/20/40/80…). Caps hit → **terminal give-up
ONCE** (needs-human comment + `ci-fix.escalation` embed, dedup `#gaveup`). Otherwise a non-blocking
`review-<repo>.lock` pre-check → record the attempt (both `#try` ledger keys) + launch one bounded run.

**Per-repo lock rule + DISCLOSED blocking change.** `ci-fixer-run.sh`'s `_handler` takes the per-repo
`review-<repo>.lock` **BLOCKING** (`flock 9`, no `-n`), *unlike* `review-run.sh`'s `_handler`, which
takes the **global** `review.lock` **NON-blocking** (`flock -n 9`) and aborts if busy. The rationale:
a same-repo queued fixer should **wait its turn** rather than drop an attempt the poller already
recorded; different repos still run fully in parallel (the lock is per-repo, not global).

**Outcome-truth-in-shell.** The wrapper snapshots the PR head via `git ls-remote refs/pull/<pr>/head`
before and after the engine run and classifies **`fixed` | `unchanged` | `stale` | `timeout`** itself
— the LLM only commits/pushes; it does not own whether CI advanced. Proven offline (caps, backoff,
give-up dedup, green/pending no-op, lock-busy defer) by `tests/ci-fixer-caps-backoff.test.sh`; the
live termination proofs are a deploy-phase gate.

## Combined review ⊗ ci-fix state machine

For an open bot PR the two mutating lanes interleave: **PR open → {review rounds ⊗ ci-fix rounds on
RED} → green + review-exhausted → merge-gate advisory → a human merges.** A terminal non-green PR is
either a ci-fixer **give-up** or a policy **ESCALATE** — both page a human exactly once.

**Livelock bounds** (why this is finite): the handler↔fixer interplay is capped per-PR
(`max_handler_runs`, `max_per_pr`/`max_per_sha`); the ci-fixer's own pushes deliberately do **not**
re-trigger `augment review` (the CI-fix handler never posts `augment review`), so a fix push can't
spawn a fresh review round; and every per-PR attempt counter is monotone, so cumulative spend per PR
is bounded ⇒ the whole interleaving terminates.

## Lock topology (Workstream K)

The concurrency model across the mutating + polling lanes, hardened by Workstream K:

- **Global `review.lock` — single-flight for the review handler.** `review-run.sh`'s `_handler` holds it
  **non-blocking** (`flock -n 9`) for the whole run and aborts if busy; `review-detector.sh` and
  `merge-gate.sh` take it non-blocking as a courtesy probe (defer while a handler is mutating a PR).
  `automerge.sh` also takes it non-blocking; `fleet-update.sh`'s quiesce, by contrast, acquires it
  **blocking-with-timeout** and *holds* it for the whole nightly update (deferring to the next night
  if the timeout elapses) — see [`maintenance/fleet-update.sh`](#maintenancefleet-updatesh).
- **Shared per-repo `review-<repo>.lock` (K1).** Serialises the shared `fleet/review/<repo>` checkout
  (the `git fetch` + `checkout -f` that `ensure_checkout` performs). `review-run.sh`'s `_handler` takes it
  **INSIDE** the global lock (order: global fd 9 → per-repo fd 8, `review-run.sh:130-132`); `ci-fixer-run.sh`
  takes **ONLY** the per-repo lock, **BLOCKING** (`ci-fixer-run.sh:110-111`). **Deadlock-free by
  construction:** ci-fixer never blocking-acquires the global while holding the per-repo lock, so the two
  lanes can never form a wait cycle. Different repos run fully in parallel. `automerge.sh`'s merge critical
  section and the policy/ci-fixer pollers take this same per-repo lock non-blocking.
- **K2 UNKNOWN-defer.** `lib/gh-ci.sh` `ci_state` returns a distinct **UNKNOWN** on gh API failure (after
  one retry); every caller (merge-gate, ci-fixer, automerge) treats UNKNOWN as **defer**, never as
  NONE/green — a transient 5xx can never be mistaken for "no CI".
- **K4 exact-ledger + atomic count-then-mark.** `lib/ledger.sh` `ledger_seen` uses an exact
  `jq select(.key==$k)` match (a substring can't spuriously hit), and the ci-fixer counts caps **and**
  marks both `#try` keys inside one hold of `review-<repo>.lock` so two overlapping polls can't both read
  "under cap" and double-launch. The policy lane's deferred-mark (`#consumed`/`#rearm:<sha>` written
  in-lock before release) is the same discipline.
- **K5 per-poller single-flight.** Every poll loop (`review-detector`, `ci-fixer`, `merge-gate`,
  `automerge`) opens a script-level `flock -n <name>-poll.lock` at entry and exits 0 on contention, so a
  timer firing mid-pass never runs two overlapping pollers.

**K7 — `review.backlog` signal.** After routing a repo's reviews, `review-detector.sh`'s
`review_backlog_check` (`:319-350`) computes the OLDEST UNHANDLED review age — a suggestion-carrying
augmentcode[bot] review that the fleet has recorded neither a SEEN marker (existing lane) nor a
`#consumed` marker (policy lane) for, aged from its `submitted_at`. Above `REVIEW_BACKLOG_ALERT_MINS`
(default 120) it emits ONE `review.backlog` design-system embed to `#gjc-approvals`, deduped to one alert
per repo per host-hour; silent under threshold. It mitigates the fleet-wide serial review single-flight
(per-repo review concurrency remains a documented follow-up, made safe by K1).

## Shared lib

`lib/discord-embed.sh` (`:1-62`) — the single Discord-embed emitter, sourced by
`intake/issue-spool-adapter.sh`, `review/review-detector.sh`, `review/merge-gate.sh`,
`review/review-policy-decide.sh`, `review/ci-fixer.sh`, `review/ci-fixer-run.sh`,
`review/automerge.sh`, `maintenance/fleet-update.sh`, and `maintenance/hermes-update.sh`. The
design-system kinds it now carries include `review-policy`, `ci-fix`, `ci-fix.escalation`, plus the
five kinds added this rebaseline (rendered in `relay/runtime/design-system.json`): `automerge`,
`automerge.escalation`, `hermes-update`, `fleet-update`, and `review.backlog`.

`lib/engine.sh` (`:1-63`) — the coding-engine dispatch. One entrypoint
`engine_run <gjc|claude> <filled_prompt_path> <timeout_secs>`: runs one coding-work invocation under a
hard `timeout` (124 on timeout, 64 for a bad arg/unknown engine), dispatching gjc (`gjc -p --no-pty
"@prompt"`) vs the legacy claude path (MODEL_PRIMARY read only there). Sourceable with no side effects;
shared by `review-run.sh` and `ci-fixer-run.sh` so neither hardcodes a CLI.

`lib/gh-ci.sh` (`:1-79`) — the shared CI-state classifier. `ci_state <repo> <sha>` →
GREEN/RED/PENDING/NONE/**UNKNOWN** from check-runs + commit statuses (single source of truth: sourced by
merge-gate, ci-fixer, and automerge so all three classify identically). **UNKNOWN (K2)** is returned on a
gh API failure after one retry — distinct from NONE (genuine no-CI) — and every caller treats it as
**defer**, never green. `ci_red_summary` is a human-readable failing-check list for `<details>` blocks.
Emits no tokens/IDs/paths.

`lib/ledger.sh` (`:1-62`) — the shared append-only JSONL ledger helpers (`ledger_seen` with **exact
`.key==$k` match, K4**, `ledger_mark`, `ledger_count`, `ledger_last_ts`) backing the policy/ci-fixer/
automerge dedup, caps, and backoff bookkeeping. **Per-file** locking (each ledger `<f>` serialises on its
own `<f>.lock`) so unrelated ledgers never contend. Keys carry a fixed trailing segment so a
startswith-count can't bleed across ids (pr 1 vs pr 12): `#try`/`#gaveup`/`#consumed`/`#outcome:*`
(ci-fix/policy), `#policy-pushed:<sha>`/`#rearm:<sha>`/`#rearm-exhausted`/`#decision:*` (D re-arm),
`#merged:<sha>`/`#blocked` (automerge).

`lib/github-md.sh` (`:1-72`) — GitHub-Flavored-Markdown composition helpers (`gmd_h3`, `gmd_fence`,
`gmd_details`, `gmd_footer`) for house-style PR comments/`<details>` blocks (see
[46-github-house-style.md](46-github-house-style.md)). Sanitiser hard-rule: the helpers only format the
exact caller text — they never read the environment, tokens, `$HOME`, or a state path — so no secret,
numeric id, or lock/spool path can leak by construction. Used by `merge-gate.sh`,
`review-policy-decide.sh`, and `ci-fixer.sh`.
`discord_embed --channel --kind [--repo --status --actor --branch --url] --message` builds a
`GJCEMBED1 <head slots> :: <free-form tail>` envelope and sends it via `clawhip send`, so gjc-relay
renders it against `~/.gjc-relay/design-system.json` — the same styling source the clawhip route
templates use ([35-gjc-relay.md](35-gjc-relay.md)). Protocol safety: head values are sanitized to
`[A-Za-z0-9._:/-]` (`_gjc_clean_head`, `:30`; URLs via `_gjc_clean_url`, `:33`) so a stray
space/quote can't corrupt the envelope; the head is assembled from those cleaned slots (`:54-59`)
and all free-form text stays in the post-`::` tail where the relay owns JSON construction (`:61`).

## Self-locating scripts

Every entry-point script resolves its own repo root instead of a hard-coded path (bug fix — the old
default pointed at the now-missing `~/scripts/repo-bot`, which broke `issue-spool-adapter` at runtime
because it could not source `lib/discord-embed.sh`). Note the fix predates, and survived unchanged
through, the later 2026-07-07 monorepo migration: `SCRIPTS_DIR` still resolves to `pipeline/` (one
level up from each stage dir), now inside `gjc-fleet` rather than a standalone `gjc-bot-scripts` repo:

```sh
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
```

i.e. it walks up one level from the script's own resolved location (each script lives one stage-dir
deep) to the repo root; `GJC_BOT_SCRIPTS` still overrides. Present in
`intake/issue-spool-adapter.sh:20`, `run/gjc-run.sh:26`, `run/gjc-reap.sh:18`,
`review/review-detector.sh:20`, `review/review-run.sh:14`. `review/merge-gate.sh` does not set
`SCRIPTS_DIR` but reaches `lib/` via the equivalent inline `cd "$(dirname)/.." && pwd` (`:28`).
Sibling references key off `SCRIPTS_DIR` (`GJC_RUN`, `JANITOR`, `RUNNER`, `HANDLER_TEMPLATE`).

**Hermes cron wrapper indirection.** Hermes rejects a symlink for `--script` (its `.resolve()` would
escape the `~/.hermes/scripts/` containment dir), so two **real-file** wrappers live there and simply
`exec` the real scripts in the repo:

- `~/.hermes/scripts/stale-branches.sh` → `exec .../gjc-fleet/pipeline/maintenance/stale-branches.sh "$@"`
- `~/.hermes/scripts/issue-triage-fetch.sh` → `exec .../gjc-fleet/pipeline/intake/issue-triage-fetch.sh "$@"`

Both previously `exec`'d the dead `~/scripts/repo-bot/...` paths and were broken; they now point at
the new stage-dirs (verified 2026-07-07).

## Scheduling map

| Unit / job | Type | Schedule / watch | Runs |
|---|---|---|---|
| `issue-spool-adapter.path` | systemd path | PathModified `~/.gjc-bot/issue-spool.jsonl` | intake/issue-spool-adapter.sh |
| `issue-spool-adapter.timer` | systemd timer | boot+5 min, every 5 min (backup) | intake/issue-spool-adapter.sh |
| `review-detector.timer` | systemd timer | boot+5 min, every 5 min | review/review-detector.sh |
| `merge-gate.timer` | systemd timer | boot+10 min, every 10 min | review/merge-gate.sh |
| `ci-fixer.timer` | systemd timer | boot+10 min, every 10 min | review/ci-fixer.sh (**inert while `CI_FIXER_ENABLED=0`**, the default) |
| `automerge.timer` | systemd timer | `*:0/10` (every 10 min) | review/automerge.sh (**inert while `AUTOMERGE_ENABLED=0`**, the default; canary pending) |
| `fleet-update.timer` | systemd timer | `*-*-* 03:30` (nightly) | maintenance/fleet-update.sh (**inert while `TOOL_UPDATE_ENABLED=0`**, the default) |
| `gjc-worktree-janitor.timer` | systemd timer | boot+2 min, every 2 min | maintenance/gjc-worktree-janitor.sh (+ tmux-reaper & log-prune) |
| `stale-branches-report` | hermes cron | `0 3 * * *` (no_agent) | `~/.hermes/scripts/stale-branches.sh` wrapper → maintenance/stale-branches.sh → `#gjc-approvals` |
| `mover-status-issue-triage` | hermes cron | `0 9 * * 1` (agent+prerun) | `~/.hermes/scripts/issue-triage-fetch.sh` wrapper → intake/issue-triage-fetch.sh → `#gjc-events` |
| `gjc-reap.sh` | janitor-wired | invoked by the janitor's tmux sweep (I; default OFF) + manual | run/gjc-reap.sh |

The gjc-bot `.service` units are **user-scope** (`~/.config/systemd/user/`, no `sudo`) and set
`ExecStart=` to the absolute stage-dir path under
`/home/cvps/github/engels74-bot/gjc-fleet/pipeline/<stage>/<script>.sh` (`ci-fixer.service` was added in
the B-3 wave, and `automerge.service` + `fleet-update.service` in this rebaseline — all `Nice=15`, all
shipped **inert** behind their default-OFF kill switches; the two new units are wired into
`bootstrap/50-units.sh` + `verify.sh`). Each also carries `EnvironmentFile=-%h/.gjc-bot/gjc-bot.env` —
the rendered, 0600 env file that supplies the per-lane Discord channel IDs (see
[Env & config surface](#env--config-surface)). Unit subtlety: `issue-spool-adapter.service`,
`review-detector.service`, and `ci-fixer.service` set **`KillMode=process`** — without it, systemd's
default control-group kill would reap the `setsid`-detached gjc/handler/fixer run when the oneshot parent
exits. **`automerge.service` deliberately does NOT** — the automerge poller merges **synchronously
inline** (no detached `_handler` to keep alive), so the default control-group kill is correct. The
janitor unit deliberately has no `PrivateTmp` (needs the user tmux socket in `/tmp`). All units are
rendered from `gjc-fleet/systemd/*` by `render/render.sh apply --units`.

> [inferred] The hermes cron also carries a third, self-scheduled agent job
> (`monitor-easyhdr-pr115-rustsec`, `every 60m`) that does **not** touch gjc-bot — it is a transient
> monitor, not part of this pipeline.

## Worktree & branch lifecycle

Two buckets under `<repo>.gajae-code-worktrees/`:

- **Automated lane:** unique `run-<stamp>-<pid>/` — created by `gjc-run.sh launch`, removed by
  `_exec` on completion; the janitor is the crash-net for runs that died uncleanly.
- **Interactive lane:** deterministic `main-<hash>/` (gjc's own coordinator worktree, left
  detached for reuse; the janitor explicitly skips it).

Nothing in this system deletes remote branches or merges PRs; `stale-branches.sh` only reports.
Historical context: the "worktree-hygiene jam" (deterministic worktree left on a branch →
`worktree_target_mismatch` relaunch loop) was the "critical recurring bug" flagged in the earlier
hermes-stack build-log (now retired), solved by
exactly this unique-worktree + janitor + reap design (see
[90-glossary-and-open-questions.md](90-glossary-and-open-questions.md)).

## Env & config surface

Everything is overridable by env; defaults in the scripts. Key names: `GJC_BOT_STATE`,
`GJC_BOT_SCRIPTS`, `GJC_BOT_GH_ROOT`, `GJC_BOT_GH_OWNER`, `GJC_BOT_LOGIN`, per-binary `*_BIN`
overrides, `GJC_RUN_TIMEOUT`, `REVIEW_RUN_TIMEOUT`, `JANITOR_GRACE_SECONDS`, `STALE_BRANCH_DAYS`,
`BRAIN_MODEL`, `NANOGPT_URL`, `REVIEW_MODEL_PRIMARY/FAST`, `HANDLER_TEMPLATE`, repo filters
(`MERGE_GATE_REPOS`/`REVIEW_REPOS`/`TRIAGE_REPOS`/`CI_FIXER_REPOS`), `*_CHANNEL` overrides, `DRY_RUN`.
The engine/policy/ci-fix/automerge/update waves add (all rendered from `fleet.toml` into `gjc-bot.env`
— see [45-fleet-config.md](45-fleet-config.md)): `REVIEW_ENGINE` (the ENGINE-lane engine, default gjc);
`REVIEW_AUTOMATED_AUTHORS`, `REVIEW_POLICY_MAX_HANDLER_RUNS`, `REVIEW_POLICY_DECISION_MODE`,
`REVIEW_POLICY_MAX_REARMS` (default 2 — the D re-arm cap) (one-review policy + re-arm);
`CI_FIXER_ENABLED` (default 0/OFF), `CI_FIXER_AUTHORS` (the E author-scope list), `CI_FIXER_MAX_PER_SHA`,
`CI_FIXER_MAX_PER_PR`, `CI_FIXER_BACKOFF_BASE_MINS`, `CI_FIX_RUN_TIMEOUT` (fix-until-green);
`REVIEW_BACKLOG_ALERT_MINS` (default 120 — the K7 signal); the automerge set `AUTOMERGE_ENABLED`
(default 0/OFF), `AUTOMERGE_AUTHORS`, `AUTOMERGE_METHOD`, `AUTOMERGE_MIN_HEAD_AGE_MINS`,
`AUTOMERGE_REVIEW_WAIT_MINS`, `AUTOMERGE_MAX_ATTEMPTS`, `AUTOMERGE_MAX_PER_POLL` (default 1),
`AUTOMERGE_EXCLUDE_REPOS`; the janitor set `JANITOR_TMUX_REAP_ENABLED` (default 0/OFF),
`JANITOR_TMUX_GRACE_SECONDS`, `JANITOR_LOG_RETENTION_DAYS`, `JANITOR_LANE_LOG_MAX_BYTES`; and the nightly
update set `TOOL_UPDATE_ENABLED` (default 0/OFF), `QUIESCE_TIMEOUT_MINS`. **Every new lane ships
default-OFF** — the committed code is live-from-repo but gated behind these switches.

Secrets (names only): `GITHUB_TOKEN` (exported as `GH_TOKEN`) and `NANOGPT_API_KEY`, both grepped
at runtime from `~/.hermes/.env`. **Discord channel IDs are no longer hard-coded in the scripts**
(changed 2026-07-07): the three numeric channel defaults that used to live in
`issue-spool-adapter.sh`, `merge-gate.sh`, and the review-handler template constant are **gone**
from the repo — each script now hard-fails at startup (`${ISSUE_NOTIFY_CHANNEL:?…}`,
`${MERGE_GATE_CHANNEL:?…}`, `${REVIEW_NOTIFY_CHANNEL:?…}`) unless the value arrives via
`EnvironmentFile=-%h/.gjc-bot/gjc-bot.env` — a rendered, 0600 file produced by `render/render.sh`
from `~/.config/gjc-fleet/fleet.toml`'s `[discord.channels]` map (`review-run.sh` additionally
`sed`-fills `NOTIFY_CHANNEL` into the handler prompt from `REVIEW_NOTIFY_CHANNEL`). This keeps
numeric Discord IDs out of the `gjc-fleet` git history entirely; the channels are still
`#gjc-events`, `#gjc-approvals`, `#gjc-lab` — see
[60-data-flow-and-integration.md](60-data-flow-and-integration.md#discord-topology) and
[45-fleet-config.md](45-fleet-config.md).

State in `~/.gjc-bot/`: locks (`gjc.lock`, `review.lock`, `issues.lock`, `merge-gate.lock`,
`reviews.lock`, the per-repo `review-<repo>.lock` shared by the review handler + policy lane + ci-fixer
+ automerge, the K5 per-poller `*-poll.lock` set — `review-detector-poll.lock`, `ci-fixer-poll.lock`,
`merge-gate-poll.lock`, `automerge-poll.lock` — and a per-ledger `<ledger>.lock` from `lib/ledger.sh`'s
per-file locking), ledgers (`issues.jsonl`, `reviews.jsonl`, `merge-gate.jsonl`, `review-policy.jsonl`,
`ci-fixer.jsonl`, `automerge.jsonl`), host kill markers (`ci-fixer.disable`, `automerge.disable`,
`fleet-update.disable` — all absent by default), the spool (`issue-spool.jsonl`), the
`state/hermes-prev-ref`/`state/hermes-deployed-ref` records, the per-run engine log dir
`logs/<lane>-<repo>-pr<NN>-<ts>.log`, the `.bak` archive dir `archive/`, and lane logs (`adapter.log`,
`gjc-run.log`, `review.log`, `merge-gate.log`, `ci-fixer.log`, `automerge.log`, `fleet-update.log`,
`janitor.log`).

## Discrepancies

1. **Missing handler template — RESOLVED 2026-07-06 (later the same day).** `review/review-run.sh:25`
   points at `$SCRIPTS_DIR/review/ai-code-review-handler-original.md` (present on disk today), which
   had gone missing
   despite a successful earlier run (`_handler OK mover-status#25`, 17:50). It was **recreated
   as an architecture-native rewrite**: one-shot per review (the detector timer is the outer
   loop; no in-prompt monitor/iteration loop), same-repo-only checkout, trigger-comment
   re-review (`augment review` — confirmed required from PR #25 history), battle-tested
   reply/react/resolve `gh`+GraphQL blocks retained, git-log iteration counter retained, plus
   rails matching this pipeline (locks/ledgers untouched, one `review`-kind Discord embed via
   `lib/discord-embed.sh`, `RESULT:` line as the authoritative outcome since `claude -p` exit
   codes can't carry logical outcomes). sed-fill contract verified against
   `review/review-run.sh:81-87`; independently critic-reviewed (2 blocking findings fixed).
2. **`gjc-reap.sh` — now wired into the janitor (was: unwired).** Its header still names a clawhip
   `tmux.stale` route that never existed; that trigger is superseded. The reaper is now invoked by
   `gjc-worktree-janitor.sh`'s age-based coordinator tmux sweep (Workstream I —
   [maintenance/gjc-worktree-janitor.sh](#maintenancegjc-worktree-janitorsh)), gated on
   `[janitor].tmux_reap_enabled` (default OFF). It remains usable manually, and the primary stop for a
   hung run is still `_exec`'s own `timeout 1800` plus the janitor's worktree crash-net.
3. **Stale unit description.** `issue-spool-adapter.service` says "→ Hermes issue-intake webhook",
   but the script dispatches directly to `gjc-run.sh launch`; no hermes webhook hop exists (the
   hermes webhook platform is disabled — [20-hermes-agent.md](20-hermes-agent.md#the-gateway)).
4. **Installed units == rendered templates.** All 9 gjc-bot units (renamed from a flat
   `gjc-bot-scripts/systemd/` copy-comparison, now superseded by the render pipeline) match the
   `gjc-fleet/systemd/*` templates rendered through `render/render.sh`; each `ExecStart` points at
   the absolute stage-dir path under `~/github/engels74-bot/gjc-fleet/pipeline/<stage>/`. Installed
   to `~/.config/systemd/user/` (user-scope, no `sudo`) + `systemctl --user daemon-reload` as part
   of the 2026-07-07 monorepo + user-units migration; all four services last ran `Result=success`,
   timers/path unit `active`.
5. **`.bak-discord-20260706-212308` wave.** The same-day backups record a purely
   notification-layer change: raw `clawhip send` calls migrated to the shared `discord_embed`
   helper, plus the `narrate()` `--error` bugfix. No control-flow changes.

## Open questions

- **Automerge canary.** `automerge.sh` is committed, wired (unit + timer + `verify.sh`), and fully
  guard-railed, but `automerge_enabled` is still `false` on the live host — the lane has not yet been
  canaried on a real renovate/dependabot PR. Enabling it (per-repo, watched) is the open operational step.
- **Per-repo review concurrency.** The review handler is still fleet-wide single-flight on the global
  `review.lock` (one handler at a time across all repos). K1's per-repo lock makes true per-repo
  parallelism safe to build, and K7's `review.backlog` signal surfaces when the serial lane falls behind,
  but running handlers for different repos concurrently remains a documented follow-up (not yet built).
- Is the interactive `wrapper` lane intended to be re-enabled, or is `launch`/`_exec` the permanent
  design? (The earlier build-log noted the coordinator rewire was deliberately HELD by user choice.) The
  paired `tmux.stale` → `gjc-reap` question is now resolved — the reaper is wired into the janitor.
- Residual: why the original `ai-code-review-handler-original.md` was removed on 2026-07-06 is still
  unknown (the template itself was restored and live-verified; see Discrepancies #1).

## Changelog

- 2026-07-09 (v2-current-state rewrite) — Doc set rebaselined to current state; prior history in git.
  This page: automerge + fleet-update + tmux-reaper lanes documented; ci-fixer author scope, policy
  re-arm, and K lock-topology added; engine dispatch (gjc) + cutover-complete; stale gjc-reap/push-race
  questions resolved.
