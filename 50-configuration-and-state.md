<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/.gjc, ~/.hermes, ~/.clawhip, ~/.gjc-relay, ~/.repo-bot (runtime evidence)
  - ~/github/engels74-bot/gjc-bot-scripts/, ~/scripts/backuprestore/
maintainer_notes: >
  Edit this file in isolation. Names/roles only — NEVER add secret values here.
  This is the consolidated inventory; per-component detail lives on the component pages.
-->

# Configuration & state inventory

> Cross-cutting reference: every config file, env file, database, lock, ledger, and worktree
> location, with owner and purpose. **No secret values — names/roles only.**

## Secrets custody (names only)

| Secret (env var name) | Lives in | Used by |
|---|---|---|
| NanoGPT API key (`NANOGPT_API_KEY`) | `~/.hermes/.env` | gjc-bot triage + merge-gate LLM calls, weekly issue-triage cron; kept as hermes revert/fallback provider (the brain switched to Codex 2026-07-07) |
| Codex/Copilot credential pool (OAuth + fingerprinted API keys, no env var) | `~/.hermes/auth.json` | hermes brain model (`active_provider: openai-codex`, `gpt-5.5`) since 2026-07-07 |
| Bot GitHub PAT (`GITHUB_TOKEN` → exported as `GH_TOKEN`) | `~/.hermes/.env` | hermes, all gjc-bot `gh` calls |
| Hermes Discord bot token (`DISCORD_BOT_TOKEN`) + `DISCORD_HOME_CHANNEL` | `~/.hermes/.env` | hermes gateway ("GJC Brain" identity) |
| clawhip GitHub token (`CLAWHIP_GITHUB_TOKEN`) | `~/.clawhip/clawhip.env` | clawhip GitHub monitors |
| clawhip Discord bot token (`CLAWHIP_DISCORD_BOT_TOKEN`) | `~/.clawhip/clawhip.env` | clawhip sends ("GJC Clawhip" identity); also read directly by `dlq-watch.sh`/`alert.sh` for out-of-band alarms |
| `CLAWHIP_DISCORD_API_BASE` (loopback URL, not a secret) | `~/.clawhip/clawhip.env` | the switch that routes clawhip through gjc-relay |
| `EXA_API_KEY` | gjc env/config | gjc's `exa` MCP server |
| Per-session notification tokens | `<repo>/.gjc/state/notifications/<sessionId>.json` | gjc notifications SDK clients |

Notable custody pattern: **`~/.hermes/.env` is the de-facto shared secret store** — gjc-bot
scripts grep `GITHUB_TOKEN`/`NANOGPT_API_KEY` out of it at runtime rather than having their own
env file. `~/.gjc-relay/relay.env` deliberately holds **no** token (the bot token transits
per-request in the `Authorization` header).

## Per-component runtime directories

### `~/.gjc` (gajae-code) — detail in [10-gajae-code.md](10-gajae-code.md#runtime--config-gjc)

`agent/config.yml` (model profile `codex-pro`), `agent/mcp.json` (exa, codebase-retrieval),
`agent/agent.db` (auth/usage/settings), `agent/credential-auto-import-state.json`,
`agent/history.db`, `agent/models.db`, `agent/sessions/<workspace-key>/…jsonl`,
`agent/terminal-sessions/`, `logs/gjc.YYYY-MM-DD.log`, `gpu_cache.json`, `star-reminder.json`.

### `~/.hermes` (hermes) — detail in [20-hermes-agent.md](20-hermes-agent.md#runtime--config-hermes)

`config.yaml` (+ `.bak-discord-20260706-213503`, `.bak-yolo-20260706-231938`), `.env` (0600 — the
shared secret store; + `.bak-workdir-20260706-232516`), `SOUL.md` (+
`.bak-workspace-20260706-232544`), `channel_directory.json`, `discord_threads.json`,
`gateway.pid`/`gateway.lock`/`gateway_state.json`, `gateway/` (Discord command-sync state),
`kanban.db` (+ `.dispatch.lock`, `.init.lock`) and `kanban/`, `state.db` (+shm/wal —
sessions/messages), `verification_evidence.db`, `auth.json`/`auth.lock` (the provider credential
pool — see Secrets custody), `cron/` (`jobs.json`, `.jobs.lock`, `.tick.lock`, `ticker_heartbeat`,
`ticker_last_success`, `output/<job_id>/*.md`), `scripts/` (cron wrappers), `hermes-agent/`
(source checkout + venv the service runs), `memories/`, `hooks/`, `sessions/`, `skills/`,
`platforms/`, `sandboxes/`, `pairing/`, `bin/`, `logs/`, `.gjc/` (hermes-local gjc `state/`),
caches.

