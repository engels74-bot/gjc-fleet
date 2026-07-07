<!--
status: draft            # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/github/engels74/gjc/gajae-code/README.md
  - ~/github/engels74/gjc/gajae-code/AGENTS.md
  - ~/github/engels74/gjc/gajae-code/docs/ (codebase-overview, rpc, external-control-readiness, hermes-mcp-bridge, bot-integration, notifications-sdk, standalone-mcp)
  - ~/github/engels74/gjc/gajae-code/packages/coding-agent/src/ (cli.ts, main.ts, cli/args.ts)
  - ~/.gjc/
  - ~/github/engels74-bot/gjc-bot-scripts/run/gjc-run.sh
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  Line-number citations were verified 2026-07-06 and will drift as the repo moves.
-->

# gajae-code (`gjc`)

> Component page. For how a job flows through the whole system, see
> [60-data-flow-and-integration.md](60-data-flow-and-integration.md). For the index, see [README.md](README.md).

## Purpose

**gajae-code** is a standalone **coding-agent runner/harness**: an autonomous coding agent you point
at a repo (or an isolated git worktree) that runs interviews, reviewed plans, tmux-native execution,
and durable verification. Tagline: "Encode intention. Decode software."
(`~/github/engels74/gjc/gajae-code/README.md:11-14`). It is explicitly beta/experimental
(`README.md:27`). Workspace version 0.9.0, author Yeachan-Heo (`Cargo.toml:7-12`).

The `gjc` binary is the product. It deliberately exposes a small fixed public surface: four workflow
skills (`deep-interview`, `ralplan`, `ultragoal`, `team`) and four role subagents (`executor`,
`architect`, `planner`, `critic`) (`AGENTS.md:7-24`).

Naming: "gajae" is Korean 가재 (crayfish), matching the crustacean TUI identity (`red-claw` dark
theme, `blue-crab` light theme). **`gjc` = the gajae-code CLI binary.**

**Lineage.** `NOTICE.md:5` (of 8 lines) credits upstream `can1357/oh-my-pi` as "the upstream red-claw lineage
and implementation DNA". gajae-code is a rebrand-in-progress of oh-my-pi — hence pervasive `pi-*`
naming (`pi-natives`, `pi-shell`, `PI_ROOT`) and stale `can1357/...` URLs in a few places. Rebrand
enforcement gates exist in CI (`scripts/rebrand-inventory.ts`, `scripts/verify-g002-gates.ts`).

**robogjc** is a *separate deliverable inside this repo* (`python/robogjc/`, `Dockerfile.robogjc`):
a self-hosted GitHub triage-and-fix bot that drives `gjc --mode rpc` as a subprocess against
per-issue worktrees (`python/robogjc/README.md:1-30`). **robogjc is not deployed on this machine** —
the live issue→PR lane is the shell pipeline in [40-gjc-bot-automation.md](40-gjc-bot-automation.md),
which calls `gjc -p` directly. See the glossary entry in
[90-glossary-and-open-questions.md](90-glossary-and-open-questions.md).

## Structure

Two build systems in one monorepo:

- **Cargo workspace** (`Cargo.toml`, `members = ["crates/*"]`, resolver 3, Rust edition 2024).
- **Bun/TypeScript monorepo** (`package.json` + `bun.lock`; Biome for lint/format; type-checks via
  `bun run check:ts`, never `tsc`).

### Rust crates (`crates/`)

| Crate | Role |
|---|---|
| `pi-natives` | The single native N-API addon (`cdylib`): clipboard, grep/glob, fs scan/cache, syntax highlighting, HTML→Markdown, SIXEL, PTY/shell/process, token counting, ANSI text measurement (`crates/pi-natives/src/lib.rs:1-13`) |
| `pi-shell` | brush-based shell execution primitives (persistent + one-shot, streaming, cancellation, bash AST fixups) |
| `pi-ast` | Tree-sitter-style AST search/edit support |
| `pi-iso` | Cross-platform isolation PAL — overlayfs/fuse-overlayfs (Linux), `clonefile` (macOS), ProjFS (Windows), `git worktree` fallback; the copy-on-write engine behind `--worktree` (`crates/pi-iso/src/lib.rs:1-13`) |
| `gjc-notifications` | Transport-agnostic notifications SDK core: JSON protocol, action lifecycle, loopback WS server, discovery file (`crates/gjc-notifications/src/lib.rs:1-9`) |
| `git-daemon` | Autonomous per-repo service that resolves referenced work items by opening reviewed PRs (`docs/git-daemon.md`) — excluded from the workspace |
| `brush-core-vendored`, `brush-builtins-vendored` | Vendored fork of the `brush` POSIX shell, patched in via `[patch.crates-io]`; excluded from workspace members |

