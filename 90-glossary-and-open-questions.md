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
| **robogjc** | A *deliverable inside the gajae-code repo* (`python/robogjc/`): a self-hosted GitHub triage-and-fix bot driving `gjc --mode rpc`. **Not deployed on this machine** — the live issue lane is repo-bot's shell pipeline. (Neither the earlier build-log nor `.omc` mentioned it; earlier confusion treating it as an alias for the automated lane is resolved.) |
| **hermes / hermes-agent** | Python messaging/orchestration agent (Nous Research); runs the Discord gateway, cron, kanban. [20-hermes-agent.md](20-hermes-agent.md) |
| **GJC Brain** | The hermes Discord bot identity — the conversational brain the user talks to |
| **GJC Clawhip** | The clawhip Discord bot identity — post-only notifier |
| **clawhip** | Rust event-to-Discord router: polls GitHub, receives CLI/HTTP events, routes to sinks; daemon on 127.0.0.1:25294. [30-clawhip.md](30-clawhip.md) |
| **gjc-relay** | Locally-authored Rust loopback proxy on 127.0.0.1:25295 that rewrites clawhip's plain-text Discord REST calls into rich embeds. **Post-dated the earlier build-log (now retired), which never mentioned it.** [35-gjc-relay.md](35-gjc-relay.md) |
| **relay (hermes sense)** | A hermes-native messaging *platform type* (`gateway/relay/`) — a WebSocket transport, **unrelated to gjc-relay**. Naming collision; always disambiguate |
| **repo-bot** | The shell glue layer sequencing issue → run → review → merge-gate. Lives in the `gjc-bot-scripts` repo (`~/github/engels74-bot/gjc-bot-scripts/`); the old `~/scripts/repo-bot/` path is dead. [40-repo-bot-automation.md](40-repo-bot-automation.md) |
| **gjc-bot-scripts** | The repo holding the repo-bot shell pipeline (renamed from `engels74-bot/gjc-bot` on 2026-07-07). Reorganized by pipeline stage: `intake/`, `run/`, `review/`, `maintenance/`, `lib/`, `systemd/`. Scripts self-locate their repo root via `SCRIPTS_DIR` (`REPO_BOT_SCRIPTS` override still honored). [40-repo-bot-automation.md](40-repo-bot-automation.md) |
| **stackman / server-script / gjc-server-tool** | The Textual TUI ops console (Python). Repo/dir renamed `engels74-bot/server-tool` → `engels74-bot/gjc-server-tool` on 2026-07-07 (`~/github/engels74-bot/gjc-server-tool/`); the Python package `server_script` and the `stackman`/`server-script` console entrypoints are unchanged. Not part of the automated pipeline. |
| **GJCEMBED1** | The delimiter-envelope prefix (`GJCEMBED1 key=value … :: tail`) that marks a message for embed rendering by gjc-relay |
| **design system** | `~/.gjc-relay/design-system.json` — the single styling source (event kind → color/emoji/title) shared by the relay and `discord-embed.sh` |
| **DLQ / bury** | clawhip's dead-letter queue: in-memory only; a "buried" notification is permanently lost. `gjc-dlq-watch` alarms on it |
| **spool** | `~/.repo-bot/issue-spool.jsonl` — the JSONL queue clawhip writes `github.issue-opened` records to; the pipeline's inbox |
| **merge gate** | Advisory, comment-only LLM verdict on CI-green bot PRs (`MERGE_READY`/`REQUEST_CHANGES`); never merges |
| **the janitor / reap** | `gjc-worktree-janitor.sh` (crash-net for orphaned run worktrees) and `gjc-reap.sh` (manual tree-kill of a jammed run) |
| **single-flight** | The `flock`-based one-run-at-a-time discipline per lane (`gjc.lock`, `review.lock`) |
| **engels74-bot** | The dedicated bot GitHub identity (Write collaborator) authoring all automated PRs |
| **augmentcode[bot]** | External GitHub app that auto-reviews PRs; its "N suggestions" reviews trigger the review lane |
| **Coordinator MCP** | gjc's outward MCP control plane (`gjc mcp-serve coordinator`) — how hermes drives gjc |
| **brain model** | The cheap **no-tools** LLM for repo-bot triage/merge verdicts: `minimax/minimax-m3` via NanoGPT (formerly DeepSeek in the earlier build-log's plan). Since 2026-07-07 hermes' *conversational* brain is separate: `gpt-5.5` via the OpenAI Codex subscription ([20-hermes-agent.md](20-hermes-agent.md#purpose)) |
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
not source `lib/discord-embed.sh`). The four repo-bot systemd units were reinstalled to
`/etc/systemd/system/` (`ExecStart=` under `…/gjc-bot-scripts/<subfolder>/`, `daemon-reload`, all
`Result=success`), and the hermes cron real-file wrappers re-`exec` the new subfolder paths. These
architecture docs also moved from `~/documentation/architecture/` into the `gjc-architecture` git
repo (a stale copy remains under `~/documentation/architecture/`).
> [inferred] The `~/documentation/architecture/` copy is a pre-move leftover, not a maintained fork.

## Open questions

This page's list is the consolidated, system-wide set (the anchor `#open-questions` here is the
canonical link target).

Highest-signal first. Per-page questions are also listed on each component page.

1. ~~**Missing review-handler template**~~ — **Resolved 2026-07-06**: recreated as an
   architecture-native one-shot rewrite (detector as outer loop, trigger-comment re-review,
   battle-tested GitHub command blocks retained); **live-verified 2026-07-07** with two clean
   back-to-back handler runs on easyhdr#115. See
   [40-repo-bot-automation.md](40-repo-bot-automation.md#discrepancies). Residual unknown: why
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
   ([40-repo-bot-automation.md](40-repo-bot-automation.md#open-questions))
5. **`gjc-reap.sh` wiring** — header claims a clawhip `tmux.stale` trigger that doesn't exist;
   manual-only today. Re-enable the route (and tmux monitors), or update the header?
6. **Kanban's role** — the board exists and the dispatcher machinery is rich, but the live
   pipeline bypasses it. Idle capacity or future direction?
   ([20-hermes-agent.md](20-hermes-agent.md#open-questions))
7. **`restore.sh` still purges the dead script path** — `~/scripts/backuprestore/restore.sh:137`
   runs `rm -rf ~/scripts/repo-bot`, now a no-op since the scripts moved to the `gjc-bot-scripts`
   repo. Left as-is deliberately (removing the git repo on restore would be a destructive policy
   change), but the line no longer matches reality — retarget it, or drop it?
   ([50-configuration-and-state.md](50-configuration-and-state.md#backups--rollback))
8. Smaller items tracked on component pages: `gpu_cache.json` consumer (gjc);
   `verification_evidence.db` purpose (hermes); `~/.gjc-relay/.omc/` contents; slack sink usage
   (clawhip); Codex-subscription rate/usage limits for the new brain model (NanoGPT fair-use
   question is moot while on Codex); unread gjc subcommand handlers
   (`harness`, `gc`, `migrate`, `codex-native-hook`, `local-provider`); `missing_for_write` errors
   in gjc logs; whether `review.lock` sharing between merge-gate and review-run is a deliberate
   contract (40); hermes gateway `relay/` ingestion configured or not (20); clawhip's `gajae`
   handler seam wiring and its two-minor-stale upstream `ARCHITECTURE.md` (30); relay fallback
   "Option C" activation conditions (35); Bridge/ACP production readiness (10).

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
  `stackman/gjc-server-tool` glossary rows; reconciled the `repo-bot` glossary entry off the dead
  `~/scripts/repo-bot/` path. New OQ#8: `restore.sh:137` `rm -rf ~/scripts/repo-bot` no-op
  (catch-all renumbered 8→9). Fixed runbook path drift (`~/documentation/…` → `~/downloads/…`).
- 2026-07-07 (runbook-retirement pass) — The earlier hermes-stack build-log/runbook has been
  deleted; this doc set is now the single source of truth. Removed it from `sources`, deleted the
  "Runbook staleness" section (its live facts survive in the brain-model glossary row and
  [30-clawhip.md](30-clawhip.md)), and removed OQ "Runbook's future" (remaining OQs renumbered
  7→8's neighbours: old #8/#9 → #7/#8). Reframed the robogjc, gjc-relay, brain-model, and Phase A–G
  glossary rows plus the wave-timeline note to past tense ("earlier build-log, now retired").
