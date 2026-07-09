<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-09
sources:
  - ~/.gjc, ~/.hermes, ~/.clawhip, ~/.gjc-relay, ~/.gjc-bot (runtime evidence)
  - ~/github/engels74-bot/gjc-fleet/{pipeline,render,systemd}/, ~/scripts/backuprestore/
  - ~/github/engels74-bot/gjc-fleet/render/render.sh
  - ~/.config/gjc-fleet/fleet.toml (structure/keys only — this file is host-local and untracked)
maintainer_notes: >
  Edit this file in isolation. Names/roles only — NEVER add secret values here, and NEVER
  reproduce numeric Discord channel/guild IDs (fleet.toml is the only place those live,
  besides the env files it renders into).
  Changelog is a single current-state rebaseline entry — rewrite this page to current
  state rather than appending; prior history lives in git.
  This is the consolidated inventory; per-component detail lives on the component pages.
  Full fleet.toml key reference: 45-fleet-config.md.
-->

# Configuration & state inventory

> Cross-cutting reference: every config file, env file, database, lock, ledger, and worktree
> location, with owner and purpose. **No secret values, no numeric Discord IDs — names/roles only.**

## The three-layer config model (since 2026-07-07)

The fleet's config custody story changed shape with the gjc-fleet monorepo migration. Three layers,
each with a distinct trust/tracking posture:

1. **`gjc-fleet` (git-tracked source of truth)** — code, unit *templates* (`systemd/*.service.tmpl`
   equivalents), config *templates*, `render/`, and this doc set. Safe to read, diff, and share; no
   secrets or numeric IDs ever land here (`render/render.sh check` is a CI gate for exactly that).
2. **`~/.config/gjc-fleet/fleet.toml`** (untracked, 0600, host-local) — the *only* file holding
   operator identity, the `[discord.channels]` name→numeric-ID map, path overrides, version
   `[pins]`, and `[secrets]` pointers (names/paths only, never values). One file per host; never
   committed, never pasted into an issue or a doc. See [45-fleet-config.md](45-fleet-config.md) for
   the full key reference.
3. **Rendered artifacts under `~/.*`** — `~/.clawhip/config.toml`, `~/.gjc-relay/relay.env`,
   `~/.gjc-bot/gjc-bot.env`, and (since the same migration) every fleet systemd unit under
   `~/.config/systemd/user/`. All produced from layer 1 + layer 2 by `render/render.sh`
   (`render|diff|apply|check|doctor`); this is what actually runs.

`render/render.sh diff` **replaces the historical dated `.bak-*` convention** described below going
forward — a would-be config edit is reviewed as a diff against the template + `fleet.toml`, then
applied, rather than hand-edited with a timestamped backup alongside it. Legacy `.bak-*` files from
the pre-renderer waves are **archived by policy** (tarred into `~/.gjc-bot/archive/` by a hand-run
sweep, not an automated job) once they are >30 days old **and** `render.sh diff` is clean — git
history is the primary archive; the tarball is a
short-lived forensic fallback, not a permanent on-disk pile. `render.sh
doctor` separately checks hermes-owned files (`config.yaml` path lines, a duplicate `terminal:`
block, cron workdirs) for drift **without** owning or rendering them — hermes's own config stays
hand-maintained.

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
per-request in the `Authorization` header). Since 2026-07-07, `~/.config/gjc-fleet/fleet.toml`'s
`[secrets]` table adds a layer of indirection on top of this: it records **pointers only**
(`hermes_env = "~/.hermes/.env"`, `clawhip_env = "~/.clawhip/clawhip.env"`, plus the env-var *names*
expected in each) so the renderer and a fresh operator both know where secrets live without the
values ever passing through `fleet.toml` itself. The `EXA_API_KEY` used by gjc's `exa` MCP server
is unaffected by this migration — gajae-code has no env-expansion support in `mcp.json`, so it
stays a plain value in `~/.gjc/agent/mcp.json` (0600); a key rotation for it is flagged to the
operator as follow-up, not part of this migration.

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

### `~/.gjc-relay` (gjc-relay) — detail in [35-gjc-relay.md](35-gjc-relay.md#state-directory-the-durability-surface)

