<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/github/engels74-bot/gjc-fleet/pipeline/<stage>/*.sh (the pipeline spine; stage-dir layout)
  - ~/.clawhip/config.toml, ~/github/engels74/gjc/clawhip/src/sink/local_file.rs
  - ~/.hermes/config.yaml, ~/.hermes/cron/jobs.json, ~/.gjc-relay/src/main.rs
  - ~/.gjc-bot/*.log (live run evidence: mover-status#24 → PR #25; easyhdr#115 review handler ×2)
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  This is the heart of the doc set — the end-to-end walk. Component internals belong on
  the component pages; only integration seams belong here.
-->

# Data flow & integration

> How the components actually talk, and the full life of one real job.
> Component pages: [gjc](10-gajae-code.md) · [hermes](20-hermes-agent.md) ·
> [clawhip](30-clawhip.md) · [gjc-relay](35-gjc-relay.md) · [gjc-bot](40-gjc-bot-automation.md).

## The seams (every cross-component mechanism)

| Seam | Mechanism | Data format | Evidence |
|---|---|---|---|
| clawhip → gjc-bot | **Shared file**: appends to `~/.gjc-bot/issue-spool.jsonl` (localfile sink); systemd `.path` unit fires on modify | JSONL, `content` leads with `<repo>#<n> opened: <title>` (compact, ≤240 chars) | `~/.clawhip/config.toml:29-33`; `clawhip src/sink/local_file.rs:75-81` |
| gjc-bot → gjc | **Subprocess**: `timeout 1800 gjc -p --no-pty "@promptfile"` in a fresh worktree | Prompt file in; gjc's side effects (commits/PR) out; exit code | `pipeline/run/gjc-run.sh:130` |
| gjc-bot → claude | **Subprocess**: `timeout 5400 claude -p --dangerously-skip-permissions --model opus < filled-prompt` in an isolated checkout | Filled markdown template in; PR mutations out | `pipeline/review/review-run.sh:101` |
| gjc-bot → clawhip | **CLI → loopback HTTP**: `clawhip send` / `clawhip agent <state>` POST to the daemon on 127.0.0.1:25294 | Event JSON; `GJCEMBED1` envelope in message content | `run/gjc-run.sh:49-58`; `lib/discord-embed.sh:61` |
| gjc-bot → GitHub | **CLI**: `gh api` / `gh pr list` / `gh pr comment` / `gh issue view` | REST JSON | throughout the scripts |
| gjc-bot → LLM (triage, merge verdict) | **HTTPS**: NanoGPT chat-completions, **no tools** | one-line `ACTIONABLE:`/`SKIP:` or `MERGE_READY:`/`REQUEST_CHANGES:` | `intake/issue-spool-adapter.sh:65-72`; `review/merge-gate.sh:62-70` |
| clawhip → Discord | **HTTP via loopback proxy**: REST base overridden to gjc-relay 127.0.0.1:25295 | Discord REST; relay rewrites `GJCEMBED1` content into embeds (since 2026-07-07 also splitting multi-envelope batches into one embed per line) | `~/.clawhip/clawhip.env`; `~/.gjc-relay/src/main.rs` (`MAGIC`/`ALLOWED_KEYS` at `:22-23`) |
| clawhip → GitHub | **Polling**: monitor sources hit the GitHub API every 60 s for 6 repos | REST JSON → internal events | `~/.clawhip/config.toml [monitors]` |
| hermes → gjc | **MCP (stdio subprocess)**: gateway registers `gjc_coordinator` → `gjc mcp-serve coordinator` | MCP tool calls (start_session, send_prompt, read_turn, …) | `~/.hermes/config.yaml`; live child in the gateway cgroup |
| hermes → gjc-bot | **Cron subprocess**: two **real-file** wrappers in `~/.hermes/scripts/` (hermes rejects symlinks for `--script`) that `exec` `maintenance/stale-branches.sh` + `intake/issue-triage-fetch.sh` in the `gjc-fleet` monorepo's `pipeline/` subdir; cron may also carry self-scheduled agent jobs that don't touch gjc-bot (e.g. the `monitor-easyhdr-pr115-rustsec` 60-min job) | script stdout → LLM prompt / Discord message | `~/.hermes/cron/jobs.json`; `~/.hermes/scripts/{stale-branches,issue-triage-fetch}.sh` |
| hermes → Discord | **Own gateway session** (bot identity "GJC Brain"), plain markdown, NOT via relay | Discord gateway/REST | `plugins/platforms/discord/adapter.py` |
| user → hermes | Discord DM / @mention → per-user session, auto-threads | chat | [20-hermes-agent.md](20-hermes-agent.md#the-gateway) |
| augmentcode[bot] → gjc-bot | **Polling**: review-detector reads PR reviews via `gh api` | GitHub review objects | `review/review-detector.sh:47-49` |

Shared state that crosses boundaries: the issue spool + ledgers + locks in `~/.gjc-bot/`
([50-configuration-and-state.md](50-configuration-and-state.md)), the worktrees next to each
clone, the design system `~/.gjc-relay/design-system.json` (read by both the relay and
`discord-embed.sh`), and `~/.hermes/.env` as the shared secret store.

**Two deliberately separate Discord identities:** "GJC Clawhip" (post-only notifier — everything
clawhip/relay renders) and "GJC Brain" (hermes, conversational). They never share a data path;
they share only a *style* (design-system emoji taxonomy + SOUL.md voice).

## End-to-end: the life of a GitHub issue

The scenario below is the real automated lane, and it has run live (evidence:
`~/.gjc-bot/gjc-run.log` shows `mover-status#24` producing PR #25 on 2026-07-06, with worktree
cleanup and a subsequent review-handler pass logged in `review.log`).

```mermaid
sequenceDiagram
    autonumber
    participant GH as GitHub
    participant CH as clawhip (daemon :25294)
    participant RL as gjc-relay (:25295)
    participant DC as Discord
    participant SD as systemd (path/timers)
    participant AD as issue-spool-adapter.sh
    participant LLM as NanoGPT (no tools)
    participant RUN as gjc-run.sh
    participant GJC as gjc (headless)
    participant DET as review-detector.sh
    participant REV as review-run.sh + claude
    participant MG as merge-gate.sh
    participant HU as Human

    GH-->>CH: monitor poll (60 s): issue opened in <repo>
    CH->>RL: POST channel message (per-repo channel)
    RL->>DC: rich embed "Issue #n opened — title" (github.issue-opened embed route, added 2026-07-07)
    CH->>CH: localfile sink route
    Note over CH: appends JSONL record to ~/.gjc-bot/issue-spool.jsonl
    SD->>AD: issue-spool-adapter.path fires on file modify
    AD->>AD: flock issues.lock; dedup vs issues.jsonl
    AD->>GH: gh api — re-fetch issue (skip PRs/closed)
    AD->>LLM: triage prompt (issue title/body, NO tools)
    LLM-->>AD: "ACTIONABLE: …" (or SKIP)
    AD->>RUN: gjc-run.sh launch --repo <r> --issue <n>
    RUN->>RUN: flock -n gjc.lock (busy→rc75→requeue)
    RUN->>RUN: git worktree add run-<stamp> from origin/<default>
    RUN->>RUN: write prompt file; setsid _exec (detach)
    RUN->>CH: clawhip agent started
    CH->>RL: session.started → RL->>DC: "agent started" embed
    RUN->>GJC: timeout 1800 gjc -p --no-pty "@prompt"
    GJC->>GH: commit, push -u, open PR "Fixes #n" (as engels74-bot)
    RUN->>CH: clawhip agent finished → embed
    RUN->>RUN: worktree remove + prune; release gjc.lock
    GH-->>GH: augmentcode[bot] auto-reviews the PR
    SD->>DET: review-detector.timer (5 min)
    DET->>GH: gh api — last augmentcode[bot] review
    DET->>REV: has "N suggestions" → review-run.sh --pr --review <id>
    REV->>REV: isolated checkout review/<repo>; fill template; flock review.lock
    REV->>GH: claude -p applies suggestions, pushes, replies on PR
    REV->>CH: clawhip agent finished → embed
    SD->>MG: merge-gate.timer (10 min)
    MG->>GH: CI state on HEAD sha (checks + statuses)
    MG->>LLM: diff review (NO tools) when GREEN
    LLM-->>MG: "MERGE_READY: …" (or REQUEST_CHANGES)
    MG->>GH: gh pr comment (advisory verdict)
    MG->>CH: discord_embed merge-gate.advisory
    CH->>RL: → RL->>DC: verdict embed in #gjc-approvals
    HU->>GH: reviews and merges the PR
```

Key invariants along the way:

- **Single-flight per lane**: at most one gjc run (`gjc.lock`) and one review handler
  (`review.lock`) at a time; merge-gate defers to an active handler by taking the same
  `review.lock` non-blocking.
- **At-most-once dispatch**: append-only JSONL ledgers (`issues.jsonl`, `reviews.jsonl`,
  `merge-gate.jsonl`) with terminal states; "busy" (rc 75) is deliberately *not* ledgered so the
  issue retries on the next trigger.
- **Untrusted text never reaches tools**: issue bodies and diffs go only to *no-tools* LLM calls;
  the tool-bearing agents (gjc, claude) receive locally-authored prompt templates.
- **Humans keep the merge**: merge-gate is advisory and comment-only; branch protection +
  a human click do the merge.

## The interactive lane (hermes drives gjc)

Separate from the automated lane above: the user converses with **GJC Brain** (hermes) in Discord
(`#gjc-brain` or a repo channel/thread); hermes can operate gjc through the **Coordinator MCP**
(`gjc_coordinator` in `~/.hermes/config.yaml` → `gjc mcp-serve coordinator`, a live child of the
gateway process): start/register sessions, send prompts, await turns, answer gjc's questions, read
artifacts ([10-gajae-code.md](10-gajae-code.md#integration-surface-how-other-things-drive-gjc)).
This lane uses gjc's own deterministic `main-<hash>` worktrees and does **not** pass through
`gjc-run.sh` or its single-flight lock — a known, intentional asymmetry (the coordinator rewire to
the shared launcher was explicitly held; see
[90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#open-questions)).

## Discord topology

Guild: "engels74's server". Channels (names only; numeric IDs live in the configs/scripts):

| Channel | Fed by | Content |
|---|---|---|
| `#<repo>` × 6 (`#mover-status`, `#easyhdr`, `#obzorarr`, `#otpravkarr`, `#perevoditarr`, `#zondarr`) | clawhip per-repo monitors | issue-opened, PR-status embeds |
| `#gjc-events` | clawhip defaults + gjc-bot | agent lifecycle narration (`agent.*` embeds), issue dispatch verdicts, weekly issue-triage digest |
| `#gjc-approvals` | clawhip route + gjc-bot + hermes cron | `agent.approval-requested`, merge-gate advisories, nightly stale-branch report, DLQ-bury alarms |
| `#gjc-brain` | hermes | conversation with GJC Brain (home channel) |
| `#gjc-lab` | canary route | test/verification traffic only (embed galleries, 429 drills) |
| `#gjc-control` | (nothing currently) | present in the directory; no active route |

## Failure & degradation paths

- **Relay down** → clawhip's send fails → DLQ-bury (permanent loss) → `gjc-dlq-watch` posts an
  out-of-band alarm directly to Discord; `gjc-relay.service` restarts forever (`RestartSec=1`).
  See [35-gjc-relay.md](35-gjc-relay.md#live-services-the-supervision-stack).
- **gjc run hangs** → `_exec`'s `timeout 1800` kills it; `failed` embed posted; worktree removed;
  janitor (2 min) is the crash-net if `_exec` itself died.
- **Adapter busy** (gjc.lock held) → rc 75, issue left un-ledgered, retried by the 5-min backup
  timer or the next spool write.
- **Discord 429** → mirrored through the relay so clawhip's own backoff handles it.
- **Review lane** → operational: the handler template (`ai-code-review-handler-original.md`,
  briefly missing on 2026-07-06) is restored and was live-verified with two clean runs on
  2026-07-07; see [40-gjc-bot-automation.md](40-gjc-bot-automation.md#discrepancies).

## Open questions

- Does the coordinator (interactive) lane ever contend with the automated lane on the same repo?
  The lanes use different worktrees but the same clones/remotes; no lock spans both. **No longer
  hypothetical:** a cross-lane push race on a shared PR branch was observed 2026-07-07
  (easyhdr#115); behaviorally mitigated via SOUL.md rebase-before-push rules, structural lock
  still open — see [40-gjc-bot-automation.md](40-gjc-bot-automation.md#open-questions).
- Is there any path by which hermes learns of pipeline outcomes besides reading Discord (e.g.
  polling the coordinator or the ledgers)? None found.
- `github.pr-status-changed` events feed the per-repo channels; whether merge-gate's verdict
  comment triggers any further clawhip event loop was not traced (no loop observed live).

## Changelog

- 2026-07-06 — Initial draft; sequence validated against the live mover-status#24 → PR #25 run.
- 2026-07-07 — Verification pass: seams re-verified against current scripts/configs. Review lane
  marked operational (template restored + live-verified); issue-opened step now reflects the
  explicit embed route; hermes cron seam scoped to the two wrapper jobs (a third, self-scheduled
  agent job now exists); relay seam notes batch splitting; the cross-lane push race is now
  observed fact (easyhdr#115), not inference.
- 2026-07-07 (reorg re-verify) — Repo renamed `gjc-bot` → `gjc-bot-scripts` and reorganized into
  pipeline stage-dirs; the dead `~/scripts/repo-bot/` path is gone. Re-verified all gjc-bot seam
  rows against live source and rewrote every `path:line` citation to the new stage-dir paths
  (gjc-run `run/…:130`, review-run `review/…:101`, adapter `intake/…:65-72`, merge-gate
  `review/…:62-70`, review-detector `review/…:47-49`, discord-embed `lib/…:61`). Confirmed clawhip
  seam anchors unchanged (`config.toml:29-33`, `local_file.rs:78` truncate-240, relay MAGIC/
  ALLOWED_KEYS `:22-23`). hermes→gjc-bot row now records the real-file wrapper indirection
  (`~/.hermes/scripts/*` exec the stage-dir scripts). Status → verified.
- 2026-07-07 (fleet/ move + component rename) — Terminology only: repo-bot → **gjc-bot** in the
  seam tables and channel matrix; cross-links updated to `40-gjc-bot-automation.md`. Seam
  mechanics unchanged (repo paths inside `GH_ROOT` now resolve under
  `~/github/engels74-bot/fleet/`).
- 2026-07-07 (state-dir rename) — Seam paths updated for the `~/.repo-bot` → `~/.gjc-bot`
  rename (spool, ledgers, locks, logs). Seam mechanics unchanged.
- 2026-07-07 (gjc-fleet monorepo + user-units migration) — Light-touch path sweep: seam-table
  citations (`gjc-run.sh`, `review-run.sh`) and the sources header now point at
  `gjc-fleet/pipeline/<stage>/` instead of the archived standalone `gjc-bot-scripts` repo; the
  hermes→gjc-bot seam row now says "the `gjc-fleet` monorepo's `pipeline/` subdir". Seam mechanics,
  the sequence diagram, and the Discord topology are all unaffected by the migration.
