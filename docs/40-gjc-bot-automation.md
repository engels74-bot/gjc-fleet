<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-07
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
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  Line citations refer to the scripts in gjc-fleet/pipeline/ as re-verified 2026-07-07
  (post the pipeline-stage reorg + self-locating SCRIPTS_DIR fix, and post the monorepo +
  user-units migration later the same day). Paths are given relative
  to the repo root ~/github/engels74-bot/gjc-fleet/, i.e. inside its pipeline/ subdir.
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
| `review/` | `review-detector.sh`, `review-run.sh`, `merge-gate.sh`, `review-policy-decide.sh` (B-2 one-review policy), `ci-fixer.sh` + `ci-fixer-run.sh` (B-3 fix-until-green, default OFF), `review-checkout.sh` (shared isolated-checkout helper), `ai-code-review-handler-original.md` + `ci-fix-handler.md` (templates), `tests/` (offline guardrail proofs) |
| `maintenance/` | `gjc-worktree-janitor.sh`, `stale-branches.sh` |
| `lib/` | `discord-embed.sh`, `engine.sh` (coding-engine dispatch), `gh-ci.sh` (CI-state classifier), `ledger.sh` (JSONL dedup/caps/backoff), `github-md.sh` (house-style GFM), `userctl.sh` |

The unit **templates** (`.service` / `.timer` / `.path`) that used to live in this repo's own
`systemd/` subdir now live at the `gjc-fleet` repo **root** `systemd/` — one level up from
`pipeline/` — since they're shared across the whole fleet (relay + clawhip + gjc-bot), not just
this pipeline.

