<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-09
sources:
  - ~/github/engels74/gjc/clawhip/ (ARCHITECTURE.md, README.md, SKILL.md, Cargo.toml, src/)
  - ~/.clawhip/config.toml, ~/.clawhip/clawhip.env (var names only)
  - ~/.config/systemd/user/clawhip.service (+ drop-in 10-gjc-relay.conf), issue-spool-adapter.{path,service,timer},
    gjc-dlq-watch.service, gjc-relay-alert.service, gjc-relay.service (live `systemctl --user` state)
  - ~/github/engels74-bot/gjc-fleet/pipeline/{intake,maintenance}/, ~/github/engels74-bot/gjc-fleet/render/
  - ~/.config/gjc-fleet/fleet.toml (host-local values; not read for this page's content)
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; Changelog is a single current-state
  rebaseline entry — rewrite this page to current state rather than appending; prior history
  lives in git. The relay that sits in front of clawhip's Discord traffic has its own page:
  35-gjc-relay.md.
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
local_path = "/home/cvps/.gjc-bot/issue-spool.jsonl"  format = "compact"
```

`src/sink/local_file.rs:75-81` appends one JSON object per line:
`{"event_kind", "format", "content" (≤240 chars), "summary_payload": {repo_name, prompt, summary, …}}`
with whitelisted fields (`summarize_payload`, `local_file.rs:38-56`) and UTF-8-safe truncation.
`format=compact` is deliberate so `<repo>#<number> opened: <title>` leads the content and survives
truncation for the downstream parser (`issue-spool-adapter.sh` — see
[40-gjc-bot-automation.md](40-gjc-bot-automation.md#intakeissue-spool-adaptersh)).

**Consumer side, verified live:** the spool path `/home/cvps/.gjc-bot/issue-spool.jsonl` is watched
by a **user-scope** systemd **path unit**, `issue-spool-adapter.path` (`PathModified=`,
`Unit=issue-spool-adapter.service`, `WantedBy=paths.target`; live state `enabled`/`active`/`waiting`
under `systemctl --user`). Every append triggers the `issue-spool-adapter.service` oneshot, whose
`ExecStart=` now points at
`/home/cvps/github/engels74-bot/gjc-fleet/pipeline/intake/issue-spool-adapter.sh` (the pipeline
moved into the `gjc-fleet` monorepo's `pipeline/` subdir on 2026-07-07, same day the unit itself
moved from system- to user-scope — see
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

**Since 2026-07-07, `config.toml` is a rendered artifact** (layer 3 of the fleet's three-layer
config model — [50-configuration-and-state.md](50-configuration-and-state.md)): `render/render.sh`
in `gjc-fleet` substitutes host values from `~/.config/gjc-fleet/fleet.toml` into a repo-tracked
template and installs the result here. The 15 `[[routes]]` (lifecycle, issue/CI embeds, the
issue-spool localfile route, the canary route, …) are **static template text** — never generated,
so the `session.*`→`kind=agent.*` keying, the deliberate absence of a catch-all route, and the
channel-less embed routes below all stay byte-for-byte stable across renders (guarded by
`render/lint-routes.sh` in CI). Only the six `[[monitors.git.repos]]` blocks are generated, one per
`[[repos]]` entry in `fleet.toml`. `render/render.sh diff` **replaces the dated `.bak-*` convention**
going forward — existing `.bak-*` files above remain on disk as forensic history and are never
deleted by the renderer.

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

`clawhip.service` (**user-scope**, `~/.config/systemd/user/clawhip.service`, `WantedBy=default.target`,
enabled under linger — no `sudo`, no `User=` directive needed): `ExecStart=%h/.cargo/bin/clawhip start`,
`Environment=CLAWHIP_CONFIG=%h/.clawhip/config.toml`, `EnvironmentFile=%h/.clawhip/clawhip.env`,
`Restart=always`, `RestartSec=5`. Drop-in `clawhip.service.d/10-gjc-relay.conf` adds
`After=`/`Wants=gjc-relay.service` so the relay is up before clawhip sends. The unit is now rendered
from `gjc-fleet/systemd/clawhip.service` (repo-root `systemd/`, not the pipeline's own dir) via
`render/render.sh apply --units`. Note the in-repo upstream `deploy/clawhip.service` template
(inside the `clawhip` crate itself, not `gjc-fleet`) still does **not** match the live unit.

## Open questions

- Is any `slack` sink route live anywhere? (Code exists; live config shows none.)
- Are the in-repo `integrations/` git/tmux hooks installed in any repo on this machine? (The tmux
  monitor list is empty — see
  [40-gjc-bot-automation.md](40-gjc-bot-automation.md#discrepancies).) Note this is no longer tied to
  `gjc-reap.sh`: reap is now wired into the janitor's tmux reaper
  (`gjc-worktree-janitor.sh`), not any clawhip `tmux.stale` route.
- Will the `gajae` handler seam be wired up (route action → exec gjc), or does invocation stay with
  gjc-bot?
- Upstream `ARCHITECTURE.md` is two minor versions stale — worth an upstream refresh or a local
  addendum.

## Changelog

- 2026-07-09 (v2-current-state rewrite) — Doc set rebaselined to current state; prior history in git.
  This page: corrected the gjc-reap.sh open question — reap is now wired into the janitor's tmux
  reaper (`gjc-worktree-janitor.sh`), not a clawhip `tmux.stale` route.
