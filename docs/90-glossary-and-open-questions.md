<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/.omc/ (progress.txt, plans/discord-unification-plan.md, research/discord-unification-findings.md)
  - all component pages in this directory
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  When a component page resolves one of the open questions below, delete it here and
  note the resolution in that page's changelog.
-->

# Glossary & open questions

## Glossary

| Term | Meaning |
|---|---|
| **gjc / gajae-code** | The coding-agent harness (goal → patch → checks → PR), worktree-isolated, tmux-capable; binary `~/.bun/bin/gjc`. [10-gajae-code.md](10-gajae-code.md) |
| **robogjc** | A *deliverable inside the gajae-code repo* (`python/robogjc/`): a self-hosted GitHub triage-and-fix bot driving `gjc --mode rpc`. **Not deployed on this machine** — the live issue lane is gjc-bot's shell pipeline. (Neither the earlier build-log nor `.omc` mentioned it; earlier confusion treating it as an alias for the automated lane is resolved.) |
| **hermes / hermes-agent** | Python messaging/orchestration agent (Nous Research); runs the Discord gateway, cron, kanban. [20-hermes-agent.md](20-hermes-agent.md) |
| **GJC Brain** | The hermes Discord bot identity — the conversational brain the user talks to |
| **GJC Clawhip** | The clawhip Discord bot identity — post-only notifier |
| **clawhip** | Rust event-to-Discord router: polls GitHub, receives CLI/HTTP events, routes to sinks; daemon on 127.0.0.1:25294. [30-clawhip.md](30-clawhip.md) |
| **gjc-relay** | Locally-authored Rust loopback proxy on 127.0.0.1:25295 that rewrites clawhip's plain-text Discord REST calls into rich embeds. Source lives in the `relay/` subdir of the `engels74-bot/gjc-fleet` monorepo (`~/github/engels74-bot/gjc-fleet/relay`, since the 2026-07-07 monorepo migration; briefly its own repo before that); runtime home `~/.gjc-relay`. **Post-dated the earlier build-log (now retired), which never mentioned it.** [35-gjc-relay.md](35-gjc-relay.md) |
| **relay (hermes sense)** | A hermes-native messaging *platform type* (`gateway/relay/`) — a WebSocket transport, **unrelated to gjc-relay**. Naming collision; always disambiguate |
| **gjc-bot** | The shell glue layer sequencing issue → run → review → merge-gate. Lives in the `pipeline/` subdir of the `gjc-fleet` monorepo (`~/github/engels74-bot/gjc-fleet/pipeline/`, since 2026-07-07; previously its own repo, `gjc-bot-scripts`); the old `~/scripts/repo-bot/` path is dead. Formerly written "repo-bot"; the state dir and env prefix were renamed to match on 2026-07-07 (`~/.repo-bot` → `~/.gjc-bot`, `REPO_BOT_*` → `GJC_BOT_*`). [40-gjc-bot-automation.md](40-gjc-bot-automation.md) |
| **gjc-fleet** | The monorepo (since 2026-07-07) consolidating what were four separate repos: the gjc-bot pipeline (`pipeline/`, ex-`gjc-bot-scripts`), the relay crate (`relay/`, ex-`gjc-relay`), this doc set (`docs/`, ex-`gjc-architecture`), plus new `render/` (the fleet.toml renderer) and `systemd/` (shared unit templates) directories. `~/github/engels74-bot/gjc-fleet/`. The three predecessor repos are archived on GitHub with pointer READMEs; history preserved via merge. [00-overview.md](00-overview.md#where-each-component-lives-and-runs) |
| **gjc-bot-scripts** | The repo that formerly held the gjc-bot shell pipeline (itself renamed from `engels74-bot/gjc-bot` on 2026-07-07, reorganized by pipeline stage). **Archived 2026-07-07** — merged into `gjc-fleet` as its `pipeline/` subdir (history preserved); the repo now carries only a pointer README. Scripts still self-locate their root via `SCRIPTS_DIR` (`GJC_BOT_SCRIPTS` override still honored), now resolving inside `gjc-fleet/pipeline/`. [40-gjc-bot-automation.md](40-gjc-bot-automation.md) |
| **fleet.toml** | `~/.config/gjc-fleet/fleet.toml` — the untracked, host-local, 0600 config file that is layer 2 of the fleet's three-layer config model: operator identity, the `[discord.channels]` name→numeric-ID map, path overrides, version `[pins]`, `[secrets]` pointers (names only). Never committed; `fleet.toml.example` in the repo is its documented, value-free template. [45-fleet-config.md](45-fleet-config.md) · [50-configuration-and-state.md](50-configuration-and-state.md#the-three-layer-config-model-since-2026-07-07) |
| **renderer / render.sh** | `gjc-fleet/render/render.sh` — turns `fleet.toml` + repo-tracked templates into layer-3 rendered artifacts (config files, env files, and, since 2026-07-07, every fleet systemd unit). Subcommands: `render`, `diff`, `apply [--units]`, `check` (CI gate), `doctor` (checks hermes-owned files it deliberately doesn't render). Replaces the historical dated `.bak-*` hand-edit convention going forward. [45-fleet-config.md](45-fleet-config.md) |
| **stackman / server-script / gjc-server-tool** | The Textual TUI ops console (Python). Repo/dir renamed `engels74-bot/server-tool` → `engels74-bot/gjc-server-tool` on 2026-07-07 (`~/github/engels74-bot/gjc-server-tool/`); the Python package `server_script` and the `stackman`/`server-script` console entrypoints are unchanged. Not part of the automated pipeline, and **not** folded into the `gjc-fleet` monorepo (it remains its own repo). |
| **fleet / fleet clone root** | `~/github/engels74-bot/fleet/` — the subfolder holding every pipeline-owned working copy (the six app clones, their `*.gajae-code-worktrees/` buckets, the `review/` checkouts) since 2026-07-07. The scripts' `GH_ROOT`, clawhip's `[[monitors.git.repos]] path`s, and hermes' `GJC_COORDINATOR_MCP_WORKDIR_ROOTS`/`terminal.cwd` all point here; the root of `~/github/engels74-bot/` holds only the bot's own `gjc-*` repos (now just `gjc-fleet` and `gjc-server-tool`). Not to be confused with `fleet.toml` (a config file, not a directory). |
| **GJCEMBED1** | The delimiter-envelope prefix (`GJCEMBED1 key=value … :: tail`) that marks a message for embed rendering by gjc-relay |
| **design system** | `~/.gjc-relay/design-system.json` — the single styling source (event kind → color/emoji/title) shared by the relay and `discord-embed.sh`; live copy canonical, versioned as `runtime/design-system.json` in the gjc-relay repo |
| **DLQ / bury** | clawhip's dead-letter queue: in-memory only; a "buried" notification is permanently lost. `gjc-dlq-watch` alarms on it |
| **spool** | `~/.gjc-bot/issue-spool.jsonl` — the JSONL queue clawhip writes `github.issue-opened` records to; the pipeline's inbox |
| **merge gate** | Advisory, comment-only LLM verdict on CI-green bot PRs (`MERGE_READY`/`REQUEST_CHANGES`); never merges |
| **the janitor / reap** | `gjc-worktree-janitor.sh` (crash-net for orphaned run worktrees) and `gjc-reap.sh` (manual tree-kill of a jammed run) |
| **single-flight** | The `flock`-based one-run-at-a-time discipline per lane (`gjc.lock`, `review.lock`) |
| **engels74-bot** | The dedicated bot GitHub identity (Write collaborator) authoring all automated PRs |
| **augmentcode[bot]** | External GitHub app that auto-reviews PRs; its "N suggestions" reviews trigger the review lane |
| **Coordinator MCP** | gjc's outward MCP control plane (`gjc mcp-serve coordinator`) — how hermes drives gjc |
| **brain model** | The cheap **no-tools** LLM for gjc-bot triage/merge verdicts: `minimax/minimax-m3` via NanoGPT (formerly DeepSeek in the earlier build-log's plan). Since 2026-07-07 hermes' *conversational* brain is separate: `gpt-5.5` via the OpenAI Codex subscription ([20-hermes-agent.md](20-hermes-agent.md#purpose)) |
| **oh-my-pi / pi-*** | gajae-code's upstream lineage (`can1357/oh-my-pi`); explains `pi-natives`, `PI_ROOT`, and stale `can1357` URLs |
| **Phase A–G** | The incremental build phases from the earlier hermes-stack build-log (now retired): jq → hermes brain → bot identity → Discord → clawhip → gjc → automation + 6-repo fan-out |
| **Discord unification** | The 2026-07-06 evening wave (`.omc` plan/progress) that added gjc-relay, route templates, `discord_embed`, and the SOUL.md voice alignment |

## The 2026-07-06/07 configuration waves (backup-file timeline)

Dated `.bak-*` files pin the order: `phaseg` (16:48) → `g7` (18:31, issue-spool route + 6-repo
fan-out) → `discord` (20:49–21:35, relay + templates + embed helper) → `yolo`/`workdir`/`workspace`
(23:19–23:25, hermes approvals-off + terminal.cwd + SOUL.md workspace rules) →
`embedbatch` (2026-07-07 01:52, post-EasyHDR-RUSTSEC run: clawhip issue/CI embed routes, relay
multi-envelope batch splitting, design-system 17→23 kinds). Separately on 2026-07-07 (~13:00,
no `.bak` marker): hermes' brain model switched from NanoGPT/`minimax-m3` to the Codex
subscription (`gpt-5.5`, OAuth via `auth.json`). The earlier build-log's Phase G log ended before
the discord wave — which is why that (now-retired) log never mentioned the relay.

**2026-07-07 repo-move wave (no `.bak` markers — git-tracked renames).** Two GitHub repos were
renamed and the pipeline scripts relocated: `engels74-bot/gjc-bot` → **`gjc-bot-scripts`** (flat dir
reorganized into `intake/`, `run/`, `review/`, `maintenance/`, `lib/`, `systemd/`) and
`engels74-bot/server-tool` → **`gjc-server-tool`** (the stackman TUI console; package/entrypoints
unchanged). The old `~/scripts/repo-bot/` tree is gone; scripts now self-locate their repo root
(`SCRIPTS_DIR` derived from `BASH_SOURCE`, fixing a runtime break where `issue-spool-adapter` could
not source `lib/discord-embed.sh`). The four gjc-bot systemd units were reinstalled to
`/etc/systemd/system/` (`ExecStart=` under `…/gjc-bot-scripts/<subfolder>/`, `daemon-reload`, all
`Result=success`), and the hermes cron real-file wrappers re-`exec` the new subfolder paths. These
architecture docs also moved from `~/documentation/architecture/` into the `gjc-architecture` git
repo (a stale copy remains under `~/documentation/architecture/`).
> [inferred] The `~/documentation/architecture/` copy is a pre-move leftover, not a maintained fork.

**2026-07-07 fleet/ move + component rename (`.bak-fleetmove-*` markers in `~/.clawhip` and `~/.hermes`).**
The six working clones, their `*.gajae-code-worktrees/` buckets, and the `review/` checkouts moved
from `~/github/engels74-bot/` into `~/github/engels74-bot/fleet/`, leaving the root to the bot's
own `gjc-*` repos. Re-pointed in the same wave: all eight scripts' `GH_ROOT` default
(gjc-bot-scripts commit `59142f9`), clawhip's six `[[monitors.git.repos]] path`s, hermes'
`GJC_COORDINATOR_MCP_WORKDIR_ROOTS` + `terminal.cwd` + SOUL.md workspace conventions; the two git
worktree link files were repaired to the new absolute paths, clawhip + hermes-gateway restarted,
and all lanes re-verified live. The doc set simultaneously settled the component name **gjc-bot**
(formerly written "repo-bot"; page 40 renamed accordingly — and the on-disk rename followed the
same evening: `~/.gjc-bot` → `~/.gjc-bot`, `GJC_BOT_*` → `GJC_BOT_*`, the spool sink, path
unit, and backup tooling re-pointed).

**2026-07-07 gjc-relay repo adoption (no `.bak` markers — git is the history now).** The last
un-versioned component gained a repo: the relay crate moved from `~/.gjc-relay/src` (built in
place) into **`engels74-bot/gjc-relay`** at `~/github/engels74-bot/gjc-relay` (crate +
`runtime/` copies of the authored runtime artifacts + README + prek.toml; pushed, public like its
siblings). Rebuilt from the repo (17 tests, binary byte-identical to the deployed one),
redeployed with a ~1 s restart, canary-verified in `#gjc-lab`; then
`~/.gjc-relay/{src,Cargo.toml,Cargo.lock,target}`, the `.bak-embedbatch-*` files, and
`~/.gjc-relay-build` were removed, leaving `~/.gjc-relay` a pure runtime home like
`~/.clawhip`/`~/.hermes`. `backup-now.sh` gained a manifest line for the new repo.

**2026-07-07 gjc-fleet monorepo + user-units migration (later the same day; no `.bak` markers —
git merges are the history).** Three repos — the just-adopted `gjc-relay`, the reorganized
`gjc-bot-scripts`, and this doc set's `gjc-architecture` — were consolidated into one monorepo,
**`engels74-bot/gjc-fleet`** (`pipeline/` `relay/` `render/` `systemd/` `docs/`), each old repo
archived on GitHub with a pointer README, full history preserved via merge. A new **three-layer
config model** was introduced: `gjc-fleet` templates → host-local, untracked
`~/.config/gjc-fleet/fleet.toml` → rendered artifacts, produced by the new `render/render.sh`
(`render|diff|apply|check|doctor`), which replaces the historical dated `.bak-*` hand-edit
convention going forward. Every fleet systemd unit — clawhip, the full relay supervision stack,
and all four gjc-bot units — moved from system-level (`/etc/systemd/system/`) to **user-scope**
(`~/.config/systemd/user/`, linger enabled, no `sudo`); unit templates moved to `gjc-fleet`'s
repo-root `systemd/`. `hermes-gateway.service` was the one exception, regenerated in user scope by
`hermes gateway install` itself. `gjc-relay.service`'s hardening changed as part of the move:
`ProtectSystem`/`ProtectHome`/`PrivateTmp` dropped (unprivileged user namespaces are a start-failure
risk under Ubuntu ≥24.04's AppArmor restriction) in favor of namespace-free directives
(`NoNewPrivileges`, `RestrictRealtime`, `LockPersonality`, `SystemCallArchitectures=native`,
`RestrictNamespaces`, `MemoryDenyWriteExecute`). The three previously hard-coded numeric Discord
channel defaults in the pipeline scripts were removed from the repo entirely, replaced by a
hard-fail-unless-set contract against a new rendered `~/.gjc-bot/gjc-bot.env`. Old system-level
units were disabled but left on disk pending a 24–48 h soak + reboot test before final removal;
`~/scripts/backuprestore/restore.sh` was made dual-scope for the transition and had its stale
`rm -rf ~/scripts/repo-bot` line removed. Separately, a hermes hygiene pass fixed a stale cron
workdir and removed the drifting, spend-drift-failing `monitor-easyhdr-pr115-rustsec` cron job
(resolving the corresponding open questions on
[20-hermes-agent.md](20-hermes-agent.md#the-cron-subsystem) and
[70-deployment-and-operations.md](70-deployment-and-operations.md#open-questions)). Verified live
end-to-end: five pipeline triggers (timers + the path unit, ≤4 s fire on spool append, all
`Result=success`); a 2-second relay+clawhip cutover behind a `healthz` gate plus a full DLQ drill
(relay stopped → doomed canary → DLQ-bury observed in the user journal → `gjc-dlq-watch` alerted
`#gjc-approvals` in ~6 s → relay restored → post-drill canary 200); `hermes-gateway.service`
regenerated as a user unit in ~4 s with its `RestartForceExitStatus=75`/`KillMode=mixed`/
`ExecStopPost` semantics intact; the relay binary rebuilt from the monorepo (17 tests,
`RELAY_DESIGN_SYSTEM` default now `$HOME`-derived). `/home/cvps` was eliminated from the
pipeline/relay scripts in favor of `$HOME`-derived paths as part of the same portability push.

## Open questions

This page's list is the consolidated, system-wide set (the anchor `#open-questions` here is the
canonical link target).

Highest-signal first. Per-page questions are also listed on each component page.

1. ~~**Missing review-handler template**~~ — **Resolved 2026-07-06**: recreated as an
   architecture-native one-shot rewrite (detector as outer loop, trigger-comment re-review,
   battle-tested GitHub command blocks retained); **live-verified 2026-07-07** with two clean
   back-to-back handler runs on easyhdr#115. See
   [40-gjc-bot-automation.md](40-gjc-bot-automation.md#discrepancies). Residual unknown: why
   the original vanished.
2. **Relay permanence & reliability posture** — is gjc-relay (in-path single point of failure for
   all notifications, compensated only by infinite-restart + out-of-band alarms) the intended end
   state, or is a persistent DLQ/retry layer planned? ([35-gjc-relay.md](35-gjc-relay.md#open-questions))
3. **Interactive-vs-automated lane asymmetry** — the coordinator (hermes→gjc) lane bypasses the
   single-flight launcher by explicit user choice; can it collide with the automated lane on the
   same repo (worktrees differ, but clones/remotes/branches are shared)?
   ([60-data-flow-and-integration.md](60-data-flow-and-integration.md#open-questions))
4. **Cross-lane push races on shared PR branches** — no longer hypothetical: observed 2026-07-07
   on easyhdr#115 (a hermes-delegated gjc session and the review handler pushing the same PR
   branch with no shared lock). Behaviorally mitigated via `~/.hermes/SOUL.md` rebase-before-push
   rules; a structural lock is still open.
   ([40-gjc-bot-automation.md](40-gjc-bot-automation.md#open-questions))
5. **`gjc-reap.sh` wiring** — header claims a clawhip `tmux.stale` trigger that doesn't exist;
   manual-only today. Re-enable the route (and tmux monitors), or update the header?
6. **Kanban's role** — the board exists and the dispatcher machinery is rich, but the live
   pipeline bypasses it. Idle capacity or future direction?
   ([20-hermes-agent.md](20-hermes-agent.md#open-questions))
7. ~~**`restore.sh` still purges the dead script path**~~ — **Resolved 2026-07-07 (gjc-fleet
   monorepo + user-units migration):** the stale `rm -rf ~/scripts/repo-bot` line has been removed
   from `~/scripts/backuprestore/restore.sh`. The same pass made `restore.sh` dual-scope (user
   units torn down first, then any `/etc/systemd/system/` leftovers from the pre-migration
   system-level install) and consolidated `backup-now.sh`'s manifests around the new `gjc-fleet`
   monorepo layout. ([50-configuration-and-state.md](50-configuration-and-state.md#backups--rollback))
8. **Relay reliability under the new hardening** — `gjc-relay.service` dropped namespace-based
   sandboxing (`ProtectSystem`/`ProtectHome`/`PrivateTmp`) on 2026-07-07 in favor of
   namespace-free directives, to avoid an AppArmor-related start-failure risk under user-scope
   systemd on Ubuntu ≥24.04. Verified live via a full cutover + DLQ drill, but the trade-off
   (weaker filesystem isolation for a in-path single point of failure) is a standing judgment
   call, not a fully closed question. ([35-gjc-relay.md](35-gjc-relay.md#open-questions))
9. **Old system-level units: soak period and final removal** — the pre-2026-07-07 `/etc/systemd/
   system/` units are disabled but intentionally left on disk for a 24–48 h soak plus a reboot
   test before deletion (and the old repo checkouts renamed `*.retired`). Tracking item: confirm
   the soak completed cleanly, then delete.
   ([70-deployment-and-operations.md](70-deployment-and-operations.md#open-questions))
10. Smaller items tracked on component pages: `gpu_cache.json` consumer (gjc);
    `verification_evidence.db` purpose (hermes); `~/.gjc-relay/.omc/` contents; slack sink usage
    (clawhip); Codex-subscription rate/usage limits for the new brain model (NanoGPT fair-use
    question is moot while on Codex); unread gjc subcommand handlers
    (`harness`, `gc`, `migrate`, `codex-native-hook`, `local-provider`); `missing_for_write` errors
    in gjc logs; whether `review.lock` sharing between merge-gate and review-run is a deliberate
    contract (40); hermes gateway `relay/` ingestion configured or not (20); clawhip's `gajae`
    handler seam wiring and its two-minor-stale upstream `ARCHITECTURE.md` (30); relay fallback
    "Option C" activation conditions (35); Bridge/ACP production readiness (10); `EXA_API_KEY`
    rotation, flagged to the operator during the 2026-07-07 migration but not yet actioned.

## Changelog

- 2026-07-06 — Initial draft; consolidated open questions from all pages; resolved the "robogjc"
  ambiguity (repo deliverable, not deployed).
- 2026-07-06 (later) — Open question #1 resolved: review-handler template restored
  (architecture-native rewrite).
- 2026-07-07 — Verification/consolidation pass: wave timeline extended through `yolo`/`workdir`/
  `workspace` and `embedbatch` plus the Codex brain switch; OQ#1 residual updated (template
  live-verified); new OQ#4 cross-lane push race (observed on easyhdr#115); catch-all item
  broadened to cover the component-page questions it was missing; brain-model glossary entry and
  runbook-staleness #2 updated for the Codex switch.
- 2026-07-07 (repo-move pass) — Status → verified. Recorded the 2026-07-07 repo renames
  (`gjc-bot` → `gjc-bot-scripts`, `server-tool` → `gjc-server-tool`), the stage-based script
  reorg, and script self-location in a new wave-timeline entry; added `gjc-bot-scripts` and
  `stackman/gjc-server-tool` glossary rows; reconciled the `gjc-bot` glossary entry off the dead
  `~/scripts/repo-bot/` path. New OQ#8: `restore.sh:137` `rm -rf ~/scripts/repo-bot` no-op
  (catch-all renumbered 8→9). Fixed runbook path drift (`~/documentation/…` → `~/downloads/…`).
- 2026-07-07 (runbook-retirement pass) — The earlier hermes-stack build-log/runbook has been
  deleted; this doc set is now the single source of truth. Removed it from `sources`, deleted the
  "Runbook staleness" section (its live facts survive in the brain-model glossary row and
  [30-clawhip.md](30-clawhip.md)), and removed OQ "Runbook's future" (remaining OQs renumbered
  7→8's neighbours: old #8/#9 → #7/#8). Reframed the robogjc, gjc-relay, brain-model, and Phase A–G
  glossary rows plus the wave-timeline note to past tense ("earlier build-log, now retired").
- 2026-07-07 (fleet/ move + component rename) — Glossary: gjc-bot entry notes the historical
  "repo-bot" working name (kept by `~/.repo-bot` + `REPO_BOT_*`); new **fleet / fleet clone root**
  entry; new wave-timeline paragraph for the fleet/ move. Page-40 cross-links renamed.
- 2026-07-07 (state-dir rename) — gjc-bot glossary entry and spool term updated: the on-disk
  rename (`~/.repo-bot` → `~/.gjc-bot`, `REPO_BOT_*` → `GJC_BOT_*`) completed the gjc-bot
  naming; wave-timeline paragraph amended accordingly.
- 2026-07-07 (gjc-relay repo adoption) — gjc-relay glossary entry gained its source repo
  (`engels74-bot/gjc-relay`); design-system entry notes the versioned `runtime/` copy (live copy
  canonical). New wave-timeline paragraph for the repo adoption: crate moved out of the
  un-versioned `~/.gjc-relay/src` into the pushed repo, rebuilt/redeployed/canary-verified, and
  the runtime dir stripped to a pure runtime home.
- 2026-07-07 (gjc-fleet monorepo + user-units migration) — New glossary entries: **gjc-fleet**
  (the monorepo), **fleet.toml** (layer-2 host config), **renderer / render.sh**. Updated
  **gjc-relay** and **gjc-bot** entries to point at their new `gjc-fleet` subdirs; **gjc-bot-scripts**
  reframed as archived/historical (merged into `gjc-fleet/pipeline`); **stackman/gjc-server-tool**
  entry notes it stayed a separate repo, not folded into `gjc-fleet`; **fleet / fleet clone root**
  entry disambiguated from `fleet.toml`. New wave-timeline paragraph for the migration itself
  (monorepo consolidation of three repos, three-layer config model, full system→user systemd
  cutover, relay hardening change, channel-ID removal from pipeline scripts, dual-scope
  backup/restore tooling, live verification evidence). Open questions: resolved #7 (`restore.sh`
  dead-path line, now removed); added #8 (relay hardening trade-off under the new sandboxing) and
  #9 (old system-unit soak/removal tracking), renumbering the catch-all to #10 and adding the
  `EXA_API_KEY` rotation follow-up to it; resolved the hermes PR-115 cron-drift question in the
  same pass (job removed from `jobs.json`, cited from pages 20/70 rather than re-listed here).
