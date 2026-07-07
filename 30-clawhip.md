<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/github/engels74/gjc/clawhip/ (ARCHITECTURE.md, README.md, SKILL.md, Cargo.toml, src/)
  - ~/.clawhip/config.toml, ~/.clawhip/clawhip.env (var names only)
  - /etc/systemd/system/clawhip.service (+ drop-in 10-gjc-relay.conf), issue-spool-adapter.{path,service,timer},
    gjc-dlq-watch.service, gjc-relay-alert.service, gjc-relay.service (live systemctl state)
  - ~/github/engels74-bot/gjc-bot-scripts/{intake,maintenance}/ (post-reorg layout)
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  The relay that sits in front of clawhip's Discord traffic has its own page: 35-gjc-relay.md.
-->

# clawhip

> Component page. For the loopback relay in front of its Discord traffic, see
> [35-gjc-relay.md](35-gjc-relay.md). For the index, see [README.md](README.md).

## Purpose

**clawhip** is a daemon-first, **event-to-Discord notification router** written in Rust
(upstream `github.com/Yeachan-Heo/clawhip`; checkout at `~/github/engels74/gjc/clawhip`).
Tagline: "Event-to-channel notification router for Discord — bypass gateway sessions, just events
in, messages out" (`Cargo.toml:5`). It gets commits, GitHub issue/PR activity, tmux keyword/stale
hits, and agent-lifecycle events into Discord channels **without running a Discord gateway/bot
session** — events in one side (CLI/HTTP/monitors), rendered messages out the other (Discord REST).

In this deployment clawhip is the **notification bus** of the whole fleet: it polls GitHub for six
repos, receives lifecycle events from the gjc-bot scripts, writes the issue spool that feeds the
automated pipeline, and posts everything to Discord as the "GJC Clawhip" bot identity.

**Version note:** the shipped `ARCHITECTURE.md:1` describes v0.4.0, but `Cargo.toml:3` is
**0.6.11** — the source has grown well past its own architecture doc (gajae/cron/hooks/telemetry/
slack modules are undocumented there). Prefer the source.

## Structure

Single binary `clawhip` (Cargo, edition 2024; axum 0.8 HTTP daemon, tokio, reqwest/rustls, clap).
Releases via `cargo-dist` (`dist-workspace.toml`). Installed here at `~/.cargo/bin/clawhip`.

`src/` modules:

| Area | Modules |
|---|---|
| Ingress/daemon | `main.rs`, `cli.rs` (clap subcommands), `daemon.rs` (axum server), `client.rs` |
| Event model | `event/{mod,body,compat}.rs`, `events.rs` (kinds + template rendering) |
| Sources (producers) | `source/{git,github,tmux,workspace}.rs` behind a `Source` trait; each polls and feeds a shared tokio mpsc queue |
| Pipeline | `dispatch.rs` (queue consumer) → `router.rs` (0..N deliveries per event) → `render/{mod,default}.rs` → `sink/{discord,local_file,slack}.rs` |
| Reliability | `core/{dlq,circuit_breaker,rate_limit,timer_wheel}.rs` |
| Discord transport | `discord.rs`, `discord_watch.rs` |
| Beyond the 0.4.0 doc | `gajae.rs` (exec gajae-code as an event handler), `cron.rs`, `memory.rs`, `hooks/`, `native_hooks.rs`, `telemetry.rs`, `provenance.rs`, `keyword_window.rs`, `tmux_wrapper.rs`, `lifecycle.rs`, `plugins.rs`, `monitor.rs`, … |

Other dirs: `integrations/` (git post-commit/post-checkout hooks, tmux keyword/stale scanners that
*produce* events), `plugins/` (`claude-code/`, `codex/` bridges), `skills/` (SKILL.md attachment
surfaces), `deploy/clawhip.service` (generic template — the live unit differs), `geobench/`.

## Entry points

- `clawhip start` — the daemon (this is what `clawhip.service` runs).
- Producer CLI (each POSTs to the daemon): `clawhip send`, `clawhip emit <kind>`,
  `clawhip github issue-opened|pr-status-changed`, `clawhip git commit`,
  `clawhip tmux keyword|stale|new|watch`, and `clawhip agent started|finished|failed|blocked`
  (`SKILL.md:49-64`).