Quirk: release profile uses `panic = "abort"`, but `ci`/`local` profiles override to `unwind`
specifically to keep the `pi-natives` `catch_unwind` N-API guard effective (`Cargo.toml:26-40`).

### TypeScript packages (`packages/`)

| Package | Role |
|---|---|
| `coding-agent` (`@gajae-code/coding-agent`) | The main `gjc` CLI and product runtime: `cli.ts`, `main.ts`, `sdk.ts`, tools, coordinator/MCP |
| `ai` | Provider/model boundary: model registry/resolution, provider impls, auth broker/storage, streaming, retry, OAuth |
| `agent` (`@gajae-code/agent-core`) | Stateful agent runtime and turn loop (context transform → model stream → tool exec → lifecycle events); compaction, telemetry |
| `tui` | Differential-rendering terminal UI framework |
| `natives` + 5 per-platform packages | JS loader resolving the platform-specific compiled `pi-natives` addon |
| `utils` | Shared TS utilities (incl. process-tree helpers) |
| `stats` | Local observability dashboard (`gjc-stats` bin; SQLite + SPA server) |
| `bridge-client` | TS client SDK for the bridge protocol |
| `gajae-code` | Thin npm install wrapper for the `gjc` CLI |

### Python (`python/`)

- `gjc-rpc` — typed Python client for `gjc --mode rpc` (event listeners, host-owned tools,
  host-owned URI schemes) (`python/gjc-rpc/`).
- `robogjc` — the GitHub bot consuming `gjc-rpc` (FastAPI + sqlite queue + WorkerPool); all GitHub
  writes go through host-owned tools with audited, redacted logging
  (`python/robogjc/src/worker.py:350-532`). Not deployed here.

### Other

`plugins/` (generated Claude Code + Codex delegation plugins wiring the coordinator MCP),
`schemas/` (`config.schema.json`, `models.schema.json`), `geobench/gajae-code.yaml`,
`scripts/` (build/CI/release/rebrand gates), `docs/` (73 architecture docs — the best entry point
is `docs/codebase-overview.md`).

## Entry points

Bin `gjc` → `packages/coding-agent/bin/gjc.js` (4-line shim, declared in
`packages/coding-agent/package.json:39-41`) → `runCli()` in `packages/coding-agent/src/cli.ts:242-287`.

Routing rule (`isSubcommand()` at `cli.ts:206-208`, dispatch at `cli.ts:278-286`): if `argv[0]` is a
known subcommand it dispatches there; otherwise the whole argv is prefixed with `launch` — the
default root agent command.

Registered subcommands (`cli.ts:25-58`): `launch` (implicit default), `state`, `setup`, `acp`,
`skills`, `session`, `harness`, `coordinator`, `team`, `ultragoal`, `gc`, `ralplan`, `config`,
`stats`, `notify`, `daemon`, `web-search` (alias `q`), `local-provider`, `mcp-serve`, `mcp`,
`contribute-pr`, `deep-interview`, `migrate`, `rlm`, `update`, `plugin`, `completion`, plus the
internal `codex-native-hook`. Fast paths: `--smoke-test` (`cli.ts:247`), `--version`, `--help`.

### Run modes

`--mode {text|json|rpc|acp|rpc-ui|bridge}` is parsed in `src/cli/args.ts:100-111`; dispatch is in
`src/main.ts:748-1127`:

