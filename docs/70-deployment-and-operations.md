<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/.config/systemd/user/ (live units, via systemctl --user cat/status)
  - ~/github/engels74-bot/gjc-fleet/{systemd,render}/ (unit templates + renderer)
  - ~/.gjc-bot/*.log, journalctl --user evidence gathered 2026-07-06/07
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  This page maps WHAT runs WHERE and owns the operating procedures — there is no separate runbook.
-->

# Deployment & operations

> Architecture-level map of processes, services, scheduling, and logs — and the owner of
> hands-on procedures. Start/stop is `systemctl --user {start,stop,restart} <unit>` on the units in
> the Service map below (all **user-scope** since 2026-07-07, no `sudo`); rollback is
> `~/scripts/backuprestore/restore.sh --apply` (see [Backup / rollback](#backup--rollback)). Deploy
> and re-deploy go through `render/render.sh` (see [Deploy & rollback via
> render.sh](#deploy--rollback-via-rendersh)). The earlier hermes-stack build-log/runbook that once
> held these procedures has been retired; this doc set supersedes it.

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

The pre-migration system-level units are **disabled but not deleted** — left on disk pending a
24–48 h soak period plus a reboot test (confirming linger + user-unit boot-start actually works
across a real reboot, not just a hot cutover) before final removal; rollback during the soak window
is re-enabling them. `~/scripts/backuprestore/restore.sh` is dual-scope for exactly this
transitional reason (see [50-configuration-and-state.md](50-configuration-and-state.md#backups--rollback)).

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
review-detector (5 min), merge-gate (10 min), and the worktree janitor (2 min); **hermes cron**
(a ticker inside the gateway, *not* systemd) runs the nightly stale-branch report and the weekly
issue-triage digest.

All four gjc-bot units are **user-scope** (`~/.config/systemd/user/`), rendered from
`gjc-fleet/systemd/*.service` templates, with `ExecStart=` pointing at
`~/github/engels74-bot/gjc-fleet/pipeline/<subfolder>/<script>.sh`: `issue-spool-adapter` →
`pipeline/intake/issue-spool-adapter.sh`, `review-detector` →
`pipeline/review/review-detector.sh`, `merge-gate` → `pipeline/review/merge-gate.sh`,
`gjc-worktree-janitor` → `pipeline/maintenance/gjc-worktree-janitor.sh`. Each also carries
`EnvironmentFile=-%h/.gjc-bot/gjc-bot.env` for the rendered per-lane Discord channel IDs. The
hermes cron wrappers `~/.hermes/scripts/{stale-branches,issue-triage-fetch}.sh` are real-file
(non-symlink) shims that `exec` `…/gjc-fleet/pipeline/maintenance/stale-branches.sh` and
`…/pipeline/intake/issue-triage-fetch.sh`.

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
- No monitoring exists for the hermes cron ticker beyond `hermes cron status` run manually;
  is that acceptable now that cron carries the two low-stakes report jobs? (~~a third,
  self-scheduled EasyHDR PR-115 monitor~~ — **resolved 2026-07-07**: it no longer appears in
  `~/.hermes/cron/jobs.json`, confirmed live; see
  [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#open-questions).)

## Changelog

- 2026-07-06 — Initial draft from live systemctl/journal evidence.
- 2026-07-07 — Verification pass: service/timer tables, management level (system, not user),
  network posture (loopback :25294/:25295 only, hermes webhook :8644 not listening), identities,
  and log locations re-verified live — no drift. Added the Codex API to the outbound-I/O list and
  updated the cron-ticker open question for the third (PR-115 monitor) job.
- 2026-07-07 (repo-move pass) — Status → verified. Re-verified all four gjc-bot units live in
  `/etc/systemd/system/`: `ExecStart=` now under `~/github/engels74-bot/gjc-bot-scripts/<subfolder>/`
  (intake/review/maintenance), reinstalled + `daemon-reload`, all `Result=success`; timers/path unit
  active. Documented the hermes cron real-file wrappers now `exec`-ing the new subfolder paths. Added
  a git-identity note (`~/.gitconfig` `includeIf` for `engels74-bot` verified still enforced).
  Long-running daemons, loopback network posture, and identities re-confirmed — no drift. Fixed
  runbook path drift and logged it as an open question.
- 2026-07-07 (runbook-retirement pass) — The earlier hermes-stack build-log/runbook has been
  deleted; this page now owns start/stop/rollback procedures inline (top blockquote). Removed it
  from `sources`, deleted the "Relationship to the runbook" section (collapsed to a one-line
  historical note) and the two now-moot open questions about its path/future. Added a "Source vs.
  runtime" note under "Where things run" reinforcing the repo split — upstream checkouts in
  `~/github/engels74/gjc/` vs the built/installed runtime locations the `ExecStart=` paths point at;
  verified live via `systemctl cat`.
- 2026-07-07 (install-provenance refinement) — Sharpened the "Source vs. runtime" note: checkouts
  are reference-only (not the build input); each app installs via its own channel (bun global,
  `cargo install` from crates.io, hermes deployed-copy venv), only gjc-relay is built in place, and
  the fleet apps are not brew formulae.
- 2026-07-07 (fleet/ move + component rename) — Terminology only: repo-bot → **gjc-bot**;
  cross-links updated. The `~/.gitconfig` `includeIf "gitdir:/home/cvps/github/engels74-bot/"`
  prefix still covers the new `fleet/` subfolder, so the bot identity is unaffected (verified).
- 2026-07-07 (state-dir rename) — Log-location table updated for the `~/.repo-bot` →
  `~/.gjc-bot` rename; `issue-spool-adapter.path` reinstalled + `daemon-reload` (watches the
  new spool path, verified fired-on-append).
- 2026-07-07 (gjc-relay repo adoption) — "Source vs. runtime" note updated: the relay is no longer
  "built in place" — it builds from its own repo `~/github/engels74-bot/gjc-relay` and the binary
  is copied to `~/.gjc-relay/`. Added the "Relay deploy / rollback" procedure (build → test →
  copy → restart → canary-verify). Executed live this session: 17 tests passed, repo-built binary
  byte-identical to the deployed one, ~1 s restart window, `#gjc-lab` canary `-> 200`, no DLQ
  burials, all relay-stack units active.
- 2026-07-07 (gjc-fleet monorepo + user-units migration) — Every fleet unit (clawhip, the full
  relay-stack, all four gjc-bot units) moved from system-level to **user-scope** systemd
  (`~/.config/systemd/user/`, linger enabled, no `sudo`); `hermes-gateway.service` stays generated
  by `hermes gateway install` (already user-scope-native). Added the "Migration to user units"
  subsection (linger + `XDG_RUNTIME_DIR` prerequisites, `pipeline/lib/userctl.sh` wrappers,
  old `/etc` units disabled-but-not-deleted pending a soak + reboot test). Service map: all
  `ExecStart=`/ownership updated for user-scope + the `gjc-fleet` monorepo paths (relay built from
  `relay/`, pipeline scripts from `pipeline/<stage>/`). Added a new top-level "Deploy & rollback via
  render.sh" section (render/diff/apply/check/doctor) superseding ad hoc hand-edits; every
  operational command in this page changed `systemctl`/`journalctl` to their `--user` forms.
  Backup/rollback: `restore.sh` confirmed dual-scope. Verified live: a 2-second relay+clawhip
  cutover behind a `healthz` gate, a canary embed transformed end-to-end (200 in `#gjc-lab`), and a
  full DLQ drill (relay stopped → doomed canary → `clawhip dlq bury:` observed in the user journal →
  `gjc-dlq-watch` alerted `#gjc-approvals` in ~6 s → relay restored → post-drill canary 200); a
  separate wave regenerated `hermes-gateway.service` as a user unit in ~4 s with
  `RestartForceExitStatus=75`/`KillMode=mixed`/`ExecStopPost` all preserved. Separately, hermes
  hygiene done in the same session removed the self-scheduled `monitor-easyhdr-pr115-rustsec` cron
  job from `jobs.json` (resolving the cron-ticker open question's "three jobs" framing) and fixed a
  stale cron workdir via `hermes cron edit`.
