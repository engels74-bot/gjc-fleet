<!--
status: draft            # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - all component pages in this directory (10, 20, 30, 35, 40)
  - ~/downloads/hermes-stack-runbook.md (history — moved from ~/documentation/, see Open questions)
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  This page must stay readable in under five minutes — push detail to component pages.
-->

# System overview

## What this system is

An **autonomous GitHub repo-bot fleet** running natively on this host (user `cvps`): GitHub issues
on six personal repos are triaged by a cheap LLM, fixed by a coding agent in isolated git
worktrees, reviewed, and advisory-gated for a human merge — with every step narrated to Discord as
rich embeds, and a conversational Discord "brain" available to drive the coding agent on demand.

Three upstream source projects, one locally-authored component, and a shell glue layer:

| # | Component | Role | Language | Source | Runtime/config | Started by |
|---|---|---|---|---|---|---|
| 1 | **gajae-code (`gjc`)** | Coding-agent harness that writes the actual fixes and opens PRs | Rust + TypeScript (Bun) | `~/github/engels74/gjc/gajae-code` | `~/.gjc` | On demand: `gjc-run.sh` (headless) or hermes via Coordinator MCP |
| 2 | **hermes-agent** | Always-on Discord "GJC Brain": chat, cron scheduler, kanban; drives gjc via MCP | Python | `~/github/engels74/gjc/hermes-agent` | `~/.hermes` | `hermes-gateway.service` |
| 3 | **clawhip** | Event-to-Discord notification router; polls GitHub, writes the issue spool | Rust | `~/github/engels74/gjc/clawhip` | `~/.clawhip` | `clawhip.service` (daemon on 127.0.0.1:25294) |
| 4 | **gjc-relay** | Loopback proxy turning clawhip's plain-text Discord posts into styled embeds | Rust (local, ~710 lines) | `~/.gjc-relay/src` | `~/.gjc-relay` | `gjc-relay.service` (127.0.0.1:25295) |
| 5 | **repo-bot** | Shell glue: issue → triage → gjc run → review → merge gate | Bash | `~/github/engels74-bot/gjc-bot-scripts` (pipeline-stage dirs: `intake/` `run/` `review/` `maintenance/` `lib/` `systemd/`) | `~/.repo-bot` (state) | systemd path unit + timers, 2 hermes cron jobs |

Also on the field: **`engels74-bot`** (the bot's GitHub identity), **`augmentcode[bot]`** (external
PR reviewer the pipeline reacts to), **headless `claude`** (Claude Code, used only as the review
handler), and **NanoGPT/`minimax-m3`** (the cheap no-tools "brain model" for triage and merge
verdicts).

## Topology

```mermaid
flowchart LR
    subgraph GitHub
        REPOS[6 repos<br/>engels74/*]
        AUG[augmentcode-bot reviews]
    end
    subgraph Discord["Discord (engels74's server)"]
        CHANS[per-repo + gjc-events +<br/>gjc-approvals + gjc-brain]
    end
    USER((User))

    CH[clawhip daemon<br/>:25294] -- "poll 60s" --> REPOS
    CH -- "issue-opened record" --> SPOOL[(~/.repo-bot/<br/>issue-spool.jsonl)]
    SPOOL -- "systemd .path" --> RB[repo-bot scripts<br/>triage → run → review → gate]
    RB -- "gjc -p in worktree" --> GJC[gjc coding agent]
    RB -- "claude -p (review handler)" --> CC[claude headless]
    GJC -- "push + PR as engels74-bot" --> REPOS
    CC -- "apply suggestions" --> REPOS
    AUG --> RB
    RB -- "clawhip send / agent" --> CH
    CH -- "REST via api-base override" --> RL[gjc-relay :25295<br/>GJCEMBED1 → embeds]
    RL --> CHANS
    USER <--> HM[hermes gateway<br/>GJC Brain]
    HM <--> CHANS
    HM -- "Coordinator MCP" --> GJC
    HM -- "2 cron jobs" --> RB
```