> The prior flat path `~/scripts/repo-bot/` is **DEAD**, and so is the standalone `gjc-bot-scripts`
> repo (archived on GitHub, pointer README, history preserved via merge into `gjc-fleet`) — every
> script resolves its own repo root at runtime (see [Self-locating scripts](#self-locating-scripts)).

Two trigger fabrics drive it: **clawhip** (polls GitHub, emits events, writes the issue spool) and
**systemd** (path unit + timers that run the glue). Heavy lifting is shelled out to **`gjc`** (the
coding agent) and **headless `claude`** (the review handler); clawhip (through gjc-relay) is the
Discord narration bus. Hermes participates only via two cron jobs (through real-file wrappers).

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
            └─ merge-gate.sh (10 min timer) ── CI green? → LLM verdict (no tools)
                     → PR comment MERGE_READY / REQUEST_CHANGES + Discord embed
                     → a HUMAN merges

Cleanup lanes: gjc-worktree-janitor (2 min timer) · gjc-reap.sh (manual) ·
               stale-branches.sh (hermes cron, report-only) · issue-triage-fetch.sh (hermes cron, read-only)
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

Crash-net for orphaned launch worktrees (`maintenance/gjc-worktree-janitor.sh:1-159`); timer every
2 min, plus called inline by `gjc-run.sh launch` and `gjc-reap.sh`. Takes `gjc.lock` for the whole
pass (`:124-128`) — if a live run holds it, the janitor skips entirely (closes the timer race).
Builds an occupancy set from `/proc/<pid>/cwd` scans + `tmux list-panes` (`:56-65`). Removes a
worktree only when **all** hold: under `<repo>.gajae-code-worktrees/*`; on a branch (detached-HEAD
`main-<hash>` worktrees are left for gjc's interactive lane to reuse); no live occupant; mtime age
≥ `GRACE_SECONDS=600` (`:91-109`). `DRY_RUN=1` supported. Live log confirms correct
skip-detached-HEAD behavior.

### run/gjc-reap.sh

Kills a hung gjc tmux session's **entire pane process tree** (PID-based BFS via `pgrep -P`, never
pattern matching, `run/gjc-reap.sh:37-46`), leaf-first TERM → `tmux kill-session` → KILL. Rationale:
killing only the tmux session orphans the in-session wrapper holding `gjc.lock`; killing the tree
closes the held fd and releases the lock (`:5-9`). Ends with a janitor pass
(`JANITOR=$SCRIPTS_DIR/maintenance/gjc-worktree-janitor.sh`, `:21`). **Currently unwired**
— see Discrepancies.

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

The **fix-until-green poller** — bounded and guard-railed, **DEFAULT OFF** (`review/ci-fixer.sh:1-219`).
Timer every 10 min. Three kill switches gate every run (`gate_open`, `:96-100`; see
[Fix-until-green](#fix-until-green-ci-fixer)). **Bot-authored PRs ONLY** (`gh pr list --author "$BOT"`,
`:207`). Per open bot PR on its HEAD sha, `consider_pr` (`:167-200`) classifies via the shared
`ci_state`: GREEN/PENDING/NONE → skip; RED → check caps (`max_per_sha=2`, `max_per_pr=5`, `:179-183`),
exponential backoff (`backoff_base_mins * 2^attempts`, `:154-162,186-189`), a non-blocking
`review-<repo>.lock` pre-check (`:193-197`), then `launch_fix` records **both** ledger `#try` keys and
fires `ci-fixer-run.sh` (`:139-150`). Caps exhausted → `give_up` posts a needs-human comment +
a loud `ci-fix.escalation` embed to `#gjc-approvals`, **once**, dedup on `#gaveup` (`:112-134`).

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
`log()` only if the caller has not, `:32-34`). Sourced today by `ci-fixer-run.sh`; `review-run.sh`
keeps its own inline copy for now and will migrate later (kept untouched this phase to avoid conflict
with the engine lane, `:8-10`).

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
| AI Code Review Handler (applies suggestions) | `review/review-run.sh` → `ci-fix-handler`'s sibling | **ENGINE** | `[review].engine` (gjc default) |
| CI-Fix Handler (fixes RED CI) | `review/ci-fixer-run.sh` | **ENGINE** | `[review].engine` (gjc default) |

**The CI-fix lane SHARES `REVIEW_ENGINE`** — it deliberately reads the *same* `[review].engine` knob,
so the fleet makes **one** engine cutover decision for both coding lanes rather than two.

**Cutover gate (deploy-time, not code).** The shipped default is already `engine = "gjc"`, but the
default flip is gated operationally: it requires **≥3 handler runs across ≥2 repos, including ≥1
failing-CI case**, with **auto-rollback armed**, before gjc is trusted as the fleet default. Until a
host has walked that gate it MAY pin `engine = "claude"` in `fleet.toml`; the pin is a deploy
decision, never a code change.

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

## Fix-until-green (ci-fixer)

The B-3 lane makes a bounded, guard-railed attempt to turn a bot PR's RED CI green — **default OFF**,
and engineered so it can never livelock or spend unboundedly.

**Three kill switches (ALL THREE must allow a run):** `CI_FIXER_ENABLED=1` (from `[ci_fixer].enabled`,
default 0/OFF) **AND** no `~/.gjc-bot/ci-fixer.disable` marker file on the host **AND** `DRY_RUN` unset/0
(`DRY_RUN=1` logs intended actions, takes none). Disabled or marker present → exit 0 quietly, zero
records.

**Scope: bot-authored PRs ONLY.** Automated-author (renovate/dependabot) and human PRs are never
touched — upstream bots force-push over fleet commits, so a fix there would be clobbered and churn.

**Per bot PR, on its HEAD sha:** `ci_state` GREEN/PENDING/NONE → skip; RED → if the PR already gave up
→ skip; else evaluate **caps** (`max_per_sha=2`, `max_per_pr=5`) and **exponential backoff**
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

## Shared lib

`lib/discord-embed.sh` (`:1-62`) — the single Discord-embed emitter, sourced by
`intake/issue-spool-adapter.sh`, `review/merge-gate.sh`, `review/review-policy-decide.sh`,
`review/ci-fixer.sh`, and `review/ci-fixer-run.sh`. The design-system kinds it now carries include
`review-policy`, `ci-fix`, and `ci-fix.escalation`.

`lib/engine.sh` (`:1-63`) — the coding-engine dispatch. One entrypoint
`engine_run <gjc|claude> <filled_prompt_path> <timeout_secs>`: runs one coding-work invocation under a
hard `timeout` (124 on timeout, 64 for a bad arg/unknown engine), dispatching gjc (`gjc -p --no-pty
"@prompt"`) vs the legacy claude path (MODEL_PRIMARY read only there). Sourceable with no side effects;
shared by `review-run.sh` and `ci-fixer-run.sh` so neither hardcodes a CLI.

`lib/gh-ci.sh` (`:1-60`) — the shared CI-state classifier. `ci_state <repo> <sha>` →
GREEN/RED/PENDING/NONE from check-runs + commit statuses (the body is extracted **verbatim** from
merge-gate so the advisory gate and the ci-fixer classify identically); `ci_red_summary` is a
human-readable failing-check list for `<details>` blocks. Emits no tokens/IDs/paths.

`lib/ledger.sh` (`:1-61`) — the shared append-only JSONL ledger helpers (`ledger_seen`, `ledger_mark`,
`ledger_count`, `ledger_last_ts`) backing the policy/ci-fixer dedup, caps, and backoff bookkeeping.
**Per-file** locking (each ledger `<f>` serialises on its own `<f>.lock`) so unrelated ledgers never
contend. `#try`/`#gaveup`/`#consumed`/`#outcome:*` keys carry a fixed trailing segment so a
startswith-count can't bleed across ids (pr 1 vs pr 12).

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
| `gjc-worktree-janitor.timer` | systemd timer | boot+2 min, every 2 min | maintenance/gjc-worktree-janitor.sh |
| `stale-branches-report` | hermes cron | `0 3 * * *` (no_agent) | `~/.hermes/scripts/stale-branches.sh` wrapper → maintenance/stale-branches.sh → `#gjc-approvals` |
| `mover-status-issue-triage` | hermes cron | `0 9 * * 1` (agent+prerun) | `~/.hermes/scripts/issue-triage-fetch.sh` wrapper → intake/issue-triage-fetch.sh → `#gjc-events` |
| `gjc-reap.sh` | none | manual | run/gjc-reap.sh |

The gjc-bot `.service` units are **user-scope** (`~/.config/systemd/user/`, no `sudo`) and set
`ExecStart=` to the absolute stage-dir path under
`/home/cvps/github/engels74-bot/gjc-fleet/pipeline/<stage>/<script>.sh` (verified against the
installed copies 2026-07-07, same day as the gjc-fleet monorepo migration; `ci-fixer.service` was
added later in the B-3 wave, `Nice=15`, shipped inert). Each also carries
`EnvironmentFile=-%h/.gjc-bot/gjc-bot.env` — the rendered, 0600 env file that supplies the
per-lane Discord channel IDs (see [Env & config surface](#env--config-surface)). Unit subtlety:
`issue-spool-adapter.service`, `review-detector.service`, and `ci-fixer.service` set
**`KillMode=process`** — without it, systemd's default control-group kill would reap the
`setsid`-detached gjc/handler/fixer run when the oneshot parent exits. The janitor unit deliberately has no `PrivateTmp` (needs the user tmux socket
in `/tmp`). All units are rendered from `gjc-fleet/systemd/*` by `render/render.sh apply --units`.

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
The B-2/B-3 waves add (all rendered from `fleet.toml` into `gjc-bot.env` — see
[45-fleet-config.md](45-fleet-config.md)): `REVIEW_ENGINE` (the ENGINE-lane engine, default gjc);
`REVIEW_AUTOMATED_AUTHORS`, `REVIEW_POLICY_MAX_HANDLER_RUNS`, `REVIEW_POLICY_DECISION_MODE` (one-review
policy); and `CI_FIXER_ENABLED` (default 0/OFF), `CI_FIXER_MAX_PER_SHA`, `CI_FIXER_MAX_PER_PR`,
`CI_FIXER_BACKOFF_BASE_MINS`, `CI_FIX_RUN_TIMEOUT` (fix-until-green).

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
`reviews.lock`, the per-repo `review-<repo>.lock` shared by the policy lane + ci-fixer, and a
per-ledger `<ledger>.lock` from `lib/ledger.sh`'s per-file locking), ledgers (`issues.jsonl`,
`reviews.jsonl`, `merge-gate.jsonl`, `review-policy.jsonl`, `ci-fixer.jsonl`), the B-3 host kill
marker (`ci-fixer.disable`, absent by default), the spool (`issue-spool.jsonl`), logs (`adapter.log`,
`gjc-run.log`, `review.log`, `merge-gate.log`, `ci-fixer.log`, `janitor.log`).

## Discrepancies

1. **Missing handler template — RESOLVED 2026-07-06 (later the same day).** `review/review-run.sh:20`
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
2. **`gjc-reap.sh` is unwired.** Its header claims invocation "by a clawhip route on `tmux.stale`",
   but no such route exists and `[monitors.tmux].sessions = []`. The live stop mechanism for a
   hung run is `_exec`'s own `timeout 1800` plus the janitor; the reaper is a manual tool.
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

- ~~Where should `ai-code-review-handler-original.md` come from?~~ Restored 2026-07-06 as an
  architecture-native rewrite (see Discrepancies #1). ~~The new version has not yet been exercised
  by a live review-detector launch.~~ **Exercised 2026-07-07:** two clean back-to-back handler
  runs on `easyhdr#115` (00:21 and 00:43, both `session.finished`) — checked out the PR, fixed CI
  ahead of review, applied augmentcode suggestions, replied, exited. Remaining sub-question: why
  the original was removed is still unknown.
- **Cross-lane push races on PR branches (observed 2026-07-07, easyhdr#115):** a hermes-delegated
  gjc session and the review handler both push to the same PR branch with no shared lock (hermes
  does not participate in the `review.lock`/`gjc.lock` protocol). Both observed collisions
  resolved via gjc's fetch+rebase (one "already fixed upstream" detection, one non-fast-forward
  reject+retry). Mitigated behaviorally via `~/.hermes/SOUL.md` delegation rules (rebase before
  push, never force-push); a structural lock remains a possible future upgrade.
- Is the interactive `wrapper` lane (and a `tmux.stale` → `gjc-reap` route) intended to be
  re-enabled, or is `launch`/`_exec` the permanent design? (The earlier build-log noted the
  coordinator rewire was deliberately HELD by user choice.)
- `merge-gate.sh` and `review-run.sh` share `review.lock` — confirm this mutual exclusion
  (merge-gate defers while a handler mutates the PR) is a deliberate contract rather than
  incidental lock reuse.
- ~~**Glob auto-discovery now sweeps the infra repos.**~~ **Resolved 2026-07-07 (fleet/ move):**
  the working clones moved to `~/github/engels74-bot/fleet/` and `GH_ROOT` now defaults there, so
  the five glob-driven lanes match exactly the 6 monitored apps; the infra repos (**`gjc-fleet`**
  and `gjc-server-tool`, since the same-day monorepo migration folded `gjc-bot-scripts` and
  `gjc-relay` into `gjc-fleet`) sit one level up, outside the glob.
  Accepted side effect: the infra repos are no longer covered by
  `stale-branches.sh`/`issue-triage-fetch.sh` either (their branches/issues are human-managed).
- ~~**`restore.sh` still references the dead `~/scripts/repo-bot` path.**~~ **Resolved 2026-07-07
  (gjc-fleet monorepo + user-units migration):** the stale `rm -rf ~/scripts/repo-bot` line has
  been removed from `~/scripts/backuprestore/restore.sh`. The same pass made `restore.sh`
  dual-scope — it tears down user-scope units first (`systemctl --user disable --now`), then any
  leftover `/etc/systemd/system/` units (`sudo systemctl disable --now` + `rm -f`, both scopes
  followed by their own `daemon-reload`) — reflecting the fleet's mixed transitional state during
  the 24–48 h soak before the old system units are deleted. `backup-now.sh`'s manifest gained a
  user-unit listing (`systemctl --user list-unit-files 'hermes*' 'clawhip*' 'gjc-*' 'issue-*'
  'review-*' 'merge-*'`) alongside the existing system-unit listing, plus a whole-`gjc-fleet`-repo
  manifest replacing the old separate `gjc-bot-scripts-repo.txt`/`gjc-relay-repo.txt` lines — see
  [50-configuration-and-state.md](50-configuration-and-state.md#backups--rollback).
- ~~Only `mover-status` has real runs so far~~ **Overtaken 2026-07-07:** `easyhdr` completed the
  first full non-mover-status pipeline exercise (RUSTSEC triage → PR #115, review handler ×2,
  merge-gate advisory — see Changelog). The remaining four repos are still ledgered only as
  `pre-existing-baseline-g7` skips.

## Changelog

- 2026-07-06 — Initial draft from full script reads + installed-unit comparison.
- 2026-07-06 (later) — Handler template restored (architecture-native one-shot rewrite);
  discrepancy #1 and the corresponding open question updated.
- 2026-07-07 — Handler template live-verified (2 successful runs, easyhdr#115); cross-lane
  push-race open question added. First full non-mover-status pipeline exercise: easyhdr RUSTSEC
  triage (8 issues → PR #115, review handler ×2, merge-gate REQUEST_CHANGES advisory).
- 2026-07-07 (later) — Verification pass: all four main scripts, line citations, unit inventory
  (9 units byte-identical between `~/scripts/repo-bot/systemd/` and `/etc/systemd/system/`), timer
  schedules, and `~/.repo-bot` state inventory re-verified live. Fixed the stale "template
  currently missing" warning (restored + live-verified); added `CODING_GUIDELINES` to the
  review-run sed-fill list; marked the "first non-mover-status run" open question overtaken.
- 2026-07-07 (reorg re-verify) — Repo renamed `gjc-bot` → `gjc-bot-scripts` and reorganized into
  pipeline stage-dirs (`intake/ run/ review/ maintenance/ lib/ systemd/`); the flat
  `~/scripts/repo-bot/` path is dead. Re-read all nine scripts + lib in the new location and
  rewrote every `path:line` citation (the self-locating `SCRIPTS_DIR` line and sibling refs shifted
  the near-top line numbers; deeper numbers mostly stable, all re-verified). Documented the
  self-locating `SCRIPTS_DIR` fix and the two real-file hermes cron wrappers (`~/.hermes/scripts/*`
  now `exec` the new stage-dir paths). Confirmed all 4 installed `.service` units' `ExecStart` point
  at the stage-dirs and are byte-identical to `gjc-bot-scripts/systemd/`, services `Result=success`,
  timers/path `active`. New findings: glob auto-discovery now also matches the co-located infra
  repos; `restore.sh` still names the dead path (both raised as open questions). Status → verified.
- 2026-07-07 (runbook-retirement pass) — Reframed the two references to the earlier hermes-stack
  build-log/runbook (the `worktree_target_mismatch` "critical recurring bug" note and the
  coordinator-rewire open-question aside) to past tense; that build-log has been deleted and this
  doc set is the single source of truth.
- 2026-07-08 (notification-overhaul: engine + B-2 + B-3 wave) — Documented the new automation stages
  against the implemented code. Added: the **engine vs brain** LLM-invocation lane audit (table +
  the ENGINE lane's shared `[review].engine`/`REVIEW_ENGINE` cutover gate, deploy-time not code); the
  **one-review policy** for automated-author PRs (author routing, FIRST-CONSUME → DECIDE
  APPLY/DISMISS/ESCALATE state machine, the HARD deferred-mark invariant under the per-repo
  `review-<repo>.lock` distinct from the global `review.lock`, and `--suppress-trigger`); the
  **fix-until-green** ci-fixer (three kill switches, bot-authored-only scope, caps + exponential
  backoff, the DISCLOSED per-repo BLOCKING-lock change vs review-run's non-blocking global lock, and
  outcome-truth-in-shell via `git ls-remote`); and the **combined review ⊗ ci-fix** state machine +
  livelock bounds. New script-by-script entries: `review-policy-decide.sh`, `ci-fixer.sh`,
  `ci-fixer-run.sh`, `ci-fix-handler.md`, `review-checkout.sh`. Rewrote the `review-run.sh` entry
  (now `engine_run`, not `claude -p`) and the `review-detector.sh` entry (two author-routed lanes);
  updated `merge-gate.sh` for the shared `lib/gh-ci.sh` + `lib/github-md.sh`. Expanded the Shared lib
  section (`engine.sh`/`gh-ci.sh`/`ledger.sh`/`github-md.sh`), the Pipeline-at-a-glance diagram, the
  Scheduling map (`ci-fixer.timer`, inert by default; `KillMode=process`), and the Env & config +
  state inventories (new `REVIEW_ENGINE`/`REVIEW_POLICY_*`/`CI_FIXER_*` keys; `review-policy.jsonl`/
  `ci-fixer.jsonl` ledgers; `ci-fixer.disable` marker; per-repo/per-ledger locks). Offline guardrail
  proofs live in `pipeline/review/tests/`; live termination proofs are a deploy-phase gate.
- 2026-07-07 (fleet/ move + component rename) — Page renamed `40-repo-bot-automation.md` →
  `40-gjc-bot-automation.md`; the component is now consistently called **gjc-bot** throughout the
  doc set (the on-disk `~/.repo-bot` state dir and `REPO_BOT_*` env prefix keep the historical
  name). The six working clones, their `*.gajae-code-worktrees/` buckets, and `review/` moved into
  `~/github/engels74-bot/fleet/`; all eight scripts' `GH_ROOT` default now points there
  (gjc-bot-scripts commit `59142f9`), clawhip's six `[[monitors.git.repos]] path` entries and
  hermes' `GJC_COORDINATOR_MCP_WORKDIR_ROOTS`/`terminal.cwd`/SOUL.md conventions updated to match;
  services restarted and re-verified live (janitor walks fleet/ paths, merge-gate clean, clawhip
  polling, coordinator MCP env confirmed). Glob-sweep open question resolved by the move.
- 2026-07-07 (state-dir rename) — On-disk identifiers now match the component name:
  `STATE_DIR` moved `~/.repo-bot` → `~/.gjc-bot` (ledgers/locks/logs intact) and every
  `REPO_BOT_*` env override is now `GJC_BOT_*` (gjc-bot-scripts commit `11b32a7`);
  `issue-spool-adapter.path` reinstalled watching the new spool path. Same commit fixed a stale
  handler-template instruction that still sourced `lib/discord-embed.sh` from the dead
  `~/scripts/repo-bot` path (Phase 8 embed block). Verified live: all four lanes ran clean, and
  a spool append at the new path fired the path unit within seconds.
- 2026-07-07 (gjc-fleet monorepo + user-units migration) — The standalone `gjc-bot-scripts` repo
  is archived (pointer README, history preserved via merge); the pipeline now lives as the
  `pipeline/` subdirectory of the `engels74-bot/gjc-fleet` monorepo, stage-dir layout unchanged
  (`intake/ run/ review/ maintenance/ lib/`). The `systemd/` unit templates moved up one level, to
  `gjc-fleet`'s repo root (shared with clawhip/relay units, not pipeline-specific). All four
  gjc-bot systemd units moved from system-level to **user-scope** (`~/.config/systemd/user/`, no
  `sudo`), rendered from `gjc-fleet/systemd/*` and installed by `render/render.sh apply --units`;
  each gained `EnvironmentFile=-%h/.gjc-bot/gjc-bot.env`. The three previously hard-coded numeric
  Discord channel defaults (`issue-spool-adapter.sh`, `merge-gate.sh`, the review-handler template
  constant) were **removed from the repo** — `ISSUE_NOTIFY_CHANNEL`/`MERGE_GATE_CHANNEL`/
  `REVIEW_NOTIFY_CHANNEL` now hard-fail (`:?`) unless supplied by the rendered `gjc-bot.env`, and
  `review-run.sh` `sed`-fills `NOTIFY_CHANNEL` into the handler prompt from
  `REVIEW_NOTIFY_CHANNEL`. `~/scripts/backuprestore/restore.sh`'s stale `rm -rf
  ~/scripts/repo-bot` line was removed and the script made dual-scope (tears down user units, then
  any `/etc/systemd/system/` leftovers); `backup-now.sh` now captures a user-unit manifest
  (including the `merge-*` glob) plus a whole-`gjc-fleet`-repo manifest. Verified live: five
  pipeline triggers exercised end-to-end (timers scheduled correctly, the path unit fired ≤4 s on
  a spool append, all oneshots `Result=success`).