Purely a **runtime home**: `gjc-relay` binary (built from the `relay/` subdir of the
`engels74-bot/gjc-fleet` monorepo at `~/github/engels74-bot/gjc-fleet/relay` and copied here),
**`design-system.json`** (shared styling source of truth, **version 2** since the notification
overhaul), `relay.env`, the supervision scripts (`dlq-watch.sh`, `alert.sh`,
`check-kind-coverage.sh`, and — new in v2 — `relay-heartbeat.sh`, `relay-health-watch.sh`),
`.omc/`, and — **new in v2** — the `state/` directory. `relay.env` is a rendered artifact
(`render/render.sh` target, 0600) rather than hand-maintained. Its keys are `RELAY_BIND`,
`RELAY_DESIGN_SYSTEM`, `GJC_ALERT_CHANNEL` (host-local numeric ID for `#gjc-approvals`), plus the v2
managed-path keys appended by `render.sh`: `RELAY_STATE_DIR`, `RELAY_MANAGED_RATE` (preset or
`<t>/<w>s`), `RELAY_WORKITEM_CHANNELS` (comma-joined opt-in channel IDs from per-repo
`workitem_surface = true` plus any `[relay].workitem_channels` extra channel names; **rendered empty
by default** ⇒ managed path OFF ⇒ byte-identical v1), `GJC_LAB_CHANNEL` (host-local canary ID for the heartbeat),
and any optional per-channel `RELAY_DEBOUNCE_SECS__<cid>` pins. Values are host-local; the numeric
channel IDs live only in the rendered file and `fleet.toml`, never in the tracked template. Since the 2026-07-07 gjc-fleet
monorepo migration folded the source's brief standalone `engels74-bot/gjc-relay` repo into
`gjc-fleet`, no separate relay repo remains — git history preserved via merge.