| Mode | Selected by | What it is |
|---|---|---|
| Interactive TUI | no `--print`, no piped stdin, no `--mode` | Default human mode |
| Print/headless | `-p/--print`, piped stdin, or `--mode text|json` | Single-shot: prompt in, output out, exit (`src/modes/print-mode.ts`). `json` = full NDJSON event stream |
| `rpc` | `--mode rpc` | JSONL-over-stdio machine protocol (see below) |
| `rpc-ui` | `--mode rpc-ui` | RPC with tool-UI context wired |
| `acp` | `--mode acp` or `gjc acp` | Agent Client Protocol server over stdio (editors, e.g. Zed) |
| `bridge` | `--mode bridge` | Experimental fail-closed HTTPS control surface (default port 4077, TLS + bearer required; `docs/bridge.md`) |

### Automation-relevant flags (all parsed in `src/cli/args.ts:70-216`)

- Headless: `-p/--print`; `--mode json` for the event stream (there is **no** separate
  `--output-format` flag).
- Sessions: `-c/--continue`, `-r/--resume [id|path]` (alias `--session`), `--fork`,
  `--session-dir <dir>`, `--no-session`.
- Isolation: `--worktree [name]` / `-w` — chdirs into a sibling
  `<repo>.gajae-code-worktrees/<slug>` worktree (`src/gjc-runtime/launch-worktree.ts:180-221`).
  `--tmux` launches inside a fresh tmux session.
- Models/capabilities: `--model`, `--smol`, `--slow`, `--plan`, `--thinking {ultra|high|medium|low}`,
  `--tools <csv>`, `--no-tools`, `--no-pty`, `--system-prompt`, `--append-system-prompt`.
- Input: `@path` args attach files/images (`src/cli/file-processor.ts:29-123`); piped stdin is
  prepended to the prompt (`src/cli/initial-message.ts:20-58`). `@file` args are rejected in
  rpc/bridge modes.

Exit codes: 0 success (RPC also exits 0 on stdin close, `docs/rpc.md:29`); 1 generic failure;
**2 = context-overflow** in non-interactive text mode (`src/modes/print-mode.ts:45,125-140`).

## Integration surface (how other things drive gjc)

`docs/external-control-readiness.md:7-12` is the authoritative readiness matrix. Five surfaces:

1. **Coordinator MCP** (preferred multi-session control plane) — `gjc mcp-serve coordinator`
   exposes an outward MCP server (`gjc-coordinator-mcp`); contract in
   `packages/coding-agent/src/coordinator/contract.ts`, server in `src/coordinator-mcp/server.ts`.
   Tools: `gjc_coordinator_{list_sessions,start_session,register_session,send_prompt,read_turn,
   await_turn,list_questions,submit_question_answer,report_status,list_artifacts,read_artifact,
   watch_events}` plus high-level `gjc_delegate_{plan,execute,team}`
   (`docs/hermes-mcp-bridge.md:114-144`). Fail-closed: mutations require both a startup opt-in
   (`GJC_COORDINATOR_MCP_MUTATIONS`) and per-call `allow_mutation:true`; workdirs are allowlisted via
   `GJC_COORDINATOR_MCP_WORKDIR_ROOTS`. `gjc mcp-serve hermes` is a compatibility alias.
   **This is how hermes drives gjc on this machine** — `~/.hermes/config.yaml` registers
   `mcp_servers.gjc_coordinator` shelling to `/home/cvps/.bun/bin/gjc mcp-serve coordinator`, and
   the live gateway cgroup shows that child process (see
   [20-hermes-agent.md](20-hermes-agent.md#how-it-connects-to-the-rest-of-the-system)).
2. **RPC stdio** (stable single-subprocess worker surface) — `gjc --mode rpc`, newline-delimited
   JSON over stdio (not JSON-RPC; `docs/rpc.md:1-31`). Emits `{"type":"ready"}` then accepts
   commands (`prompt`, `steer`, `abort`, `get_state`, `set_todos`, `set_host_tools`, `bash`,
   session ops, …) and streams canonical `event` frames. Distinctive concepts: **host-owned tools**
   (controller registers tools; gjc calls back out via `host_tool_call` — credentials stay with the
   host), **host URI schemes**, **workflow gates** (human-gated moments become machine-answerable
   frames), and fail-closed **unattended mode** (`negotiate_unattended` with budget/scopes).
   Reference client: `python/gjc-rpc`.
3. **ACP** — `gjc acp` / `--mode acp` for editor/ACP clients.
4. **Bridge HTTPS** — experimental, fail-closed by default; only `/healthz`, `/v1/help`,
   `/v1/handshake` respond; everything else returns `403 endpoint_disabled` (`docs/bridge.md:7-34`).
5. **Notifications SDK** — every session with notifications enabled exposes a loopback WebSocket;
   discovery file at `<repo>/.gjc/state/notifications/<sessionId>.json` (contains a per-session
   token — never log it). Protocol: `action_needed` / `reply` (first valid reply wins). Bundled
   Telegram/Discord/Slack daemons are reference clients (`docs/notifications-sdk.md`).

**MCP consumption (gjc as client):** gjc does *not* inherit other tools' `.mcp.json`; explicit
registration only via `gjc mcp add`, persisted to `~/.gjc/agent/mcp.json` (or `./.gjc/mcp.json`
with `--project`) (`docs/standalone-mcp.md:9-18`).

## Runtime & config (`~/.gjc`)

Home resolved as `GJC_CONFIG_DIR ?? PI_CONFIG_DIR ?? ~/.gjc` (`packages/utils/src/dirs.ts:23,146`).
Live contents on this machine:

| Path | What it is |
|---|---|
| `~/.gjc/agent/config.yml` | User config: `modelProfile.default: codex-pro`, model roles, task agent-model overrides — this install is configured against Codex/OpenAI-style providers by default |
| `~/.gjc/agent/mcp.json` | External MCP servers gjc consumes: `exa` (via `npx exa-mcp-server`, needs `EXA_API_KEY`) and `codebase-retrieval` (`~/.bun/bin/auggie --mcp --mcp-auto-workspace`). Its `$schema` URL still points at the stale `can1357/gajae-code` |
| `~/.gjc/agent/agent.db` (+wal/shm) | SQLite: `auth_credentials`, `cache`, `model_usage`, `settings` (auth material lives here — not inspected) |
| `~/.gjc/agent/history.db` | Prompt/command history with FTS5 |
| `~/.gjc/agent/models.db` | Remote model discovery cache |
| `~/.gjc/agent/sessions/` | One dir per workspace, keyed by absolute workspace path (slashes→dashes), each holding timestamped `<ISO>_<uuid>.jsonl` transcripts + `resident-cache/`. Live entries include gjc-bot run worktrees (e.g. `-github-engels74-bot-fleet-mover-status.gajae-code-worktrees-run-…`; entries from before the 2026-07-07 fleet/ move keep the old un-nested key) |
| `~/.gjc/agent/terminal-sessions/` | Per-terminal state (`pts-2`, `tmux-%0`, …) for `--tmux` pane ownership |
| `~/.gjc/logs/` | Daily JSONL logs (`gjc.YYYY-MM-DD.log`) + a hidden audit file hashing rotated logs |
| `~/.gjc/gpu_cache.json` | Cached GPU identity string, used for image/render-protocol decisions > [inferred] — no direct source reference located |
| `~/.gjc/star-reminder.json` | `{declined, starred, starredCheckedAt}` state for the "star the repo" launch gate (`src/reminders/star-reminder`, via `modes/interactive-mode.ts:61-62`) |

Per-repo state also exists under each workspace's `.gjc/` dir (git-ignored), e.g.
`.gjc/state/notifications/` and `.gjc/state/coordinator-mcp/` (coordinator event journal
`events/event-journal.jsonl`).

## How it connects to the rest of the system

- **hermes → gjc:** the hermes gateway registers gjc's **Coordinator MCP** as `gjc_coordinator`
  (`~/.hermes/config.yaml`); the coordinator runs as a child process of `hermes-gateway.service`.
  This is the interactive "GJC Brain drives gjc" lane.
- **gjc-bot → gjc:** the automated issue→PR lane runs `timeout 1800 gjc -p --no-pty "@<promptfile>"`
  inside a unique per-run worktree
  (`~/github/engels74-bot/gjc-bot-scripts/run/gjc-run.sh:130`). See
  [40-gjc-bot-automation.md](40-gjc-bot-automation.md).
- **gjc → GitHub:** in the automated lane, gjc itself commits, pushes, and opens the PR as
  `engels74-bot` (per the generated prompt file written in `gjc-run.sh:103-110`).
- **gjc → Discord:** none directly. Its visible activity is narrated by gjc-bot scripts through
  clawhip → gjc-relay (see [35-gjc-relay.md](35-gjc-relay.md)).
- **clawhip → gjc:** clawhip has a first-class "gajae handler" seam (`clawhip/src/daemon.rs:637,714-745`,
  `src/gajae.rs`) that can exec the gjc binary to handle an event — **not configured live**
  (no `gajae` route in `~/.clawhip/config.toml`).

## Open questions

- **`gpu_cache.json` consumer** — no source reference surfaced in `packages/coding-agent`,
  `packages/tui`, or `crates/`. Resolve by grepping `packages/natives` and the SIXEL/image-protocol
  code for the GPU string.
- **`harness`, `gc`, `migrate`, `local-provider`, `codex-native-hook` subcommands** — registered in
  `cli.ts:25-58` but their handlers were not read; exact behavior unconfirmed.
- **Session-resolution `missing_for_write` errors** in `~/.gjc/logs/gjc.2026-07-06.log` coincide
  with bot runs; benign-vs-bug status unknown (correlate log `pid` with a specific run).
- **Bridge/ACP production readiness** — summarized from `docs/external-control-readiness.md`;
  a full read of `docs/bridge.md` + `src/modes/acp/` would confirm supported clients.
- Known upstream RPC gaps are tracked in-repo under `issues/` (e.g. `06`–`13`, `19`: session
  registry, head-of-line blocking, detached sessions).

## Changelog

- 2026-07-06 — Initial draft from source + live-runtime research (repo at workspace version 0.8.2).
- 2026-07-07 — Verification pass: repo unmoved (HEAD `e78a33a4`, v0.8.2; installed `gjc/0.8.2`
  matches), monorepo/CLI/control-surface claims re-verified — no drift. Added the
  `--mcp-auto-workspace` flag to the `auggie` invocation in the mcp.json row.
- 2026-07-07 (later) — Re-verification pass following the `gjc-architecture` repo move and the
  `gjc-bot` → `gjc-bot-scripts` reorg. Repo advanced to HEAD `faf917e0` / workspace v0.9.0
  (installed `gjc/0.9.0` matches; was v0.8.2 at the prior pass). Fixed the DEAD
  `~/scripts/repo-bot/gjc-run.sh:128` citation: the script now lives at
  `~/github/engels74-bot/gjc-bot-scripts/run/gjc-run.sh`, and the `timeout 1800 gjc -p --no-pty`
  invocation re-anchored to line 130 (prompt-file write block re-anchored to lines 103-110) against
  the current file. Re-checked and corrected several `cli.ts` line citations that drifted with the
  version bump: `runCli()` 227-261→242-287, routing rule 191-194,253-259→206-208 (`isSubcommand()`)
  and 278-286 (dispatch), `--smoke-test` fast path 232-235→247. Corrected the beta/experimental
  banner citation `README.md:31`→`27` and the `NOTICE.md` lineage citation `1-9`→`5` (file is 8
  lines total). Corrected the `docs/` count from the stale "~90" to the actual 73 files. Verified
  the worktree-example path in the `~/.gjc` runtime table (`…mover-status.gajae-code-worktrees-run-…`)
  still matches a live entry under `~/.gjc/agent/sessions/` — no change needed. AGENTS.md's
  four-skills/four-subagents claim (`AGENTS.md:7-24`) and the run-mode/flag tables re-verified
  against current source — no drift found there.
- 2026-07-07 (fleet/ move + component rename) — repo-bot → **gjc-bot** terminology; the
  sessions-table workspace-key example updated to the new `~/github/engels74-bot/fleet/` clone
  root (entries from before the move keep the old un-nested key).
