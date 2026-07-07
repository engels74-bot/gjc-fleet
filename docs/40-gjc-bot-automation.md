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
2026-07-07 monorepo migration; before that, `gjc-bot`) is a set of nine Bash scripts + shared lib
that turn the three projects into an autonomous **GitHub-issue → PR → review → advisory-merge**
bot for six of engels74's application repos. The scripts are grouped by **pipeline stage**:

| Stage dir | Scripts |
|---|---|
| `intake/` | `issue-spool-adapter.sh`, `issue-triage-fetch.sh` |
| `run/` | `gjc-run.sh`, `gjc-reap.sh` |
| `review/` | `review-detector.sh`, `review-run.sh`, `merge-gate.sh`, `ai-code-review-handler-original.md` (template) |
| `maintenance/` | `gjc-worktree-janitor.sh`, `stale-branches.sh` |
| `lib/` | `discord-embed.sh` |

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
            │        ▼
            │  review-run.sh ── isolated checkout; timeout 5400 claude -p --model opus
            │                   applies suggestions, pushes, replies on the PR
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

Timer every 5 min, **zero LLM** (`review/review-detector.sh:1-75`). For each open bot PR
(`gh pr list --author engels74-bot`, `:47`) fetch the *last* `augmentcode[bot]` formal review
(`:48-49`); record `repo#pr#reviewid` in `reviews.jsonl` on **every** poll (`:55` — so a
"No suggestions" review can never re-launch later); launch only when the body matches
`[0-9]+ suggestion` and NOT `no suggestions at this time` (`:58`). If `review.lock` is free →
`review-run.sh --repo --pr --review <id>` (`:63-65`); if held, a handler is already active, so
just mark seen. `RUNNER` defaults to `$SCRIPTS_DIR/review/review-run.sh` (`:28`).

### review/review-run.sh

Launcher for the **AI Code Review Handler** — a headless Claude Code run (`review/review-run.sh:1-115`).
`launcher` (`:66-91`): non-blocking `review.lock` precheck (rc 75), `ensure_checkout` maintains an
**isolated** per-repo clone at `~/github/engels74-bot/fleet/review/<repo>` (own `.git`, never contends
with the gjc lane, `:53-64`), `sed`-fills the Config block of the handler template
(REPO/PR_ID/REVIEW_ID/CODING_GUIDELINES/MODEL_PRIMARY=opus/MODEL_FAST=sonnet, `:81-87`;
`CODING_GUIDELINES` defaults to `AGENTS.md`, `:29`), then `setsid _handler`. The template path is
`HANDLER_TEMPLATE=$SCRIPTS_DIR/review/ai-code-review-handler-original.md` (`:20`).
`_handler` (`:93-108`) holds `review.lock` on fd 9, narrates via clawhip, runs
`( cd $dir && timeout 5400 claude -p --dangerously-skip-permissions --model opus < filled )`
(`:101`), narrates by exit code. The handler applies augmentcode's suggestions, pushes, and replies
on the PR as the bot. `CLAUDE=/home/cvps/.local/bin/claude` (`:22`).

The template this script fills briefly went **missing on disk** on 2026-07-06 and has since been
restored as an architecture-native rewrite (see [Discrepancies #1](#discrepancies)); it was
live-verified with two clean handler runs on 2026-07-07.

### review/merge-gate.sh

Timer every 10 min; **advisory and comment-only** — never a formal GitHub review (self-review
422s), never an auto-merge (`review/merge-gate.sh:1-99`). Per open bot PR: compute CI state on the
HEAD sha from check-runs + commit statuses → GREEN/RED/PENDING/NONE (`:49-59`); only on GREEN and
not already gated for that sha (ledger `merge-gate.jsonl`, `:45-46,78`); take a non-blocking
`review.lock` so it never runs while a review handler is mutating the PR (`:81`); then a
**no-tools** NanoGPT review of the truncated diff → `MERGE_READY:` / `REQUEST_CHANGES:`
(inconclusive coerced to REQUEST_CHANGES, `:62-70,84`). Posts a `gh pr comment` + a
`merge-gate.advisory` embed to `#gjc-approvals` (`:86-94`). Humans do the actual merge. (Note:
merge-gate does not define `SCRIPTS_DIR`; it sources `lib/discord-embed.sh` via an inline
`cd "$(dirname)/.." && pwd` resolve, `:28`.)

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

## Shared lib

`lib/discord-embed.sh` (`:1-62`) — the single Discord-embed emitter, sourced by
`intake/issue-spool-adapter.sh` and `review/merge-gate.sh`.
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
| `gjc-worktree-janitor.timer` | systemd timer | boot+2 min, every 2 min | maintenance/gjc-worktree-janitor.sh |
| `stale-branches-report` | hermes cron | `0 3 * * *` (no_agent) | `~/.hermes/scripts/stale-branches.sh` wrapper → maintenance/stale-branches.sh → `#gjc-approvals` |
| `mover-status-issue-triage` | hermes cron | `0 9 * * 1` (agent+prerun) | `~/.hermes/scripts/issue-triage-fetch.sh` wrapper → intake/issue-triage-fetch.sh → `#gjc-events` |
| `gjc-reap.sh` | none | manual | run/gjc-reap.sh |

All four systemd `.service` units are **user-scope** (`~/.config/systemd/user/`, no `sudo`) and set
`ExecStart=` to the absolute stage-dir path under
`/home/cvps/github/engels74-bot/gjc-fleet/pipeline/<stage>/<script>.sh` (verified against the
installed copies 2026-07-07, same day as the gjc-fleet monorepo migration). Each also carries
`EnvironmentFile=-%h/.gjc-bot/gjc-bot.env` — the rendered, 0600 env file that supplies the
per-lane Discord channel IDs (see [Env & config surface](#env--config-surface)). Unit subtlety:
`issue-spool-adapter.service` and `review-detector.service` set **`KillMode=process`** — without
it, systemd's default control-group kill would reap the `setsid`-detached gjc/handler run when the
oneshot parent exits. The janitor unit deliberately has no `PrivateTmp` (needs the user tmux socket
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
(`MERGE_GATE_REPOS`/`REVIEW_REPOS`/`TRIAGE_REPOS`), `*_CHANNEL` overrides, `DRY_RUN`.

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
`reviews.lock`), ledgers (`issues.jsonl`, `reviews.jsonl`, `merge-gate.jsonl`), the spool
(`issue-spool.jsonl`), logs (`adapter.log`, `gjc-run.log`, `review.log`, `merge-gate.log`,
`janitor.log`).

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