- HTTP daemon on `127.0.0.1:25294` (`~/.clawhip/config.toml`, `[daemon]`): `POST /event`,
  `/api/event`, `/events`, `/native/hook`, `/api/native/hook`, `/api/tmux/register`, `/github`;
  `GET /health`, `/api/status`, `/api/tmux`; plus an update-management surface not previously
  documented here: `GET /api/update/status`, `POST /api/update/approve`, `POST
  /api/update/dismiss` (`src/daemon.rs:146-159`, re-verified live — the router table also has an
  `/api/native/hook` alias alongside `/native/hook` that this page previously omitted).

**Event-kind gotcha (load-bearing):** `clawhip agent started|finished|...` emits canonical
**`session.*`** events, not `agent.*` — an `agent.*` route will never match. The live config keys
lifecycle routes on `session.started/finished/failed/blocked` while the *rendered* embeds present
`kind=agent.*` via templates (`~/.clawhip/config.toml:53-57` comments; confirmed in `src/events.rs`).

## Event pipeline

```
CLI producers ─┐
HTTP POSTs  ───┼──► mpsc queue ──► Dispatcher ──► Router (0..N routes) ──► Renderer ──► Sink
git/github/tmux│                                   (config [[routes]])    (compact/    (discord │
monitor sources┘                                                           alert/…)     localfile │ slack)
```