### `~/.clawhip` (clawhip) — detail in [30-clawhip.md](30-clawhip.md#runtime--config-clawhip)

`config.toml` (routes/templates/monitors) + four generational backups
(`.bak-phaseg-20260706-164830` → `.bak-g7-20260706-183120` → `.bak-discord-20260706-204953` →
`.bak-embedbatch-20260707-015213`), `clawhip.env` (+ `.bak-discord-…`).

### `~/.gjc-relay` (gjc-relay) — detail in [35-gjc-relay.md](35-gjc-relay.md#structure)

`gjc-relay` binary, `src/` + `Cargo.toml`/`Cargo.lock` + `target/` (own crate, built in place),
**`design-system.json`** (shared styling source of truth; + `.bak-embedbatch-20260707-015213`),
`relay.env`, `dlq-watch.sh`, `alert.sh`, `check-kind-coverage.sh`, `.omc/`. `src/main.rs` also
carries a `.bak-embedbatch-20260707-015213` from the batch-splitting wave.

### `~/.repo-bot` (gjc-bot state) — detail in [40-gjc-bot-automation.md](40-gjc-bot-automation.md#env--config-surface)

The dir name (and the `REPO_BOT_*` env prefix) keeps the component's historical "repo-bot"
working name; the component itself is called **gjc-bot** throughout this doc set.