**`~/.gjc-relay/state/`** (v2 durability surface, `RELAY_STATE_DIR`, mode 0700 by convention) — this
is where the managed work-item path keeps its durable delivery state. `state.json` is a crash-recovery
**cache** of the registry (anchor message ids + facets + a dedup ledger; `version:2`), written
atomically (tmp + fsync + rename) and **quarantined** to `state.json.corrupt-<epoch>` on a parse/version
mismatch rather than crashing the relay. The **delivery source of truth** is `queue/`: one
`<epoch_ms>-<seq>-<opclass>.json` op file per pending Discord operation, fsync'd **before** the relay
acks clawhip, plus a sibling `<op>.json.committed` marker (message_id + fingerprint + delivered_at)
fsync'd before the op file is unlinked. Ops that exhaust their retry budget / exceed
`RELAY_DELIVERY_MAX_AGE_SECS` / overflow `RELAY_QUEUE_CAP` / hit a 403 are moved to `dead/`.
`flush.alive` is a mtime-only liveness marker the flush thread touches every tick (read by
`relay-health-watch.sh`). **No auth token is ever written to any file under `state/`** — the bot token
lives in memory only. Mechanism detail: [35-gjc-relay.md](35-gjc-relay.md#the-v2-managed-work-item-path).

### `~/.gjc-bot` (gjc-bot state) — detail in [40-gjc-bot-automation.md](40-gjc-bot-automation.md#env--config-surface)

Renamed from `~/.repo-bot` on 2026-07-07 (together with `REPO_BOT_*` → `GJC_BOT_*`), so the
state dir now matches the component name.

| File | Purpose |
|---|---|
| `issue-spool.jsonl` | Input queue — clawhip appends `github.issue-opened` records (JSONL) |
| `issues.jsonl` | Dedup ledger of processed issues (terminal states `dispatched`/`skipped`) |
| `reviews.jsonl` | Seen-set ledger for review-detector (marked on every poll) |
| `merge-gate.jsonl` | Per-`repo#pr#sha` dedup ledger for merge-gate verdicts |
| `review-policy.jsonl` | One-review policy ledger for automated-author PRs (renovate/dependabot). Append-only, keyed on the PR: `<repo>#<pr>#consumed` (exactly-once "this PR was policy-handled" marker), `<repo>#<pr>#decision:<APPLY\|DISMISS\|ESCALATE>`, `<repo>#<pr>#escalated`, plus the force-push re-arm keys `#policy-pushed:<sha>` / `#rearm:<sha>` (Workstream D, bounded by `REVIEW_POLICY_MAX_REARMS`). |
| `ci-fixer.jsonl` | Fix-until-green loop ledger. Keys: `#pr:<pr>#try` and `#sha:<sha>#try` (per-PR / per-sha attempt counters bounding the loop), `#gaveup` (a cap was hit), and `#outcome:{fixed\|unchanged\|stale\|timeout}` (terminal result of an attempt). |
| `automerge.jsonl` | Automerge lane ledger (Workstream F). Keys: `#pr:<pr>#try` (attempt count), `#pr:<pr>#merged:<sha>` (terminal success), `#pr:<pr>#blocked` (terminal give-up, dedup for the one `automerge.escalation` embed). |
| `gjc.lock` | Single-flight lock for the gjc run lane (held by `_exec` fd 9 for a run's lifetime; also taken by the janitor per pass) |
| `review.lock` | Global single-flight lock taken **non-blocking** by the review-run handler **and** merge-gate (mutual exclusion) |
| `review-<repo>.lock` | Per-repo lock (Workstream K1) nested inside `review.lock` by the review-run handler; taken alone (non-blocking) by the policy lane's deferred-mark, and taken **blocking** by ci-fixer/automerge — deadlock-free by construction since ci-fixer/automerge never blocking-acquire the global lock while holding this one |
| `issues.lock`, `merge-gate.lock`, `reviews.lock` | Per-lane pass locks |
| `<lane>-poll.lock` (`review-detector-poll.lock`, `ci-fixer-poll.lock`, `merge-gate-poll.lock`, `automerge-poll.lock`) | Workstream K5 — per-loop script-level single-flight, taken non-blocking at poll entry; contention exits 0 quietly |
| `adapter.log`, `gjc-run.log`, `review.log`, `merge-gate.log`, `ci-fixer.log`, `automerge.log`, `fleet-update.log`, `janitor.log` | Per-lane logs |
| `logs/<lane>-<repo>-pr<NN>-<ts>.log` | Per-run engine log directory — one file per bounded coding-engine invocation (review handler / ci-fix run), pruned by the janitor's log-prune pass (entries older than 14 days deleted; the shared lane logs above are size-capped, not deleted) |
| `state/hermes-prev-ref`, `state/hermes-deployed-ref` | Workstream G — `hermes-update.sh`'s pre-update ref record (rollback target) and last-successful-deploy ref record |
| `archive/` | Tarballs of legacy dated `.bak-*` files, archived by a hand-run sweep once >30 days old **and** `render.sh diff` clean (a documented policy, not an automated job) — see [The three-layer config model](#the-three-layer-config-model-since-2026-07-07) for the policy |
| `prompt-*.md` | Transient per-run prompt files (created by `gjc-run.sh launch`, removed by `_exec`) |
| `ci-fixer.disable`, `automerge.disable`, `fleet-update.disable` | Host-local kill-switch markers, one per default-OFF lane: presence disables that lane regardless of its `[...]_ENABLED` knob (one of each lane's independent off-switches, alongside its config flag and `DRY_RUN`) |
| `gjc-bot.env` | Rendered, 0600 env file, loaded via each unit's `EnvironmentFile=-%h/.gjc-bot/gjc-bot.env`. Carries the per-lane Discord channel defaults (`ISSUE_NOTIFY_CHANNEL`/`MERGE_GATE_CHANNEL`/`REVIEW_NOTIFY_CHANNEL`, numeric IDs never in the scripts) plus every non-numeric-ID knob from `[review]`/`[review.policy]`/`[ci_fixer]`/`[merge]`/`[janitor]`/`[updates]` in `fleet.toml` (`REVIEW_ENGINE`, `REVIEW_POLICY_*`, `CI_FIXER_*`, `AUTOMERGE_*`, `JANITOR_TMUX_*`, `TOOL_UPDATE_ENABLED`/`QUIESCE_TIMEOUT_MINS`) — config truth, zero hand-pins; see [45-fleet-config.md](45-fleet-config.md#rendered-env-vars-b-2b-3--relay-v2) for the full knob reference. |

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

## systemd units (templates vs rendered/installed)

**Rewritten 2026-07-07 (gjc-fleet monorepo + user-units migration).** Unit *templates* now live at
the `gjc-fleet` repo **root** `systemd/` (`~/github/engels74-bot/gjc-fleet/systemd/` — one level
above `pipeline/`, since these units span gjc-bot, clawhip, and the relay, not just the pipeline).
`render/render.sh apply --units` fills each `{{FLEET_REPO}}`/`%h`-style placeholder and installs the
result to **`~/.config/systemd/user/`** — every fleet unit is now a **user unit**
(`WantedBy=default.target`, linger enabled so they start without a login session, no `sudo`
anywhere in the lifecycle). All four gjc-bot `ExecStart=` resolve under
`~/github/engels74-bot/gjc-fleet/pipeline/<subfolder>/` — `intake/issue-spool-adapter.sh`,
`review/review-detector.sh`, `review/merge-gate.sh`, `maintenance/gjc-worktree-janitor.sh` (each
last run `Result=success`). The relay-stack units (`gjc-relay.service`, `gjc-dlq-watch.service`,
`gjc-relay-alert.service`, the `clawhip.service.d/10-gjc-relay.conf` drop-in) and `clawhip.service`
are rendered + installed the same way.

**`hermes-gateway.service` is the one exception**: it is **regenerated** by `hermes gateway
install`, which `hermes_cli` natively runs in user scope (and handles its own linger enablement) —
the renderer does not own it. `gjc-fleet/systemd/hermes-gateway.service.ref` is kept purely as a
**non-installable reference copy** for diffing, marked `# REFERENCE ONLY — DO NOT INSTALL FROM
HERE` in its header.

**Old system-level units: removed 2026-07-08.** The pre-migration units under
`/etc/systemd/system/` were `disable`d at cutover and deleted the following day (operator skipped
the planned soak); `/etc` now carries zero fleet units. The old repo checkouts were renamed
`*.retired` in the same pass and a fresh backup snapshot taken. `render/render.sh doctor` and
`~/scripts/backuprestore/restore.sh` remain dual-scope defensively (see
[Backups & rollback](#backups--rollback)). Full service map:
[70-deployment-and-operations.md](70-deployment-and-operations.md#service-map).

## Backups & rollback

`~/scripts/backuprestore/{backup-now.sh,restore.sh}` — snapshot + full-revert tooling; every
Phase-G/relay artifact is registered for teardown (`restore.sh --apply`, optional
`--purge-repos`): `backup-now.sh` `copy_if`s `~/.gjc-relay` (runtime home) and `restore.sh` tears
down the three relay-stack units, the clawhip ordering drop-in, `~/.gjc-relay`, and the now-gone
`~/.gjc-relay-build` (a harmless no-op). The dated `.bak-*` files across `~/.clawhip` and
`~/.hermes` are per-wave inline backups, distinct from this snapshot tooling — the pipeline scripts
carry no `.bak-*` files (git-managed, now inside `gjc-fleet`).

**Rewritten 2026-07-07 (gjc-fleet monorepo + user-units migration):** `restore.sh` is now
**dual-scope** — it tears down user-scope units first (`systemctl --user disable --now`, per unit
name), then any leftover `/etc/systemd/system/` units from the pre-migration system-level install
(`sudo systemctl disable --now` + `rm -f`), running `daemon-reload` in both scopes; this reflects
the fleet's transitional state during the 24–48 h soak before the old system units are deleted for
good (see [systemd units](#systemd-units-templates-vs-renderedinstalled)). The stale `rm -rf
~/scripts/repo-bot` line (`restore.sh:137` in earlier passes) has been **removed** — that dead path
resolution is no longer needed. `backup-now.sh`'s manifests were consolidated: the separate
`gjc-bot-scripts-repo.txt`/`gjc-relay-repo.txt` lines were replaced by one whole-`gjc-fleet`-repo
manifest (`ls -laR` excluding `target/`/`.git/`), and a new `systemd-user-stack-units.txt` listing
(`systemctl --user list-unit-files 'hermes*' 'clawhip*' 'gjc-*' 'issue-*' 'review-*' 'merge-*'`) sits
alongside the pre-existing system-scope listing.

## Open questions

- `~/.hermes/verification_evidence.db` schema/purpose.
- `~/.gjc-relay/.omc/` contents.

## Changelog

- 2026-07-09 (v2-current-state rewrite) — Doc set rebaselined to current state; prior history in git.
  This page: added the new `~/.gjc-bot` state artifacts (`automerge.jsonl` ledger; `state/hermes-*`
  prev-ref/deployed-ref records; the per-run `logs/<lane>-<repo>-pr<NN>-<ts>.log` directory;
  `review-<repo>.lock` and the per-lane `poll.lock` files; `automerge.disable`/`fleet-update.disable`
  markers), summarized (cross-linked to 45 rather than duplicated) the new `[merge]`/`[janitor]`/
  `[updates]` knobs now rendered into `gjc-bot.env`, and pruned the resolved backup-coverage open
  question.
