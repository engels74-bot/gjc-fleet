<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/github/engels74/gjc/hermes-agent/ (pyproject.toml, hermes_cli/, gateway/, cron/, run_agent.py, hermes_state.py)
  - ~/.hermes/ (config.yaml, auth.json, SOUL.md, gateway_state.json, cron/jobs.json, cron/output/,
    channel_directory.json, scripts/{stale-branches.sh,issue-triage-fetch.sh})
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  hermes-agent is a very large upstream project (Nous Research); this page documents the
  structure relevant to THIS deployment plus enough internal shape to navigate the repo.
-->

# hermes-agent (`hermes`)

> Component page. For how a job flows through the whole system, see
> [60-data-flow-and-integration.md](60-data-flow-and-integration.md). For the index, see [README.md](README.md).

## Purpose

**hermes-agent** (package `hermes-agent` v0.18.0, by Nous Research, Python ≥3.11,<3.14) is a
general-purpose **messaging-platform AI agent**: an always-on gateway daemon connects chat platforms
(Discord, Telegram, Slack, Signal, WhatsApp, Matrix, …) to an LLM agent loop with tools, skills,
memory, scheduled jobs, and a kanban work-dispatch system.

**In this deployment** hermes is the **"GJC Brain"** — the conversational Discord bot the user talks
to, which can drive gajae-code via gjc's Coordinator MCP, and which runs two scheduled jobs via
its internal cron (a third, self-scheduled EasyHDR PR-115 monitor existed briefly and was removed
2026-07-07 — see [The cron subsystem](#the-cron-subsystem)). Live model:
`gpt-5.5` via the **OpenAI Codex subscription** (`~/.hermes/config.yaml`, `model.default: gpt-5.5`
/ `provider: openai-codex`; switched from NanoGPT/`minimax-m3` on 2026-07-07). Credentials resolve
from the OAuth credential pool in `~/.hermes/auth.json`, not from a NanoGPT key;
`providers.nanogpt` is kept in config only as a revert path.

## Structure

### Entry points (`pyproject.toml:307-310`)

- `hermes` → `hermes_cli.main:main` — the primary CLI.
- `hermes-agent` → `run_agent:main` — direct one-shot agent invocation.
- `hermes-acp` → `acp_adapter.entry:main` — ACP adapter for editors.

**Important correction to the folklore:** the huge repo-root `cli.py` (~726 KB) is **not** the
argparse entry point — it is the interactive REPL/terminal chat interface (`cli.py:1-13`). The real
CLI is `hermes_cli/main.py` (`def main()` at `hermes_cli/main.py:12686`), which registers ~60
subcommands from `hermes_cli/subcommands/*` (canonical set: `_BUILTIN_SUBCOMMANDS`,
`hermes_cli/main.py:12204-12225`). Highlights: `gateway`, `cron`, `kanban`, `model`, `tools`,
`setup`, `config`, `doctor`, `mcp`, `webhook`, `skills`, `profile`, `sessions`, `chat`.

### Top-level layout

| Dir / file | Role |
|---|---|
| `hermes_cli/` | Entire CLI: `main.py` dispatch, `subcommands/` parser builders, large handler modules (`gateway.py`, `config.py`, `kanban_db.py` ~351 KB, `models.py`, `doctor.py`, `setup.py`, …) |
| `gateway/` | The messaging gateway (see below): `run.py` (~972 KB orchestrator), `config.py`, `session.py`, `platforms/`, `relay/`, `kanban_watchers.py`, `slash_commands.py`, `stream_*` |
| `agent/` | Internals extracted from `run_agent.py`: the real conversation loop (`conversation_loop.py` ~294 KB), provider adapters (anthropic/bedrock/codex/azure), context compression |
| `run_agent.py` | `AIAgent` (`:393`) — thin orchestrator whose methods forward into `agent/`; `run_conversation` at `:5745` |
| `batch_runner.py` | Standalone batch trajectory generator (`BatchRunner:527`, multiprocessing, checkpointing, RL-format trajectories). Not part of this deployment's wiring |
| `hermes_state.py` | `SessionDB` (`:869`) over the on-disk `state.db` SQLite: tables `sessions`, `messages`, `state_meta`, `gateway_routing`, `compression_locks` (`SCHEMA_SQL:696-793`); WAL handling, corruption auto-repair |
| `cron/` | Built-in scheduler subsystem (`scheduler.py` ~164 KB, `jobs.py`, `blueprint_catalog.py`, `suggestions.py`) |
| `tools/` | Agent tool implementations (browser, code execution, delegate/subagents, cron tools, discord tool, computer-use) |
| `toolsets.py`, `model_tools.py` | Named tool groups + the registry layer exposing `get_tool_definitions`/`handle_function_call` |
| `plugins/` | Bundled extensions by category — notably `plugins/platforms/discord/` (the Discord adapter used here, ~354 KB `adapter.py`) |
| `providers/` | Model-provider profile registry (`register_provider(ProviderProfile)`) |
| `acp_adapter/`, `acp_registry/` | ACP server exposing hermes to editors + static registry manifest |
| `apps/` | End-user apps (Tauri/Electron desktop) |
| `tui_gateway/`, `ui-tui/` | Terminal-UI gateway backend (WS server) + frontend |
| `skills/` | Bundled skill library by domain |
| `mcp_serve.py` | stdio MCP server exposing hermes conversations as MCP tools (`hermes mcp serve`) |

## The gateway

The always-on daemon. On this machine it runs as **`hermes-gateway.service`**
("Hermes Agent Gateway - Messaging Platform Integration"). The installed unit's ExecStart is
`…/hermes-agent/venv/bin/python -m hermes_cli.main gateway run` (module form, **no `--replace`
flag** — the `service_manager.py` `hermes gateway run --replace` composition is not what is
installed). Runtime evidence agrees: `~/.hermes/gateway_state.json` and `gateway.pid` record
`argv: [.../hermes_cli/main.py, gateway, run]`. The coroutine entry point is
`gateway/run.py:start_gateway()`.

Message flow (`gateway/platforms/base.py`, `gateway/run.py`):

1. A platform adapter (all subclass `BasePlatformAdapter`, `gateway/platforms/base.py`) receives a
   message and calls `handle_message()` (`base.py:4585`), which is fire-and-forget: it spawns
   `_process_message_background(event, session_key)` (`base.py:4808`).
2. Session identity: `GatewayRunner._session_key_for_source` (`gateway/run.py:3442`) →
   `build_session_key` (`gateway/session.py:856`). This deployment sets
   `group_sessions_per_user: true`, so each user gets an isolated session within a shared channel;
   threads/DMs get their own keys.
3. The runner keeps an LRU cache of live `AIAgent` instances keyed by session key
   (`run.py:2873,2918`); the agent turn streams back through `stream_consumer.py`/`stream_dispatch.py`
   to the adapter's `send()`.

**Discord specifics (live):** adapter at `plugins/platforms/discord/adapter.py` (raw gateway
socket, threads, voice, dedup). Config `discord.reply_to_mode: first` and `auto_thread: true`
(`~/.hermes/config.yaml`; auto-thread decision at `adapter.py:5887-5901`; participated threads
persisted to `~/.hermes/discord_threads.json`). Home channel comes from `DISCORD_HOME_CHANNEL` in
`~/.hermes/.env` (the `#gjc-brain` channel). Channel discovery persists to
`~/.hermes/channel_directory.json`.

**HTTP surfaces:** (a) an API server (`gateway/platforms/api_server.py`: `/api/sessions*`,
`/v1/chat/completions`, `/api/cron/fire`, …) and (b) a generic webhook adapter
(`gateway/platforms/webhook.py`: `POST /webhooks/{route}`, default port 8644, HMAC-verified,
dynamic subscriptions in `~/.hermes/webhook_subscriptions.json`). **Neither is enabled in this
deployment** — no `WEBHOOK_ENABLED` in `.env` and no `webhook_subscriptions.json` on disk. The
"issue-intake webhook" mentioned in `issue-spool-adapter.service`'s description is a *dynamic
subscription that was never created*; the live intake path dispatches to `gjc-run.sh` directly
(see [40-gjc-bot-automation.md](40-gjc-bot-automation.md#discrepancies)).

## The kanban subsystem

A SQLite-backed task board that can **dispatch autonomous agent work** — the "cross-profile
coordination primitive" (`hermes_cli/kanban_db.py:1-69`). Statuses:
`triage, todo, scheduled, ready, running, blocked, review, done, archived` (`kanban_db.py:102`).

- **Dispatcher** = an embedded gateway loop (`gateway/kanban_watchers.py:744`, tick every
  `kanban.dispatch_interval_seconds`, default 60 s) calling `kanban_db.dispatch_once`: reap zombies,
  release stale claims (15-min TTL), promote `todo → ready` when parents are done, then atomically
  claim `ready → running` (CAS on `tasks.status`, `kanban_db.py:3433-3445`) and spawn a worker.
- **Worker spawn** = fire-and-forget subprocess `hermes -p <profile> --accept-hooks` with prompt
  `"work kanban task <id>"` and env (`HERMES_KANBAN_TASK/DB/BOARD/…`) so the child converges on the
  same board (`kanban_db.py:7662-7764`).
- **Workspaces**: `scratch` dirs, explicit `dir`, or real **git worktrees**
  (`git worktree add -b wt/<task-id> <repo>/.worktrees/<task-id>`, `kanban_db.py:5404-5475`) —
  note these are hermes' own worktrees, distinct from gjc's `*.gajae-code-worktrees` (see
  [50-configuration-and-state.md](50-configuration-and-state.md#worktrees)).
- **Failure handling**: a consecutive-failure circuit breaker (`_record_task_failure`,
  `kanban_db.py:6543`; trip → `blocked` + `gave_up` event) and a typed-block loop breaker
  (`block_task:4541`; `dependency` blocks route back to `todo`, recurring same-cause blocks route
  to `triage` after 2 recurrences).
- **goal_mode**: dispatched workers can run a Ralph-style judge loop (worker turn → judge model
  evaluates against the card → continue/stop; `hermes_cli/goals.py:1620`).
- **Notifications**: `kanban_notify_subs` binds a task to a chat surface; a 5-second gateway watcher
  pushes terminal events (completed/blocked/gave_up/…) to Discord/Telegram/Slack
  (`gateway/kanban_watchers.py:115`).
- Higher layers: `kanban_specify.py` (LLM-tighten triage cards), `kanban_decompose.py` (LLM fan-out
  into task graphs), `kanban_swarm.py` (planner/workers/verifier/synthesizer topology on the same
  kernel), `kanban_diagnostics.py` (read-only rule engine).

**Live status:** `~/.hermes/kanban.db` exists (with `.dispatch.lock` / `.init.lock`), i.e. the board
is initialized, but no evidence was gathered of active cards in the gjc-bot flow — the automated
issue lane bypasses kanban entirely. > [inferred] Kanban is currently idle capacity.

## The cron subsystem

Not systemd, not a separate daemon: a **60-second in-process ticker thread inside the gateway**
(`cron/__init__.py:9-15`, `cron/scheduler_provider.py:154-195`). Jobs live in a single JSON store
`~/.hermes/cron/jobs.json` (0600, atomic writes, `.jobs.lock`; `cron/jobs.py:687-754`). Each tick
(`cron/scheduler.py:3399+`) takes a cross-process `.tick.lock`, advances `next_run_at` under lock
(at-most-once), then runs due jobs in parallel.

Two job kinds (`run_job`, `scheduler.py:2386`):

- **`no_agent` script jobs** — resolve a script under `~/.hermes/scripts/`, run it (bash/python,
  sanitized env, timeout); empty stdout = silent success; non-zero exit = delivered error alert.
- **Agent jobs** — construct a fresh `AIAgent` (`platform="cron"`, isolated session,
  `skip_memory=True`, per-job model/toolsets) and run the prompt with an inactivity timeout
  (default 600 s). Prompts can embed a prerun script's stdout.

Delivery (`_deliver_result`, `scheduler.py:1308`) parses `deliver` strings like
`discord:<chat_id>` (or `local`/`origin`/`all`) and sends through the live platform adapter.
Output archives to `~/.hermes/cron/output/<job_id>/<timestamp>.md`. A `lifecycle_guard.py` rejects
job specs containing gateway-lifecycle commands (prevents self-restart loops, issue #30719).

**Live jobs (2)** (`~/.hermes/cron/jobs.json`) — down from 3 as of 2026-07-07 (see below):

| Job | Schedule | Kind | Runs | Delivers to |
|---|---|---|---|---|
| `stale-branches-report` | `0 3 * * *` | `no_agent` | `stale-branches.sh` (wrapper → `~/github/engels74-bot/gjc-fleet/pipeline/maintenance/stale-branches.sh`) | `#gjc-approvals` |
| `mover-status-issue-triage` | `0 9 * * 1` | agent (`web` toolset; per-job `model_snapshot` still `minimax/minimax-m3` — stale, predates the Codex switch) | prerun `issue-triage-fetch.sh` (wrapper → `~/github/engels74-bot/gjc-fleet/pipeline/intake/issue-triage-fetch.sh`) feeds a weekly issue digest | `#gjc-events` |

The two gjc-bot jobs' `~/.hermes/scripts/*.sh` entries are real-file wrappers (hermes rejects
symlinks for `--script`) that `exec` straight into the `gjc-fleet` monorepo's `pipeline/` subdir. **Verified live**
(both wrapper files read 2026-07-07): they previously `exec`'d the now-dead
`~/scripts/repo-bot/{stale-branches.sh,issue-triage-fetch.sh}` (that directory no longer exists)
and were broken at runtime; they now `exec` the paths in the table above, under the repo's
`maintenance/` and `intake/` pipeline-stage subfolders respectively, and both ran successfully on
their last tick (`last_status: "ok"` in `~/.hermes/cron/jobs.json` for both). A stale cron workdir
(`fleet/mover-status`) was also fixed this session via `hermes cron edit`.

~~The PR-115 monitor is unlike the other two: it was **self-scheduled by the agent** during the
EasyHDR RUSTSEC run…~~ **Removed 2026-07-07.** The third, self-scheduled
`monitor-easyhdr-pr115-rustsec` job (previously failing every tick on a hermes spend-drift guard
error after the Codex model switch — its `provider_snapshot`/`model_snapshot` were pinned to the
retired `custom`/`minimax/minimax-m3` combo) no longer appears in `~/.hermes/cron/jobs.json`,
confirmed live. This resolves the drift open question below and the "acceptable now that cron
carries three jobs" question on
[70-deployment-and-operations.md](70-deployment-and-operations.md#open-questions).

## Runtime & config (`~/.hermes`)

| Path | What it is |
|---|---|
| `config.yaml` (+ `.bak-discord-20260706-213503`, `.bak-yolo-20260706-*`) | Main config: model block (`gpt-5.5` / `openai-codex` since 2026-07-07; `providers.nanogpt` retained as revert stub), `discord:` block, `platform_toolsets`, `mcp_servers.gjc_coordinator` → `/home/cvps/.bun/bin/gjc mcp-serve coordinator`. Added 2026-07-06/07 (post-RUSTSEC-run tuning): `approvals.mode: "off"` + `approvals.cron_mode: approve` (full-auto, user-requested — dangerous-command prompts disabled; hardline blocklist still applies), `agent.max_turns: 300` (was 60; re-bridged into `HERMES_MAX_ITERATIONS` every turn, so config.yaml wins over .env), `terminal.cwd: ~/github/engels74-bot/fleet` (default terminal workdir — the `TERMINAL_CWD` env form is deprecated; NB the file defines `terminal:` **twice** — an early block with `cwd: .` and a later one with the fleet path; YAML last-key-wins makes the latter effective, but the duplicate is a footgun for future edits), `mcp_servers.gjc_coordinator.timeout: 1800` (per-tool-call; default 300 s was too short for delegated coding tasks) |
| `.env` (0600, ~23 KB) | Secrets by name: NanoGPT API key (now unused by the live model path), bot GitHub PAT (`GITHUB_TOKEN`), Discord bot token, `DISCORD_HOME_CHANNEL`, allowed users. **Also read by the gjc-bot shell scripts** (see [50-configuration-and-state.md](50-configuration-and-state.md)). Upstream now ships a pluggable **SecretSource** interface (`agent/secret_sources/`: registry + Bitwarden + 1Password `op://` sources, ordered via a `secrets.sources` config key; commits 2026-07-06/07) — **this deployment configures none of them**: no `secrets:` block in `config.yaml`, no `op://` refs in `.env`. Live custody = `.env` (bulk) + `auth.json` (provider credentials) |
| `SOUL.md` | Auto-injected agent voice/persona; rewritten during Discord unification to align with the design system's emoji lexicon. Extended 2026-07-06/07 with **Workspace conventions** (all repo work under `~/github/engels74-bot/fleet/`, never loose in `$HOME`; layout bullet added 2026-07-07 with the fleet/ move) and **Delegation to gajae-code** (code changes go through the coordinator MCP tools — the brain investigates/triages, gjc codes; includes PR-branch push safety: rebase before push, never force-push). Read from disk at prompt-build time, so new sessions pick changes up without a restart |
| `channel_directory.json` | Discovered Discord channels/threads for the guild |
| `discord_threads.json` | Auto-thread participation persistence |
| `gateway.pid`, `gateway.lock`, `gateway_state.json` | Gateway process state (`gateway_state: running`, `platforms.discord.state: connected`) |
| `gateway/` | Only Discord slash-command sync state + non-conversational message ids (most gateway state lives at the `~/.hermes` root, not here) |
| `kanban.db` (+locks), `kanban/` | Kanban store (see above) |
| `state.db` (+shm/wal, ~6.9 MB) | Session/message store (`hermes_state.py` schema) |
| `verification_evidence.db` | Evidence store |
| `cron/` | `jobs.json`, tick/jobs locks, `ticker_heartbeat`, `output/<job_id>/*.md` |
| `scripts/` | Cron exec-wrappers (must be real files — symlink targets are rejected) |
| `hermes-agent/` | The source checkout + venv the service runs from (`…/hermes-agent/venv/bin/python -m hermes_cli.main gateway run`) |
| `auth.json` (+ `auth.lock`) | **Credential pool for model/provider auth** — since the 2026-07-07 Codex switch this is the live auth path: `active_provider: openai-codex` (one OAuth entry, device-code sourced), plus `copilot` API-key entries sourced from `gh` CLI and `GITHUB_TOKEN` (fingerprints, not raw values). Structure: `version`, `providers`, `credential_pool`, `active_provider`, `suppressed_sources` |
| `.skills_prompt_snapshot.json`, `memories/`, `hooks/`, `sessions/`, `platforms/`, `sandboxes/`, `pairing/`, `bin/`, caches | Assorted agent state (hooks/ currently empty) |

## How it connects to the rest of the system

- **User → hermes:** Discord DM/@mention to GJC Brain (per-user sessions, auto-threads).
- **hermes → gjc:** via gjc's Coordinator MCP (`mcp_servers.gjc_coordinator` in `config.yaml`);
  live evidence: `bun …/gjc mcp-serve coordinator` runs as a child in the
  `hermes-gateway.service` cgroup. See [10-gajae-code.md](10-gajae-code.md#integration-surface-how-other-things-drive-gjc).
- **hermes → gjc-bot:** only via cron — the two gjc-bot jobs above shell out to
  `~/github/engels74-bot/gjc-fleet/pipeline/{maintenance/stale-branches.sh,intake/issue-triage-fetch.sh}`
  through real-file wrappers in `~/.hermes/scripts/`. (A third, self-scheduled PR-115 monitor job
  existed here at one point, self-contained and not touching gjc-bot scripts; removed 2026-07-07 —
  see [The cron subsystem](#the-cron-subsystem).)
- **hermes → Discord:** conversational replies as plain markdown via its own bot identity
  ("GJC Brain"). **Hermes traffic does not pass through gjc-relay** and never produces embeds —
  by design (see [35-gjc-relay.md](35-gjc-relay.md#scope--what-does-and-does-not-flow-through-it)).
- **hermes ← others:** nothing currently pushes into hermes programmatically — the webhook platform
  is disabled and no `issue-intake` subscription exists. Shared secrets custody: gjc-bot scripts
  grep `GITHUB_TOKEN`/`NANOGPT_API_KEY` out of `~/.hermes/.env` at runtime.
- Naming hazard: hermes has a native platform type called `relay` (`gateway/relay/`) that is
  **unrelated** to `gjc-relay`. See the glossary.

## Open questions

- Is the **kanban dispatcher** enabled in this deployment (`kanban.dispatch_in_gateway`), and is
  there any intent to route repo work through kanban instead of the shell pipeline?
- The gateway `relay/` transport ("fleet events via clawhip + the relay" per a config comment) —
  is any relay-platform ingestion actually configured here? No runtime evidence found.
- `verification_evidence.db` — schema/purpose not investigated.
- ~~`hermes gateway run --replace` vs recorded argv~~ **Resolved 2026-07-07:** the installed unit
  uses `python -m hermes_cli.main gateway run` with no `--replace`; the argv matches.
- The NanoGPT fair-use question is moot while the live provider is openai-codex; it becomes
  relevant again only if the `providers.nanogpt` revert stub is activated.
- What are the Codex-subscription rate/usage limits for `gpt-5.5` under this OAuth pool, and is
  there a fallback if the subscription hits caps? (New with the 2026-07-07 provider switch.)

## Changelog

- 2026-07-06 — Initial draft from source + live-runtime research (hermes-agent v0.18.0).
- 2026-07-07 — Config/SOUL.md additions from the EasyHDR RUSTSEC-run tuning documented (approvals
  off, max_turns 300, terminal.cwd, gjc_coordinator timeout 1800, workspace + delegation rules).
  Operational notes from that run: guild messages require a REAL @mention (pasted "@Name" text is
  not a mention — `DISCORD_REQUIRE_MENTION` defaults true); `gh` symlinked into `~/.local/bin` for
  the agent's PATH; per-turn iteration cap is `agent.max_turns` (the injected "maximum number of
  tool-calling iterations" message is this limit, not a stall).
- 2026-07-07 (later, ~13:00) — Verification pass against live `~/.hermes` state: model/provider
  switched to `gpt-5.5` via `openai-codex` (auth via the `auth.json` credential pool; nanogpt kept
  as revert stub); third cron job documented (`monitor-easyhdr-pr115-rustsec`, hourly,
  self-scheduled); upstream SecretSource/1Password architecture noted (unconfigured here);
  `auth.json` promoted to its own runtime-table row; ExecStart claim corrected (module form, no
  `--replace`) and that open question resolved; duplicate `terminal:` block footgun noted.
- 2026-07-07 (later still, ~19:15) — Re-verification pass after the gjc-bot-scripts reorg and the
  hermes cron-wrapper bugfix. Read both `~/.hermes/scripts/{stale-branches.sh,issue-triage-fetch.sh}`
  wrappers directly: confirmed they previously `exec`'d the now-dead `~/scripts/repo-bot/*` path and
  are now fixed to `exec` into `~/github/engels74-bot/gjc-bot-scripts/{maintenance,intake}/*.sh`;
  updated the cron table and the "hermes → gjc-bot" connection line accordingly. Re-confirmed
  against `~/.hermes/config.yaml`/`auth.json`/`SOUL.md`: model `gpt-5.5`/`openai-codex`,
  `agent.max_turns: 300`, `approvals.mode: "off"` + `cron_mode: approve`, `terminal.cwd`
  (duplicate-block behavior unchanged), `gjc_coordinator` command/timeout, and the credential-pool
  shape (one `openai-codex` OAuth entry + two `copilot` API-key entries sourced from `gh_cli` and
  `env:GITHUB_TOKEN`, fingerprints only) — all match verbatim. Fixed a stale `model_snapshot` value
  in the cron table (`minimax-m3` → the actual stored `minimax/minimax-m3`). **New drift found**:
  the `monitor-easyhdr-pr115-rustsec` job is now failing every tick with a hermes spend-drift guard
  error (job unpinned, created under the old `custom`/`minimax-m3` snapshot, global config now
  `openai-codex`/`gpt-5.5`) — documented under the cron table; PR #115 was still open/unmerged.
  Delivery channel names (`#gjc-approvals`, `#gjc-events`) cross-checked by name only against
  `~/.hermes/channel_directory.json` — no numeric IDs added to this page.
- 2026-07-07 (fleet/ move + component rename) — repo-bot → **gjc-bot** terminology.
  `terminal.cwd` and `GJC_COORDINATOR_MCP_WORKDIR_ROOTS` now point at
  `~/github/engels74-bot/fleet` (config backed up as `.bak-fleetmove-*`, gateway restarted,
  coordinator MCP env re-verified live); SOUL.md workspace conventions rewritten for the fleet/
  layout (Layout bullet, fleet-scoped clone/scratch/pipeline-ownership paths).
- 2026-07-07 (gjc-fleet monorepo + user-units migration) — Light-touch path sweep: the cron table
  and the "hermes → gjc-bot" wrapper description now cite
  `gjc-fleet/pipeline/{maintenance,intake}/*.sh` instead of the archived standalone
  `gjc-bot-scripts` repo. `hermes-gateway.service` itself is unaffected by the units migration —
  it remains generated by `hermes gateway install`, already user-scope; no gateway config changed.
  Separately (same session, hermes hygiene pass): the previously-drifting
  `monitor-easyhdr-pr115-rustsec` cron job has been **removed** from `~/.hermes/cron/jobs.json`
  (confirmed live) — cron table now shows 2 live jobs, not 3; the Purpose section and the
  hermes→gjc-bot connection bullet updated to match. A stale cron workdir (`fleet/mover-status`)
  was fixed via `hermes cron edit` in the same pass.