| File | Purpose |
|---|---|
| `issue-spool.jsonl` | Input queue — clawhip appends `github.issue-opened` records (JSONL) |
| `issues.jsonl` | Dedup ledger of processed issues (terminal states `dispatched`/`skipped`) |
| `reviews.jsonl` | Seen-set ledger for review-detector (marked on every poll) |
| `merge-gate.jsonl` | Per-`repo#pr#sha` dedup ledger for merge-gate verdicts |
| `gjc.lock` | Single-flight lock for the gjc run lane (held by `_exec` fd 9 for a run's lifetime; also taken by the janitor per pass) |
| `review.lock` | Single-flight lock shared by review-run handler **and** merge-gate (mutual exclusion) |
| `issues.lock`, `merge-gate.lock`, `reviews.lock` | Per-lane pass locks |
| `adapter.log`, `gjc-run.log`, `review.log`, `merge-gate.log`, `janitor.log` | Per-lane logs |
| `prompt-*.md` | Transient per-run prompt files (created by `gjc-run.sh launch`, removed by `_exec`) |

## Databases

| DB | Owner | Contents |
|---|---|---|
| `~/.hermes/state.db` (~6.9 MB) | hermes | `sessions`, `messages`, `state_meta`, `gateway_routing`, `compression_locks` (`hermes_state.py:696-793`) |
| `~/.hermes/kanban.db` | hermes | Kanban board (tasks, task_runs, task_events, kanban_notify_subs, …) |
| `~/.hermes/verification_evidence.db` | hermes | Evidence store (schema not investigated) |
| `~/.gjc/agent/agent.db` | gjc | `auth_credentials`, `cache`, `model_usage`, `settings` |
| `~/.gjc/agent/history.db` | gjc | Prompt history + FTS5 |
| `~/.gjc/agent/models.db` | gjc | Model discovery cache |

## Worktrees

Three distinct worktree families — do not conflate:

| Family | Location | Created by | Cleaned by |
|---|---|---|---|
| Automated run worktrees | `~/github/engels74-bot/fleet/<repo>.gajae-code-worktrees/run-<stamp>-<pid>/` | `gjc-run.sh launch` | `gjc-run.sh _exec` (normal), janitor (crash-net) |
| gjc interactive/coordinator worktrees | `<repo>.gajae-code-worktrees/main-<hash>/` (detached HEAD) | gjc itself (`--worktree` / coordinator) | left for reuse; janitor explicitly skips |
| hermes kanban worktrees | `<repo>/.worktrees/<task-id>/` (branch `wt/<task-id>`) | `kanban_db.py:_ensure_git_worktree` | kanban lifecycle (none live observed) |

Plus the isolated review checkout `~/github/engels74-bot/fleet/review/<repo>` (a full clone, not a
worktree — own `.git`, so the review lane never contends with the run lane).

All of the above live under `~/github/engels74-bot/fleet/` — the **fleet clone root** holding
every pipeline-owned working copy (the six app clones, their worktree buckets, `review/`) since
the 2026-07-07 fleet/ move; the root of `~/github/engels74-bot/` holds only the bot's own
`gjc-*` project repos.

## systemd units (source vs installed)

Repo-bot unit *sources* live in `~/github/engels74-bot/gjc-bot-scripts/systemd/`; installed copies
in `/etc/systemd/system/` are byte-identical as of 2026-07-07 (reinstalled + `daemon-reload` this
session when the scripts left the now-dead `~/scripts/repo-bot/`). All four `ExecStart=` now resolve
under `~/github/engels74-bot/gjc-bot-scripts/<subfolder>/` — `intake/issue-spool-adapter.sh`,
`review/review-detector.sh`, `review/merge-gate.sh`, `maintenance/gjc-worktree-janitor.sh` (each
last run `Result=success`). The relay-stack units
(`gjc-relay.service`, `gjc-dlq-watch.service`, `gjc-relay-alert.service`, the
`clawhip.service.d/10-gjc-relay.conf` drop-in) and `clawhip.service`/`hermes-gateway.service`
exist only in `/etc/systemd/system/` (hermes' unit is generated by
`hermes_cli/gateway.py`/`service_manager.py`; clawhip's differs from the repo's
`deploy/clawhip.service` template). Full service map:
[70-deployment-and-operations.md](70-deployment-and-operations.md#service-map).

## Backups & rollback

`~/scripts/backuprestore/{backup-now.sh,restore.sh}` — snapshot + full-revert tooling; every
Phase-G/relay artifact is registered for teardown (`restore.sh --apply`, optional
`--purge-repos`). `backup-now.sh` now captures directory manifests for
`~/github/engels74-bot/gjc-bot-scripts` and `~/.repo-bot` (`backup-now.sh:80-81`). The dated
`.bak-*` files across `~/.clawhip` and `~/.hermes` are per-wave inline backups, distinct from this
snapshot tooling — the relocated scripts carry no `.bak-*` files (they are git-managed in the
`gjc-bot-scripts` repo). Note `restore.sh:137` still runs `rm -rf ~/scripts/repo-bot`, now a no-op
(see [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#open-questions)).

## Open questions

- `~/.hermes/verification_evidence.db` schema/purpose.
- `~/.gjc-relay/.omc/` contents.
- Whether `~/scripts/backuprestore/` snapshots include the relay stack added after Phase G
  (the earlier build-log asserted registration, not re-verified here).

## Changelog

- 2026-07-06 — Initial draft (consolidated from all component research).
- 2026-07-07 — Verification pass: inventory synced to the 2026-07-06/07 waves — hermes brain
  switched to the Codex OAuth pool (`auth.json` row added; NanoGPT custody rescoped to gjc-bot);
  hermes inline backups added (`.bak-yolo`, `.env.bak-workdir`, `SOUL.md.bak-workspace`) plus
  `logs/` and `.gjc/`; clawhip backup count 3→4 (`embedbatch`); relay `design-system.json`/`main.rs`
  embedbatch backups; gjc `credential-auto-import-state.json`. `~/.repo-bot` inventory re-verified
  complete, no drift.
- 2026-07-07 (repo-move pass) — Status → verified. Re-verified live: secrets still sourced from
  `~/.hermes/.env` by name (scripts `grep '^GITHUB_TOKEN='`→export `GH_TOKEN`, `grep
  '^NANOGPT_API_KEY='`); `~/.repo-bot` state dir unchanged; `relay.env` holds no token
  (`RELAY_BIND`/`RELAY_DESIGN_SYSTEM` only); `clawhip.env` names confirmed. Fixed script-path drift
  for the `gjc-bot-scripts` relocation: systemd sources now `~/github/engels74-bot/gjc-bot-scripts/
  systemd/` (byte-identical to installed, reinstalled + `daemon-reload`; all four `ExecStart=` under
  the new `<subfolder>/` layout, `Result=success`). Backup section: dropped dead
  `~/scripts/repo-bot` from the `.bak-*` list (git-managed now, no inline backups), noted
  `backup-now.sh:80-81` manifests and the `restore.sh:137` `rm -rf ~/scripts/repo-bot` no-op.
- 2026-07-07 (runbook-retirement pass) — Reframed the two references to the earlier hermes-stack
  build-log/runbook (backup-registration claims) to past tense; that build-log has been deleted and
  this doc set is the single source of truth.
- 2026-07-07 (fleet/ move + component rename) — Component consistently named **gjc-bot**
  (`~/.repo-bot` and `REPO_BOT_*` flagged as historical naming). Worktree-family and
  review-checkout paths updated to the new `~/github/engels74-bot/fleet/` clone root.
