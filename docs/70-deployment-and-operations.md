<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-09
sources:
  - ~/.config/systemd/user/ (live units, via systemctl --user cat/status)
  - ~/github/engels74-bot/gjc-fleet/{systemd,render}/ (unit templates + renderer)
  - ~/.gjc-bot/*.log, journalctl --user evidence gathered 2026-07-06/07
  - gjc-fleet/pipeline/maintenance/{fleet-update.sh,hermes-update.sh,gjc-worktree-janitor.sh},
    gjc-fleet/pipeline/review/automerge.sh, gjc-fleet/pipeline/lib/engine.sh,
    gjc-fleet/fleet.toml.example
maintainer_notes: >
  Edit this file in isolation. Keep headings stable.
  Changelog is a single current-state rebaseline entry — rewrite this page to current state
  rather than appending; prior history lives in git.
  This page maps WHAT runs WHERE and owns the operating procedures — there is no separate runbook.
-->

# Deployment & operations

> Architecture-level map of processes, services, scheduling, and logs — and the owner of
> hands-on procedures. Start/stop is `systemctl --user {start,stop,restart} <unit>` on the units in
> the Service map below (all **user-scope** since 2026-07-07, no `sudo`); rollback is
> `~/scripts/backuprestore/restore.sh --apply` (see [Backup / rollback](#backup--rollback)). Deploy
> and re-deploy go through `render/render.sh` (see [Deploy & rollback via
> render.sh](#deploy--rollback-via-rendersh)). **The fleet self-updates nightly** (the
> `fleet-update` lane — host toolchain + hermes-agent, currently gated OFF, see
> [Scheduled lanes](#scheduled-lanes-systemd-timerspath--hermes-cron)); hand-running the
> underlying `tool-update.sh`/`hermes update` commands remains a documented override for when the
> nightly lane is off or an out-of-band update is needed (see
> [Deploy & rollback via render.sh](#deploy--rollback-via-rendersh)). The earlier hermes-stack
> build-log/runbook that once held these procedures has been retired; this doc set supersedes it.

## Where things run

Everything runs **natively on this host as user `cvps`** (no Docker), managed by **user-scope
systemd units** (`~/.config/systemd/user/`, `WantedBy=default.target`, linger enabled so units
start at boot with no login session — there is no crontab). This is a change from before
2026-07-07, when the fleet ran as system-level units under `/etc/systemd/system/`; see
[Migration to user units](#migration-to-user-units-2026-07-07) below. Rationale for native (no
Docker): sharing the host filesystem, tmux, git credentials, and Codex OAuth.

### Migration to user units (2026-07-07)

Every fleet unit — clawhip, gjc-relay + its supervision stack, and all four gjc-bot units — was
cut over from system-level (`/etc/systemd/system/`, installed with `sudo`) to **user-scope**
(`~/.config/systemd/user/`, installed by `render/render.sh apply --units`, no `sudo` anywhere in
the lifecycle), rendered from templates now living in `gjc-fleet/systemd/` at the monorepo root.
`hermes-gateway.service` is the one exception: it was **already** effectively user-manageable via
`hermes gateway install`, which `hermes_cli` runs natively in user scope (handling its own linger
enablement); `gjc-fleet/systemd/hermes-gateway.service.ref` is kept only as a non-installable
reference copy for diffing.

Two host-level prerequisites this migration depends on:
- **Linger** (`loginctl enable-linger cvps`) — without it, user units stop when the last login
  session ends; with it, they behave like system units for uptime purposes.
- **`XDG_RUNTIME_DIR`** — `systemctl --user`/`journalctl --user` need this set to the user's
  runtime dir (`/run/user/$(id -u)`) to reach the user manager's bus. Cron jobs, hooks, and other
  non-login-shell contexts don't get it for free: `pipeline/lib/userctl.sh` wraps both commands
  (`userctl()`/`userjournal()`) with an explicit `XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id
  -u)}"` fallback, and `~/.zshenv` now exports it for interactive shells.

The pre-migration system-level units were **removed on 2026-07-08** (operator's call to skip the
planned 24–48 h soak): all 13 remaining `/etc/systemd/system/` fleet unit files plus the
`clawhip.service.d/` drop-in dir deleted, `daemon-reload`ed, verified zero fleet leftovers in
`/etc`. Rollback now means re-rendering from a pre-migration snapshot (or git history — the
verbatim system units live in the repo's history at the import commit). One residual to confirm:
the **reboot test** (linger + user-unit boot-start across a real reboot, not just the hot
cutover) is still outstanding. `~/scripts/backuprestore/restore.sh` stays dual-scope defensively
(see [50-configuration-and-state.md](50-configuration-and-state.md#backups--rollback)).

**Source vs. runtime (a common misread).** The three upstream engines live as *reference-only*
source checkouts under `~/github/engels74/gjc/` (`gajae-code`, `hermes-agent`, `clawhip` — upstream
remotes, not the user's own repos). The services do not run from those checkouts, and the checkouts
are not the build input: each app is installed independently — `gjc` as a bun global package
(runs from `~/.bun/bin/gjc`), clawhip via `cargo install` from crates.io (`~/.cargo/bin/clawhip`),
hermes as a separate deployed copy + editable venv under `~/.hermes/hermes-agent`
(`~/.hermes/hermes-agent/venv/bin/python`). The locally-authored relay follows the same pattern
with a local build as its install channel: `cargo build --release` in the `relay/` subdir of the
`engels74-bot/gjc-fleet` monorepo and the binary copied to `~/.gjc-relay/gjc-relay` (see
[Relay deploy / rollback](#relay-deploy--rollback)).
The base toolchain is linuxbrew; the fleet apps are
not brew formulae. The `ExecStart=` paths in the Service map below are the authoritative runtime
locations. See [00-overview.md](00-overview.md#where-each-component-lives-and-runs) for the full split.

## Service map

### Long-running daemons (all `Restart=always`, **user-scope** — `~/.config/systemd/user/`, no `sudo`)

| Unit | ExecStart | Role |
|---|---|---|
| `hermes-gateway.service` | `~/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run` | The hermes gateway: Discord "GJC Brain", in-process cron ticker, kanban watchers. Child process: `bun …/gjc mcp-serve coordinator` (the gjc coordinator MCP). Generated by `hermes gateway install`, not the fleet renderer |
| `clawhip.service` | `%h/.cargo/bin/clawhip start` | Event router daemon on 127.0.0.1:25294; drop-in `10-gjc-relay.conf` orders it after the relay |
| `gjc-relay.service` | `%h/.gjc-relay/gjc-relay` | Loopback embed proxy on 127.0.0.1:25295; `RestartSec=1`, `StartLimitIntervalSec=0`, `OnFailure=gjc-relay-alert.service` |
| `gjc-dlq-watch.service` | `%h/.gjc-relay/dlq-watch.sh` | journal follower (`journalctl --user`) alarming on `clawhip dlq bury:` (direct-to-Discord, bypasses clawhip+relay) |

`gjc-relay-alert.service` is a oneshot `OnFailure` target (direct-to-Discord + journald + mail).
All units above except `hermes-gateway.service` are rendered from `gjc-fleet/systemd/*` and
installed by `render/render.sh apply --units`.

### Scheduled lanes (systemd timers/path + hermes cron)

See the full table in
[40-gjc-bot-automation.md](40-gjc-bot-automation.md#scheduling-map). Summary: a **path unit**
fires the issue intake on spool writes (with a 5-min backup timer); **timers** run
review-detector (5 min), merge-gate (10 min), automerge (10 min, default OFF), the worktree
janitor (2 min, also carries an age-based tmux-session reaper, default OFF), and nightly
fleet-update (~03:30, default OFF); **hermes cron** (a ticker inside the gateway, *not* systemd)
runs the nightly stale-branch report and the weekly issue-triage digest.

All gjc-bot units are **user-scope** (`~/.config/systemd/user/`), rendered from
`gjc-fleet/systemd/*.service` templates, with `ExecStart=` pointing at
`~/github/engels74-bot/gjc-fleet/pipeline/<subfolder>/<script>.sh`: `issue-spool-adapter` →
`pipeline/intake/issue-spool-adapter.sh`, `review-detector` →
`pipeline/review/review-detector.sh`, `merge-gate` → `pipeline/review/merge-gate.sh`,
`automerge` → `pipeline/review/automerge.sh`, `gjc-worktree-janitor` →
`pipeline/maintenance/gjc-worktree-janitor.sh`, `fleet-update` →
`pipeline/maintenance/fleet-update.sh`. Each also carries
`EnvironmentFile=-%h/.gjc-bot/gjc-bot.env` for the rendered per-lane Discord channel IDs and
config knobs. The hermes cron wrappers `~/.hermes/scripts/{stale-branches,issue-triage-fetch}.sh`
are real-file (non-symlink) shims that `exec` `…/gjc-fleet/pipeline/maintenance/stale-branches.sh`
and `…/pipeline/intake/issue-triage-fetch.sh`.

**Coordinator tmux reaper (in `gjc-worktree-janitor.sh`, Workstream I).** Before its worktree
pass, the janitor now enumerates `gjc-coordinator-*` tmux sessions and reaps one iff its
coordinator-mcp state is `completed`/`stale` AND `live == false` AND `updated_at` is older than
`[janitor].tmux_grace_mins` (`JANITOR_TMUX_GRACE_SECONDS`, default 30 min); a session with no
matching state file gets a much larger ~24h fallback grace; missing/malformed state fields
SKIP (fail-safe). Reaping goes through the existing `gjc-reap.sh`. Gated on
`[janitor].tmux_reap_enabled` (default OFF) + `DRY_RUN`. This resolves the earlier "`gjc-reap.sh`
is defined but never wired / who triggers it" open question — it is now wired into the janitor's
2-minute timer.

**`fleet-update` (nightly self-update lane, `pipeline/maintenance/fleet-update.sh`).**
Orchestrates: quiesce (blocking-with-timeout `flock -w` on `gjc.lock` AND `review.lock`, plus
waiting for zero live coordinator-mcp sessions; on timeout, DEFERS to the next night with a
notice embed rather than forcing) → `tool-update.sh` (headless host-toolchain refresh, with a
`trap … EXIT` that re-runs `bootstrap/10-engines.sh` to re-assert the gajae-code/clawhip pins) →
`hermes-update.sh --apply` (gateway restarted last — see
[20-hermes-agent.md#updates](20-hermes-agent.md#updates)) → release locks →
`bootstrap/verify.sh` → one `fleet-update` summary embed (per-job ok/fail table). Kill switches
(all must allow a real run): `[updates].tool_update_enabled` (default OFF), a
`~/.gjc-bot/fleet-update.disable` marker, and `DRY_RUN`.

**`automerge` (auto-merge lane, `pipeline/review/automerge.sh`).** Synchronously merges
CI-green, policy-settled, automated-author PRs oldest-first, capped by
`[merge].automerge_max_per_poll` (default 1) per repo per run, via
`gh pr merge --squash --match-head-commit <sha>` inside the per-repo lock (re-fetches head +
re-checks CI in-lock first). A capability guard feature-probes `gh pr merge --help` for
`--match-head-commit`; if absent, it fails closed (one `automerge.escalation` embed, `gh pr
merge` is never called). Kill switches (ALL must allow): `[merge].automerge_enabled` (default
OFF/false — canary pending), no `~/.gjc-bot/automerge.disable` marker, `DRY_RUN` unset, the repo
not excluded, and no `automerge-hold` label on the PR.

### Processes that exist only during work

- `gjc` headless runs (`gjc -p --no-pty`) inside per-run worktrees, detached via `setsid`,
  bounded by `timeout 1800`.
- `claude` headless review-handler runs in the isolated review checkout, bounded by `timeout 5400`.
- hermes cron *agent* jobs (fresh `AIAgent`, inactivity timeout 600 s) and kanban worker spawns
  (`hermes -p <profile>` subprocesses — none observed live).

## Network posture

Loopback only; no inbound ports for the fleet: `127.0.0.1:25294` (clawhip daemon),
`127.0.0.1:25295` (gjc-relay). Hermes' webhook platform (would be 0.0.0.0:8644) and API server
are **disabled**. All external I/O is outbound: GitHub API, NanoGPT API (gjc-bot triage/gate),
OpenAI Codex API (hermes brain, since 2026-07-07), Discord API. This upholds the fleet's
"no inbound ports / no standing sudo" safety rails.

## Identities

| Identity | Kind | Used by |
|---|---|---|
| `engels74` | GitHub account (repo owner) | human |
| `engels74-bot` | GitHub account (Write collaborator) | all bot PRs/comments (gjc pushes, review handler, merge-gate comments) |
| "GJC Brain" | Discord bot | hermes (conversational) |
| "GJC Clawhip" | Discord bot | clawhip→relay posts (notifications) |
| `augmentcode[bot]` | GitHub app (external) | the automatic PR reviewer the review lane responds to |

Local git commit identity is enforced per-directory via `~/.gitconfig` `includeIf` blocks: work
under `gitdir:/home/cvps/github/engels74-bot/` loads `~/.gitconfig-engels74-bot` (the bot identity),
while `gitdir:/home/cvps/github/engels74/` loads `~/.gitconfig-engels74` (the human). Verified live
2026-07-07 — the `engels74-bot` `includeIf` still holds, so all of the bot's own repos (including
the `gjc-fleet` monorepo that absorbed `gjc-bot-scripts`) commit as the bot.

## Logs & observability

| Where | What |
|---|---|
| `journalctl --user -u {hermes-gateway,clawhip,gjc-relay,gjc-dlq-watch}.service` | Daemon logs (user journal since the 2026-07-07 units migration); relay logs `[transform] POST … kind=… -> <status>` lines; clawhip logs `clawhip dlq bury:` on lost sends. Verified persistent journald + `SplitMode=uid` so user-scope logs survive across sessions/reboots |
| `~/.gjc-bot/{adapter,gjc-run,review,merge-gate,janitor}.log` | Per-lane pipeline logs |
| `~/.gjc/logs/gjc.YYYY-MM-DD.log` | gjc daily JSONL logs (+ hashed audit sidecar) |
| `~/.hermes/cron/output/<job_id>/*.md` | Cron job run records; `ticker_heartbeat`/`ticker_last_success` for scheduler liveness (`hermes cron status`) |
| `~/.hermes/gateway_state.json` | Live gateway/platform state |
| Discord `#gjc-events` / `#gjc-approvals` | The human-facing operational surface (embeds) |

Out-of-band alerting: `gjc-dlq-watch` (silent notification loss) and `gjc-relay-alert`
(relay failure) both post directly to Discord `#gjc-approvals`, deliberately bypassing the
components they monitor.

## Backup / rollback

`~/scripts/backuprestore/backup-now.sh` (snapshot) and `restore.sh --apply` (full revert;
`--purge-repos` also removes clones) — every phase artifact is registered for
teardown. `restore.sh` is **dual-scope** since 2026-07-07: it disables/removes user-scope units
first, then any leftover pre-migration `/etc/systemd/system/` units. Config waves additionally
leave dated `.bak-*` files next to each edited file
([50-configuration-and-state.md](50-configuration-and-state.md#backups--rollback)).

## Deploy & rollback via render.sh

Since 2026-07-07, config and unit deploys go through the fleet renderer rather than hand-editing
files in place:

```sh
cd ~/github/engels74-bot/gjc-fleet
render/render.sh render          # stage all targets from fleet.toml, touches nothing live
render/render.sh diff            # unified diff staging vs live; exit 1 on drift
render/render.sh apply --units   # per-target confirm + atomic install, incl. systemd units
systemctl --user daemon-reload   # only needed after a unit-file change
```

`render/render.sh check` (the CI gate) renders from `fleet.toml.example` and additionally validates
route invariants, design-system kind coverage, and that no numeric Discord ID has landed in the
repo. `render/render.sh doctor` checks the hermes-owned files the renderer deliberately does not
own (`config.yaml` path lines, cron workdirs) for drift, without touching them. A fresh
"stand up your own fleet" walkthrough is in
[80-reproduction-guide.md](80-reproduction-guide.md); the bootstrap scripts it references handle
first-time engine installs, secrets, and unit installation in order.

### Fleet self-update (nightly) and manual override

The fleet self-updates: the nightly `fleet-update` lane (`pipeline/maintenance/fleet-update.sh`,
`systemd/fleet-update.{service,timer}`, ~03:30, currently gated OFF — see
[Scheduled lanes](#scheduled-lanes-systemd-timerspath--hermes-cron)) quiesces the fleet, refreshes
the host toolchain (`tool-update.sh`, which re-asserts the `gajae-code`/`clawhip` `fleet.toml`
pins on exit via a trap), then updates hermes-agent (`hermes-update.sh --apply`, gateway restarted
last, health-gated with rollback-on-failure), then runs `bootstrap/verify.sh` and posts one
summary embed. This is the intended steady state; the older pattern of hand-running updates is no
longer how this deployment expects to move forward.

When the nightly lane is off (its default state) or an out-of-band update is needed, the same
commands the lane wraps remain the documented manual override:

```sh
# host toolchain (uv/prek/bun+globals/skills/ruff/claude), then re-pin gajae-code/clawhip
~/github/engels74-bot/gjc-fleet/pipeline/maintenance/tool-update.sh
~/github/engels74-bot/gjc-fleet/bootstrap/10-engines.sh

# hermes-agent: check, then apply with restart + health gate + rollback-on-failure
~/github/engels74-bot/gjc-fleet/pipeline/maintenance/hermes-update.sh --check
~/github/engels74-bot/gjc-fleet/pipeline/maintenance/hermes-update.sh --apply
```

### Review-lane engine and rollback to `claude`

The review/policy/ci-fix handlers dispatch through `pipeline/lib/engine.sh` (`engine_run`), which
runs the coding engine named in `[review].engine`. **Live default is `gjc`**
(`gjc -p --no-pty "@<prompt-file>"`, inheriting gjc's own configured backend). The legacy headless
`claude -p --dangerously-skip-permissions --model "$MODEL_PRIMARY"` path remains available as a
selectable fallback engine, not the active one. To roll the review lane back to it: set
`[review].engine = "claude"` in `~/.config/gjc-fleet/fleet.toml` and re-run
`render/render.sh apply` (renders `REVIEW_ENGINE=claude` into `~/.gjc-bot/gjc-bot.env`), or export
`REVIEW_ENGINE=claude` directly in that env file for an immediate override without a render pass.
`[review].model_primary`/`model_fast` are not wired through the renderer today — the `claude`
fallback path uses hardcoded `opus`/`sonnet` regardless, and under `engine=gjc` (the default) they
are irrelevant anyway, since gjc inherits its own backend/models.

### Relay deploy / rollback

gjc-relay is the one component deployed by a local build (its source now lives in the `relay/`
subdir of the `engels74-bot/gjc-fleet` monorepo; the unit file never changes on redeploy):

```sh
cd ~/github/engels74-bot/gjc-fleet/relay
cargo test && cargo build --release
cp --remove-destination target/release/gjc-relay ~/.gjc-relay/gjc-relay
systemctl --user restart gjc-relay.service
```

Rollback is the same procedure from an earlier commit (`git checkout <rev> -- src/ Cargo.toml
Cargo.lock`, or a worktree at `<rev>`), rebuild, copy, restart. The relay is in-path for all
Discord notifications and clawhip has no send retry — keep the restart window short and verify:
`systemctl --user is-active gjc-relay`, `curl 127.0.0.1:25295/healthz`, a `#gjc-lab` canary embed,
no `clawhip dlq bury:` lines ([35-gjc-relay.md](35-gjc-relay.md#build--deploy)).

> Historical note: an earlier hermes-stack build-log/runbook (a SESSION HANDOFF snapshot, the
> Phase-G execution log, and the original phase-by-phase build plan) once held the procedures and
> build history for this stack. It has been retired and deleted; this doc set is its successor and
> single source of truth. Build phases survive as the "Phase A–G" glossary entry in
> [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#glossary).

## Open questions

- `gjc-worktree-janitor.timer` uses `Persistent=false`; the other timers' persistence flags were
  not individually recorded — worth capturing if boot-catch-up behavior ever matters.
- No monitoring exists for the hermes cron ticker beyond `hermes cron status` run manually — is
  that acceptable now that cron carries only two low-stakes report jobs?
- Per-repo review concurrency remains a documented follow-up: review handling is fleet-wide
  single-flight (K1/K5 locking); the `review.backlog` embed (fires past
  `REVIEW_BACKLOG_ALERT_MINS`) mitigates but does not resolve the resulting queueing under load.

## Changelog

- 2026-07-09 (v2-current-state rewrite) — Doc set rebaselined to current state; prior history in git.
  This page: `fleet-update` + `automerge` units and the janitor's coordinator tmux reaper added to
  the service/scheduling inventory; nightly self-update (tool-update + hermes-update, with pin
  re-assertion) documented as normal ops with the manual commands kept as an override; review-lane
  engine noted as `gjc` live with the documented rollback to `claude`.
