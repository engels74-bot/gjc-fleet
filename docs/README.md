<!--
status: draft            # draft | reviewed | verified
last_verified: 2026-07-09
sources:
  - all module pages in this directory
maintainer_notes: >
  This is the index. Keep the file list and the at-a-glance table in sync with the
  module pages; push all substance to those pages. Changelog is a single current-state
  rebaseline entry — rewrite this page to current state rather than appending; prior history
  lives in git.
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
| [45-fleet-config.md](45-fleet-config.md) | `fleet.toml` key reference, the renderer command reference, secrets custody map, route invariants |
| [46-github-house-style.md](46-github-house-style.md) | House GitHub-Flavored-Markdown style for bot-authored PR comments/commits: golden skeletons, Conventional Commits, leakage rules |
| [47-renovate-policy.md](47-renovate-policy.md) | Canonical org-wide `renovate.json` policy: per-key rationale, all-non-fork-engels74 scope, canary-gated rollout + revert |
| [50-configuration-and-state.md](50-configuration-and-state.md) | Consolidated config/state/secret-custody inventory (names only, no values); the three-layer config model |
| [60-data-flow-and-integration.md](60-data-flow-and-integration.md) | **The heart**: every integration seam + the end-to-end sequence of a real job |
| [70-deployment-and-operations.md](70-deployment-and-operations.md) | Services, scheduling, network posture, identities, logs; start/stop/rollback procedures |
| [80-reproduction-guide.md](80-reproduction-guide.md) | Stand up your own fleet from scratch — accounts, prerequisites, secrets, bootstrap, verification |
| [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md) | Terms/aliases, the 2026-07-06/07 wave timeline, consolidated open questions |

This doc set is the single source of truth. An earlier hermes-stack build-log/runbook that once
held the operational procedures and build history (Phases A–G) has been retired and deleted;
70-deployment-and-operations.md now owns start/stop/rollback, and the build phases survive as the
"Phase A–G" glossary entry in
[90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#glossary).

**Since 2026-07-07**, "single source of truth" extends to a three-layer config model, not just
docs: `gjc-fleet` (this repo — code, unit templates, config templates, docs) is layer 1; the
untracked, host-local `~/.config/gjc-fleet/fleet.toml` (operator identity, the Discord channel-ID
map, path/version overrides, secret pointers) is layer 2; every rendered config file, env file, and
now every fleet systemd unit under `~/.*`/`~/.config/systemd/user/` is layer 3, produced from the
first two by `render/render.sh`. Detail: [45-fleet-config.md](45-fleet-config.md) ·
[50-configuration-and-state.md](50-configuration-and-state.md#the-three-layer-config-model-since-2026-07-07).

## System at a glance

| Component | Role | Source | Runtime | Runs as |
|---|---|---|---|---|
| gajae-code (`gjc`) | Coding agent (fixes issues, opens PRs) | `~/github/engels74/gjc/gajae-code` | `~/.gjc` | on-demand subprocess |
| hermes-agent | Discord "GJC Brain" + cron + kanban | `~/github/engels74/gjc/hermes-agent` | `~/.hermes` | `hermes-gateway.service` (user unit) |
| clawhip | Event → Discord router + GitHub poller | `~/github/engels74/gjc/clawhip` | `~/.clawhip` | `clawhip.service` (:25294, user unit) |
| gjc-relay | Plain text → rich embed loopback proxy | `~/github/engels74-bot/gjc-fleet/relay` | `~/.gjc-relay` | `gjc-relay.service` (:25295, user unit) |
| gjc-bot | issue → run → review → merge-gate glue, plus automerge + nightly fleet-update + reaper lanes | `~/github/engels74-bot/gjc-fleet/pipeline` | `~/.gjc-bot` | user-scope systemd path/timers + hermes cron |

```
GitHub ──poll── clawhip ──spool──▶ gjc-bot ──engine_run (gjc)──▶ gjc ──PRs──▶ GitHub
                   │                                                          │
                   └──REST──▶ gjc-relay ──embeds──▶ Discord ◀──chat──▶ hermes┴─MCP─▶ gjc
```

## Conventions used in these pages

- Citations are `path:line` against the 2026-07-06/07 state of the repos; line numbers drift.
- `> [inferred]` marks statements not directly confirmed against source/runtime.
- Secret material is referenced by **name/role only** — never values, never numeric Discord IDs.
- Metadata block at the top of each page tracks `status` (draft/reviewed/verified) and sources.
- Each page's `## Changelog` holds a single current-state rebaseline entry; prior history lives in
  git (rewrite-to-current-state, not append).

## Open questions

- None specific to the index — the consolidated system-wide list lives in
  [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#open-questions).

## Changelog

- 2026-07-09 (v2-current-state rewrite) — Doc set rebaselined to current state; prior history in git.
  This page: gjc-bot at-a-glance row + ascii flow updated for engine dispatch (gjc) and the new
  automerge/fleet-update/reaper lanes; added the per-page Changelog-convention bullet.
