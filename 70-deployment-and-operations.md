<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - /etc/systemd/system/ (live units, via systemctl cat/status)
  - ~/downloads/hermes-stack-runbook.md (operational procedures — linked, not duplicated)
  - ~/.repo-bot/*.log, journalctl evidence gathered 2026-07-06
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  This page maps WHAT runs WHERE. Step-by-step operating procedures stay in the runbook.
-->

# Deployment & operations

> Architecture-level map of processes, services, scheduling, and logs. For hands-on procedures
> (start/stop, rollback, phase history) use the runbook:
> `~/downloads/hermes-stack-runbook.md` — but note its staleness flags in
> [90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#runbook-staleness).

## Where things run

Everything runs **natively on this host as user `cvps`** (no Docker), managed by **system-level
systemd units** (not user units — `systemctl --user` has no fleet units; there is no crontab).
Rationale from the runbook: sharing the host filesystem, tmux, git credentials, and Codex OAuth.

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
[40-repo-bot-automation.md](40-repo-bot-automation.md#scheduling-map). Summary: a **path unit**
fires the issue intake on spool writes (with a 5-min backup timer); **timers** run
review-detector (5 min), merge-gate (10 min), and the worktree janitor (2 min); **hermes cron**
(a ticker inside the gateway, *not* systemd) runs the nightly stale-branch report and the weekly
issue-triage digest.

All four repo-bot units' `ExecStart=` were relocated this session and verified live in
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
are **disabled**. All external I/O is outbound: GitHub API, NanoGPT API (repo-bot triage/gate),
OpenAI Codex API (hermes brain, since 2026-07-07), Discord API. This matches
the runbook's "no inbound ports / no standing sudo" safety rails.

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
2026-07-07 — the `engels74-bot` `includeIf` still holds, so all repo-bot repos (including the
relocated `gjc-bot-scripts`) commit as the bot.

## Logs & observability

| Where | What |
|---|---|
| `journalctl -u {hermes-gateway,clawhip,gjc-relay,gjc-dlq-watch}.service` | Daemon logs; relay logs `[transform] POST … kind=… -> <status>` lines; clawhip logs `clawhip dlq bury:` on lost sends |
| `~/.repo-bot/{adapter,gjc-run,review,merge-gate,janitor}.log` | Per-lane pipeline logs |
| `~/.gjc/logs/gjc.YYYY-MM-DD.log` | gjc daily JSONL logs (+ hashed audit sidecar) |
| `~/.hermes/cron/output/<job_id>/*.md` | Cron job run records; `ticker_heartbeat`/`ticker_last_success` for scheduler liveness (`hermes cron status`) |
| `~/.hermes/gateway_state.json` | Live gateway/platform state |
| Discord `#gjc-events` / `#gjc-approvals` | The human-facing operational surface (embeds) |

Out-of-band alerting: `gjc-dlq-watch` (silent notification loss) and `gjc-relay-alert`
(relay failure) both post directly to Discord `#gjc-approvals`, deliberately bypassing the
components they monitor.

## Backup / rollback

`~/scripts/backuprestore/backup-now.sh` (snapshot) and `restore.sh --apply` (full revert;
`--purge-repos` also removes clones) — per the runbook, every phase artifact is registered for
teardown. Config waves additionally leave dated `.bak-*` files next to each edited file
([50-configuration-and-state.md](50-configuration-and-state.md#backups--rollback)).

## Relationship to the runbook

The runbook (`~/downloads/hermes-stack-runbook.md`) is three stacked layers: a
SESSION HANDOFF snapshot (2026-07-05), the PHASE G execution log (2026-07-06), and the original
phase-by-phase build plan. Use it for: procedures (systemctl commands, pause-a-lane, rollback),
build history (Phases A–G), and decision rationale. **Do not use it for current topology** — it
predates gjc-relay entirely and parts of it describe a superseded model (DeepSeek-era). The
architecture pages here supersede it for structure; staleness specifics are catalogued in
[90-glossary-and-open-questions.md](90-glossary-and-open-questions.md#runbook-staleness).

## Open questions

- The runbook now lives at `~/downloads/hermes-stack-runbook.md` (it was cited as
  `~/documentation/hermes-stack-runbook.md`, which no longer exists — the only copy on disk is under
  `~/downloads/`). Is `~/downloads/` its intended home or a transient location that should move back
  under `~/documentation/`? All citations updated to the live path 2026-07-07.
- Should the runbook be updated to reference this doc set (and the relay), or frozen as history?
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
- 2026-07-07 (repo-move pass) — Status → verified. Re-verified all four repo-bot units live in
  `/etc/systemd/system/`: `ExecStart=` now under `~/github/engels74-bot/gjc-bot-scripts/<subfolder>/`
  (intake/review/maintenance), reinstalled + `daemon-reload`, all `Result=success`; timers/path unit
  active. Documented the hermes cron real-file wrappers now `exec`-ing the new subfolder paths. Added
  a git-identity note (`~/.gitconfig` `includeIf` for `engels74-bot` verified still enforced).
  Long-running daemons, loopback network posture, and identities re-confirmed — no drift. Fixed
  runbook path drift (`~/documentation/…` → live `~/downloads/hermes-stack-runbook.md`) and logged
  it as an open question.
