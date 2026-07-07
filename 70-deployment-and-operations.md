<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - /etc/systemd/system/ (live units, via systemctl cat/status)
  - ~/.gjc-bot/*.log, journalctl evidence gathered 2026-07-06
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  This page maps WHAT runs WHERE and owns the operating procedures — there is no separate runbook.
-->

# Deployment & operations

> Architecture-level map of processes, services, scheduling, and logs — and the owner of
> hands-on procedures. Start/stop is `systemctl {start,stop,restart} <unit>` on the units in the
> Service map below (all `User=cvps`, system-level); rollback is `~/scripts/backuprestore/restore.sh
> --apply` (see [Backup / rollback](#backup--rollback)). The earlier hermes-stack build-log/runbook
> that once held these procedures has been retired; this doc set supersedes it.

## Where things run

Everything runs **natively on this host as user `cvps`** (no Docker), managed by **system-level
systemd units** (not user units — `systemctl --user` has no fleet units; there is no crontab).
Rationale: sharing the host filesystem, tmux, git credentials, and Codex OAuth.

**Source vs. runtime (a common misread).** The three upstream engines live as *reference-only*
source checkouts under `~/github/engels74/gjc/` (`gajae-code`, `hermes-agent`, `clawhip` — upstream
remotes, not the user's own repos). The services do not run from those checkouts, and the checkouts
are not the build input: each app is installed independently — `gjc` as a bun global package
(runs from `~/.bun/bin/gjc`), clawhip via `cargo install` from crates.io (`~/.cargo/bin/clawhip`),
hermes as a separate deployed copy + editable venv under `~/.hermes/hermes-agent`
(`~/.hermes/hermes-agent/venv/bin/python`). The locally-authored relay follows the same pattern
with a local build as its install channel: `cargo build --release` in its own repo
(`~/github/engels74-bot/gjc-relay`, since 2026-07-07) and the binary copied to
`~/.gjc-relay/gjc-relay` (see [Relay deploy / rollback](#relay-deploy--rollback)).
The base toolchain is linuxbrew; the fleet apps are
not brew formulae. The `ExecStart=` paths in the Service map below are the authoritative runtime
locations. See [00-overview.md](00-overview.md#where-each-component-lives-and-runs) for the full split.

## Service map

### Long-running daemons (all `Restart=always`, `User=cvps`)

| Unit | ExecStart | Role |
|---|---|---|
| `hermes-gateway.service` | `~/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main gateway run` | The hermes gateway: Discord "GJC Brain", in-process cron ticker, kanban watchers. Child process: `bun …/gjc mcp-serve coordinator` (the gjc coordinator MCP) |
| `clawhip.service` | `/home/cvps/.cargo/bin/clawhip start` | Event router daemon on 127.0.0.1:25294; drop-in `10-gjc-relay.conf` orders it after the relay |
| `gjc-relay.service` | `/home/cvps/.gjc-relay/gjc-relay` | Loopback embed proxy on 127.0.0.1:25295; `RestartSec=1`, `StartLimitIntervalSec=0`, `OnFailure=gjc-relay-alert.service` |
| `gjc-dlq-watch.service` | `/home/cvps/.gjc-relay/dlq-watch.sh` | journal follower alarming on `clawhip dlq bury:` (direct-to-Discord, bypasses clawhip+relay) |

`gjc-relay-alert.service` is a oneshot `OnFailure` target (direct-to-Discord + journald + mail).

### Scheduled lanes (systemd timers/path + hermes cron)

See the full table in
[40-gjc-bot-automation.md](40-gjc-bot-automation.md#scheduling-map). Summary: a **path unit**
fires the issue intake on spool writes (with a 5-min backup timer); **timers** run
review-detector (5 min), merge-gate (10 min), and the worktree janitor (2 min); **hermes cron**
(a ticker inside the gateway, *not* systemd) runs the nightly stale-branch report and the weekly
issue-triage digest.

All four gjc-bot units' `ExecStart=` were relocated this session and verified live in
`/etc/systemd/system/` (reinstalled + `daemon-reload`, all `Result=success`): `issue-spool-adapter`
→ `…/gjc-bot-scripts/intake/issue-spool-adapter.sh`, `review-detector` →
`…/gjc-bot-scripts/review/review-detector.sh`, `merge-gate` → `…/gjc-bot-scripts/review/merge-gate.sh`,
`gjc-worktree-janitor` → `…/gjc-bot-scripts/maintenance/gjc-worktree-janitor.sh` (repo root
`~/github/engels74-bot/gjc-bot-scripts/`). The hermes cron wrappers `~/.hermes/scripts/{stale-branches,
issue-triage-fetch}.sh` are real-file (non-symlink) shims that now `exec` the new
`…/gjc-bot-scripts/maintenance/stale-branches.sh` and `…/intake/issue-triage-fetch.sh`.

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
2026-07-07 — the `engels74-bot` `includeIf` still holds, so all gjc-bot repos (including the
relocated `gjc-bot-scripts`) commit as the bot.

## Logs & observability

| Where | What |
|---|---|
| `journalctl -u {hermes-gateway,clawhip,gjc-relay,gjc-dlq-watch}.service` | Daemon logs; relay logs `[transform] POST … kind=… -> <status>` lines; clawhip logs `clawhip dlq bury:` on lost sends |
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
teardown. Config waves additionally leave dated `.bak-*` files next to each edited file
([50-configuration-and-state.md](50-configuration-and-state.md#backups--rollback)).

### Relay deploy / rollback

gjc-relay is the one component deployed by a local build (its source repo is
`~/github/engels74-bot/gjc-relay`; the unit file never changes):

```sh
cd ~/github/engels74-bot/gjc-relay
cargo test && cargo build --release
cp --remove-destination target/release/gjc-relay ~/.gjc-relay/gjc-relay
sudo systemctl restart gjc-relay.service
```

Rollback is the same procedure from an earlier commit (`git checkout <rev> -- src/ Cargo.toml
Cargo.lock`, or a worktree at `<rev>`), rebuild, copy, restart. The relay is in-path for all
Discord notifications and clawhip has no send retry — keep the restart window short and verify:
`systemctl is-active gjc-relay`, `curl 127.0.0.1:25295/healthz`, a `#gjc-lab` canary embed, no
`clawhip dlq bury:` lines ([35-gjc-relay.md](35-gjc-relay.md#build--deploy)).

> Historical note: an earlier hermes-stack build-log/runbook (a SESSION HANDOFF snapshot, the
> Phase-G execution log, and the original phase-by-phase build plan) once held the procedures and
> build history for this stack. It has been retired and deleted; this doc set is its successor and
> single source of truth. Build phases survive as the "Phase A–G" glossary entry in
> [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#glossary).

## Open questions

- `gjc-worktree-janitor.timer` uses `Persistent=false`; the other timers' persistence flags were
  not individually recorded — worth capturing if boot-catch-up behavior ever matters.
- No monitoring exists for the hermes cron ticker beyond `hermes cron status` run manually;
  is that acceptable now that cron carries three jobs — two low-stakes reports plus the
  self-scheduled EasyHDR PR-115 monitor (see [20-hermes-agent.md](20-hermes-agent.md#the-cron-subsystem))?

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
