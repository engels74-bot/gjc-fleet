<!--
status: draft            # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - all module pages in this directory
maintainer_notes: >
  This is the index. Keep the file list and the at-a-glance table in sync with the
  module pages; push all substance to those pages. Append to Changelog at the bottom.
-->

# Architecture — gjc / hermes / clawhip fleet

Modular architecture documentation for the autonomous GitHub gjc-bot system on this host.
Start with [00-overview.md](00-overview.md) (five-minute read), then follow the reading order it
suggests. Each page is self-contained and independently editable; every page ends with
`## Open questions` and `## Changelog`.

## Pages

| Page | Contents |
|---|---|
| [00-overview.md](00-overview.md) | What the whole system is; component table; topology diagram; history in one breath |
| [10-gajae-code.md](10-gajae-code.md) | `gjc` the coding agent: monorepo structure, CLI/run modes, control surfaces (RPC/MCP/ACP), `~/.gjc` |
| [20-hermes-agent.md](20-hermes-agent.md) | hermes: gateway, Discord adapter, kanban, cron, `~/.hermes` |
| [30-clawhip.md](30-clawhip.md) | clawhip: event pipeline, routes, DLQ semantics, issue spool, `~/.clawhip` |
| [35-gjc-relay.md](35-gjc-relay.md) | The loopback embed proxy + supervision stack (added beyond the original layout — see its maintainer notes) |
| [40-gjc-bot-automation.md](40-gjc-bot-automation.md) | The shell glue pipeline, script by script; scheduling map; worktree lifecycle |
| [50-configuration-and-state.md](50-configuration-and-state.md) | Consolidated config/state/secret-custody inventory (names only, no values) |
| [60-data-flow-and-integration.md](60-data-flow-and-integration.md) | **The heart**: every integration seam + the end-to-end sequence of a real job |
| [70-deployment-and-operations.md](70-deployment-and-operations.md) | Services, scheduling, network posture, identities, logs; start/stop/rollback procedures |
| [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md) | Terms/aliases, the 2026-07-06 wave timeline, consolidated open questions |

This doc set is the single source of truth. An earlier hermes-stack build-log/runbook that once
held the operational procedures and build history (Phases A–G) has been retired and deleted;
70-deployment-and-operations.md now owns start/stop/rollback, and the build phases survive as the
"Phase A–G" glossary entry in
[90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#glossary).

## System at a glance

| Component | Role | Source | Runtime | Runs as |
|---|---|---|---|---|
| gajae-code (`gjc`) | Coding agent (fixes issues, opens PRs) | `~/github/engels74/gjc/gajae-code` | `~/.gjc` | on-demand subprocess |
| hermes-agent | Discord "GJC Brain" + cron + kanban | `~/github/engels74/gjc/hermes-agent` | `~/.hermes` | `hermes-gateway.service` |
| clawhip | Event → Discord router + GitHub poller | `~/github/engels74/gjc/clawhip` | `~/.clawhip` | `clawhip.service` (:25294) |
| gjc-relay | Plain text → rich embed loopback proxy | `~/.gjc-relay/src` | `~/.gjc-relay` | `gjc-relay.service` (:25295) |
| gjc-bot | issue → run → review → merge-gate glue | `~/github/engels74-bot/gjc-bot-scripts` | `~/.gjc-bot` | systemd path/timers + hermes cron |

```
GitHub ──poll── clawhip ──spool──▶ gjc-bot ──runs──▶ gjc / claude ──PRs──▶ GitHub
                   │                                                        │
                   └──REST──▶ gjc-relay ──embeds──▶ Discord ◀──chat──▶ hermes┴─MCP─▶ gjc
```

## Conventions used in these pages

- Citations are `path:line` against the 2026-07-06/07 state of the repos; line numbers drift.
- `> [inferred]` marks statements not directly confirmed against source/runtime.
- Secret material is referenced by **name/role only** — never values, never numeric Discord IDs.
- Metadata block at the top of each page tracks `status` (draft/reviewed/verified) and sources.

## Open questions

- None specific to the index — the consolidated system-wide list lives in
  [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#open-questions).

## Changelog

- 2026-07-06 — Initial doc set created (all pages status: draft); verified against sources the
  same day (independent review pass: APPROVE, all spot-checks passed).
- 2026-07-07 — Post-EasyHDR-RUSTSEC-run updates to pages 20/30/35/40: hermes config tuning
  (approvals off, max_turns, terminal.cwd, MCP timeout) + SOUL.md workspace/delegation rules;
  clawhip issue/CI embed routes + corrected issue-spool claim; relay multi-embed batch splitting
  + 6 new design-system kinds; review-handler template live-verified, push-race open question.
- 2026-07-07 (later) — Full verification pass across all 10 pages against live sources, configs,
  and systemd state (five parallel audits); `last_verified` bumped everywhere. Substantive drift
  fixed: hermes brain switched to Codex/`gpt-5.5` with the `auth.json` credential pool (page 20 +
  custody table on 50); third hermes cron job (EasyHDR PR-115 monitor); hermes ExecStart corrected
  (no `--replace`); relay figures refreshed (~710 lines, 17 tests, 23 kinds); clawhip config
  ~7.4 KB + `embedbatch` backup; review lane marked operational on 60; push-race promoted to the
  consolidated open-questions list; wave timeline extended through `embedbatch` + the Codex switch.
- 2026-07-07 (repo-move pass) — This documentation set now lives in its own git repo,
  `engels74-bot/gjc-architecture` (moved from `~/documentation/architecture/`). Reflects two more
  repo renames done this session: `engels74-bot/server-tool` → `engels74-bot/gjc-server-tool`
  (the stackman / `server-script` ops-console TUI; only the repo/dir was renamed, the Python
  package and console-script entrypoints are unchanged — not referenced elsewhere on this page, so
  no other edit needed) and `engels74-bot/gjc-bot` → `engels74-bot/gjc-bot-scripts`, which was
  also reorganized from a flat script dir into pipeline-stage subfolders (`intake/` `run/`
  `review/` `maintenance/` `lib/` `systemd/`). Fixed the "System at a glance" table's gjc-bot
  Source cell, which still cited the dead `~/scripts/repo-bot`; confirmed the new path and layout
  against the live filesystem and all four systemd units' `ExecStart=`. Corrected the then-existing
  runbook cross-reference to its on-disk path at the time (later retired — see the following entry);
  flagged in 00-overview's Open questions since that move wasn't part of this session's known
  changes. No secrets or numeric IDs introduced.
- 2026-07-07 (runbook-retirement pass) — The earlier hermes-stack build-log/runbook has been
  deleted; this doc set is now stated as the single source of truth. Rewrote the "Related, outside
  this directory" pointer accordingly and dropped "runbook relationship / staleness" from the page
  table. (Repo-split clarification landed in 00-overview and 70.)
- 2026-07-07 (fleet/ move + component rename) — The shell-glue component is now consistently
  **gjc-bot**; page 40 renamed to `40-gjc-bot-automation.md`. The six working clones, their
  worktree buckets, and `review/` moved into `~/github/engels74-bot/fleet/`; scripts, clawhip,
  and hermes configs re-pointed and re-verified live.
- 2026-07-07 (state-dir rename) — `~/.repo-bot` → `~/.gjc-bot` and `REPO_BOT_*` → `GJC_BOT_*`
  everywhere on disk; at-a-glance table updated.