- Routing: every matching route fires (there is **no catch-all `*` route**, and adding one would
  double-post — per-repo routing is done via each monitor's `channel` field, not a `github.*` route).
- Batching: `[dispatch] ci_batch_window_secs=30`, `routine_batch_window_secs=5`.
- Event taxonomy actually emitted (grep of `src`): `git.commit`, `git.branch-changed`,
  `github.issue-opened|issue-commented|issue-closed`, `github.pr-status-changed`,
  `github.ci-{started,passed,failed,cancelled}`, `github.release-*`, `session.*` (started/finished/
  failed/blocked/idle/stale/pr-created/…), `tmux.{keyword,stale}`, `custom`.

### DLQ ("bury") semantics — the load-bearing fragility

`core/dlq.rs:22-37`: the DLQ is a **plain in-memory `Vec<DlqEntry>`** — no persistence, no
redelivery. clawhip retries **only** on HTTP 429 (honoring `retry_after`, up to
`MAX_ATTEMPTS = 3`, `src/discord.rs:19,180-195`); once retries are exhausted (or the error carries
no `retry_after`) it calls `record_dlq` (`discord.rs:433-470`), which logs
`clawhip dlq bury: {json}` to stderr (`discord.rs:462-463`) and pushes the entry into the
in-process `Dlq` — the notification is **permanently lost** (and lost on restart, since the DLQ has
no on-disk backing). The entire 4-unit systemd supervision stack around the relay (infinite
restart, ordering drop-in, two out-of-band alarms — see [35-gjc-relay.md](35-gjc-relay.md)) exists
to compensate for this. Of the two alarms, `gjc-dlq-watch` is the operative one (confirmed live:
`ActiveState=active`/`running`); `gjc-relay-alert` rarely fires by design (confirmed live:
`ActiveState=inactive`/`dead` — the relay's infinite-restart policy means it never reaches the
`failed` state).

### The issue spool (producer side)

A live route sends `github.issue-opened` to the **localfile sink**:

```toml
# ~/.clawhip/config.toml:29-33
[[routes]] event = "github.issue-opened"  sink = "localfile"
local_path = "/home/cvps/.repo-bot/issue-spool.jsonl"  format = "compact"
```

`src/sink/local_file.rs:75-81` appends one JSON object per line:
`{"event_kind", "format", "content" (≤240 chars), "summary_payload": {repo_name, prompt, summary, …}}`
with whitelisted fields (`summarize_payload`, `local_file.rs:38-56`) and UTF-8-safe truncation.
`format=compact` is deliberate so `<repo>#<number> opened: <title>` leads the content and survives
truncation for the downstream parser (`issue-spool-adapter.sh` — see
[40-gjc-bot-automation.md](40-gjc-bot-automation.md#issue-spool-adaptersh)).

**Consumer side, verified live:** the spool path `/home/cvps/.repo-bot/issue-spool.jsonl` is watched
by a systemd **path unit**, `issue-spool-adapter.path` (`PathModified=`, `Unit=issue-spool-adapter.service`,
`WantedBy=paths.target`; live state `enabled`/`active`/`waiting`). Every append triggers the
`issue-spool-adapter.service` oneshot, whose `ExecStart=` now points at
`/home/cvps/github/engels74-bot/gjc-bot-scripts/intake/issue-spool-adapter.sh` (updated from the
dead `~/scripts/repo-bot/` path as part of the same reorg as the hermes cron wrappers — see
[20-hermes-agent.md](20-hermes-agent.md#the-cron-subsystem)). A companion
`issue-spool-adapter.timer` provides a backup retry pass. The adapter re-reads the whole spool and
dedups via its own ledger, so a coalesced or missed path-unit trigger is self-correcting.

**Correction (2026-07-07):** this page originally claimed the spool dispatch was "in addition to
the per-repo Discord monitor channel, so the human notice still appears" — that was **wrong**.
Router semantics (`src/router.rs resolve()`): any matched route suppresses the monitor-channel
fallback, so the localfile route silently swallowed the per-repo `issue-opened` Discord notice —
journal evidence showed issue-opened events delivering to `localfile:` only. Fixed by adding an
explicit Discord route for `github.issue-opened` (both routes now match → both deliveries fire).

## Runtime & config (`~/.clawhip`)

Files (0600): `config.toml` (live, ~7.4 KB), `clawhip.env`, plus dated `.bak-*` snapshots that
record the 2026-07-06/07 reconfiguration waves (`phaseg` → `g7` → `discord` → `embedbatch`; see
[90-glossary-and-open-questions.md](90-glossary-and-open-questions.md) for the wave timeline).

`config.toml` sections:

- `[dispatch]` — batching windows.
- `[daemon]` — `bind_host=127.0.0.1`, `port=25294`, `base_url`.
- `[defaults]` — default `channel` (`#gjc-events`), `format="compact"`.
- `[[routes]]` — the wiring: lifecycle `session.*` routes → Discord with `GJCEMBED1` templates,
  `agent.approval-requested` → `#gjc-approvals`, the issue-spool localfile route, a `gjc.canary`
  route (test channel `#gjc-lab`). Added 2026-07-07: `GJCEMBED1` Discord routes for
  `github.issue-opened/-closed/-commented` and `github.ci-passed/-failed/-started/-cancelled` —
  these kinds previously fell back to plain compact text (or, for issue-opened, were swallowed by
  the localfile route — see the correction above). These routes deliberately carry **no `channel`**
  so target resolution (`route.channel > event.channel > default`) preserves each monitor's
  per-repo channel.
- `[monitors]` — `poll_interval_secs=60`, `github_api_base`; `[monitors.tmux] sessions=[]` (tmux
  watching currently off).
- `[[monitors.git.repos]]` × 6 — one block per monitored repo (`mover-status`, `easyhdr`,
  `obzorarr`, `otpravkarr`, `perevoditarr`, `zondarr`, all under `~/github/engels74-bot/fleet/`), each
  with `emit_issue_opened=true`, `emit_pr_status=true`, commits/branch-changes off, and a dedicated
  per-repo Discord channel.

`clawhip.env` variable names (values not documented here): `CLAWHIP_GITHUB_TOKEN`,
`CLAWHIP_DISCORD_BOT_TOKEN`, and `CLAWHIP_DISCORD_API_BASE` — the last one is the single global
switch that puts **gjc-relay** in-path (`http://127.0.0.1:25295/api/v10`; consumed at
`src/discord.rs:77-78`, default `https://discord.com/api/v10`). Caveat: webhook-URL sends use a
separate HTTP client that does **not** honor the api-base (`discord.rs:79`) — only bot-token
channel sends traverse the relay. The live config uses channel sends exclusively.

Config comments cite exact clawhip source line numbers (the `session.*` mismatch, the 240-char
truncation) — they were authored from the Discord-unification research and are themselves useful
documentation.

## How it connects to the rest of the system

**Inbound (event producers):**
- Its own git/GitHub monitor sources (the 6 repos).
- gjc-bot scripts: `gjc-run.sh`/`review-run.sh` (`clawhip agent <state>` narration),
  `issue-spool-adapter.sh`/`merge-gate.sh` (via `lib/discord-embed.sh` → `clawhip send`).
- In-repo `integrations/` git/tmux hooks and `plugins/{claude-code,codex}/bridge.sh` (available,
  not centrally configured here).

**Outbound:**
- Discord REST (bot token) — all channel sends routed through **gjc-relay** on loopback :25295,
  which turns `GJCEMBED1 …` envelopes into rich embeds ([35-gjc-relay.md](35-gjc-relay.md)).
- The localfile issue spool → gjc-bot's intake ([40-gjc-bot-automation.md](40-gjc-bot-automation.md)).

**Non-connections worth stating:**
- **hermes and clawhip are siblings**, not a pipeline: hermes' chat replies go out via its own bot
  identity and do *not* traverse clawhip or the relay; neither consumes the other's events. They
  are unified only by shared *style* (SOUL.md voice + the same emoji taxonomy).
- clawhip has a first-class **gajae handler** seam (`src/daemon.rs:637,714-745`, `src/gajae.rs`)
  that can exec the gajae-code binary in response to an event — present in code, **not configured
  live** (no `gajae` route action in `config.toml`).

## Live service

`clawhip.service` (system-level): `ExecStart=/home/cvps/.cargo/bin/clawhip start`, `User=cvps`,
`Environment=CLAWHIP_CONFIG=/home/cvps/.clawhip/config.toml`, `EnvironmentFile=~/.clawhip/clawhip.env`,
`Restart=always`. Drop-in `clawhip.service.d/10-gjc-relay.conf` adds `After=`/`Wants=gjc-relay.service`
so the relay is up before clawhip sends. Note the in-repo `deploy/clawhip.service` template does
**not** match the live unit.

## Open questions

- Is any `slack` sink route live anywhere? (Code exists; live config shows none.)
- Are the in-repo `integrations/` git/tmux hooks installed in any repo on this machine? (The tmux
  monitor list is empty and `gjc-reap.sh`'s claimed `tmux.stale` trigger route doesn't exist — see
  [40-gjc-bot-automation.md](40-gjc-bot-automation.md#discrepancies).)
- Will the `gajae` handler seam be wired up (route action → exec gjc), or does invocation stay with
  gjc-bot?
- Upstream `ARCHITECTURE.md` is two minor versions stale — worth an upstream refresh or a local
  addendum.

## Changelog

- 2026-07-06 — Initial draft from source + live-runtime research (clawhip 0.6.11).
- 2026-07-07 — Issue/CI embed routes added to config (see Runtime & config); corrected the false
  "human notice still appears" claim about the issue-spool route (see The issue spool). Backups:
  `config.toml.bak-embedbatch-20260707-*`.
- 2026-07-07 (later) — Verification pass: config.toml size refreshed (5.4→~7.4 KB after the
  embedbatch routes); wave list extended with `embedbatch`; alarm nuance added (dlq-watch operative,
  relay-alert rarely fires). Version 0.6.11, routes, monitors, DLQ semantics all re-verified live.
- 2026-07-07 (later still, ~19:30) — Re-verification pass after the `gjc-bot-scripts` reorg. No
  in-repo clawhip source/docs reference the old `~/scripts/repo-bot` path (grepped `src/`,
  `SKILL.md`, `README.md` — clean), so no path fixes were needed inside this page's clawhip-source
  claims. Added the previously-undocumented consumer side of the issue spool: the live
  `issue-spool-adapter.path` systemd path unit (`PathModified=/home/cvps/.repo-bot/issue-spool.jsonl`)
  that triggers `issue-spool-adapter.service`, whose `ExecStart=` now correctly points at
  `.../gjc-bot-scripts/intake/issue-spool-adapter.sh` (confirmed via `systemctl cat`, live and
  `enabled`/`active`/`waiting`). Tightened the DLQ/`discord.rs` line citations (retry loop, `MAX_ATTEMPTS
  = 3`, `record_dlq`, the `eprintln!`) and confirmed `gjc-dlq-watch`/`gjc-relay-alert` live states via
  `systemctl show`. Found and fixed an incomplete HTTP-surface list on `src/daemon.rs`: this page was
  missing the `/api/native/hook` alias and the `/api/update/{status,approve,dismiss}` endpoints — added.
  Cross-checked `clawhip.service` live unit (`ExecStart`, `EnvironmentFiles`, `Restart=always`,
  drop-in) — matches. No numeric Discord IDs added; route channel targets are named only
  (cross-checked against `~/.hermes/channel_directory.json` and `config.toml`'s own channel IDs,
  which are not reproduced here).
- 2026-07-07 (fleet/ move + component rename) — repo-bot → **gjc-bot** terminology; the six
  `[[monitors.git.repos]] path` entries now point at `~/github/engels74-bot/fleet/<repo>`
  (config backed up as `.bak-fleetmove-*`, daemon restarted, polling re-verified live).