Two Discord bot identities, deliberately separate paths: **GJC Clawhip** posts notifications
(everything on the clawhip→relay path); **GJC Brain** (hermes) converses in plain markdown and
never touches the relay. All fleet listeners are loopback-only; there are no inbound ports.
The in-path relay is supervised out-of-band: `gjc-dlq-watch.service` (alarms on clawhip DLQ-bury —
the operative watchdog) and `gjc-relay-alert.service` (`OnFailure`, rarely fires by design) both
curl Discord directly, bypassing clawhip and the relay
([35](35-gjc-relay.md) · [70](70-deployment-and-operations.md)).

## How a typical job flows (one paragraph)

clawhip's monitor notices a new issue and both posts a notice to the repo's Discord channel and
appends a record to the issue spool; a systemd path unit runs the spool adapter, which dedups,
re-fetches the issue via `gh`, and asks a **no-tools** LLM "actionable?"; if yes, `gjc-run.sh`
creates a fresh worktree and runs headless `gjc`, which commits, pushes, and opens a PR as
`engels74-bot`; augmentcode[bot] reviews the PR, and if it leaves suggestions, a detector launches
a headless `claude` handler that applies them; every 10 minutes a merge gate checks CI-green bot
PRs and posts an advisory `MERGE_READY`/`REQUEST_CHANGES` comment — and a **human** merges. Every
hop is narrated to Discord through clawhip → gjc-relay as styled embeds. Full walk-through with
sequence diagram: [60-data-flow-and-integration.md](60-data-flow-and-integration.md).

## History in one breath

Built incrementally per the runbook's Phases A–G (2026-07-05/06): hermes brain → bot GitHub
identity → Discord → clawhip → gjc + Coordinator MCP → automation lanes → fan-out to 6 repos.
The same evening, a separate "Discord unification" wave added gjc-relay and the embed design
system — which the runbook does not yet know about. A follow-up wave (2026-07-07, after the first
full EasyHDR pipeline exercise) added issue/CI embed routes, multi-embed batch splitting in the
relay, and hermes tuning — and hermes' brain model switched from NanoGPT/minimax-m3 to the Codex
subscription (`gpt-5.5`). Timeline & staleness:
[90-glossary-and-open-questions.md](90-glossary-and-open-questions.md).

## Reading order for newcomers

1. This page, then the diagram + tables in [README.md](README.md).
2. [60-data-flow-and-integration.md](60-data-flow-and-integration.md) — how it actually works.
3. [40-repo-bot-automation.md](40-repo-bot-automation.md) — the spine, script by script.
4. Component pages as needed: [10](10-gajae-code.md) · [20](20-hermes-agent.md) ·
   [30](30-clawhip.md) · [35](35-gjc-relay.md).
5. [50](50-configuration-and-state.md) + [70](70-deployment-and-operations.md) for state/ops,
   [90](90-glossary-and-open-questions.md) for terms and known unknowns.

## Open questions

- The runbook (`hermes-stack-runbook.md`, cited in this page's metadata) is currently at
  `~/downloads/hermes-stack-runbook.md`, not `~/documentation/` as prior drafts assumed —
  confirmed live on disk this pass. Downloads is an unusual permanent home for a reference doc;
  unclear if this is its intended stable location or a stray copy. > [inferred: not part of this
  session's known repo-rename/reorg changes]
- See the consolidated list in
  [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#open-questions).

## Changelog

- 2026-07-06 — Initial draft.
- 2026-07-07 — Verification pass: component table, topology, and job-flow paragraph re-verified —
  structurally unchanged. Added the relay watchdog note (dlq-watch/relay-alert), the 2026-07-07
  wave + Codex model switch to the history paragraph.
- 2026-07-07 (repo-move pass) — Docs relocated to the `gjc-architecture` git repo (was
  `~/documentation/architecture/`). Fixed dead source path: repo-bot component row now cites
  `~/github/engels74-bot/gjc-bot-scripts` (renamed from `gjc-bot`) with its new pipeline-stage
  layout, replacing the dead `~/scripts/repo-bot`; confirmed all four subfolders + `systemd/` on
  disk and all four systemd units' `ExecStart=` paths live. Topology diagram's `repo-bot scripts`
  node re-checked against the actual stage order (intake → run → review/merge-gate) — unchanged,
  still accurate. Rows 1–4 of the component table re-confirmed against live paths; no drift found.
  No `gjc-server-tool`/stackman ops-console reference exists on this page (nothing to rename).
  Also caught unrelated drift: the runbook source file has moved to `~/downloads/`; flagged above
  rather than silently assumed stable.
