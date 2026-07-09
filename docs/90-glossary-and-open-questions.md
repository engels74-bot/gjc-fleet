<!--
status: verified         # draft | reviewed | verified
last_verified: 2026-07-09
sources:
  - ~/.omc/ (progress.txt, plans/discord-unification-plan.md, research/discord-unification-findings.md)
  - all component pages in this directory
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; Changelog is a single current-state
  rebaseline entry — rewrite this page to current state rather than appending; prior history
  lives in git. When a component page resolves one of the open questions below, delete it here
  and note the resolution in that page's changelog.
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
| **the janitor / reap** | `gjc-worktree-janitor.sh` (crash-net for orphaned run worktrees, plus an age-based **coordinator tmux reaper** sweep) and `gjc-reap.sh` (tree-kill of a jammed run). Reap is now wired into the janitor's tmux sweep — it reaps a `gjc-coordinator-*` session iff its state ∈ {completed,stale}, `live==false`, and `updated_at` older than `JANITOR_TMUX_GRACE_SECONDS` (default 30 min); gated `[janitor].tmux_reap_enabled` (default OFF) + `DRY_RUN`. Not manual-only. [40-gjc-bot-automation.md](40-gjc-bot-automation.md) |
| **single-flight** | The `flock`-based one-run-at-a-time discipline per lane (`gjc.lock`, `review.lock`) |
| **engels74-bot** | The dedicated bot GitHub identity (Write collaborator) authoring all automated PRs |
| **augmentcode[bot]** | External GitHub app that auto-reviews PRs; its "N suggestions" reviews trigger the review lane |
| **Coordinator MCP** | gjc's outward MCP control plane (`gjc mcp-serve coordinator`) — how hermes drives gjc |
| **brain model** | The cheap **no-tools** LLM for gjc-bot triage/merge verdicts: `minimax/minimax-m3` via NanoGPT (formerly DeepSeek in the earlier build-log's plan). Since 2026-07-07 hermes' *conversational* brain is separate: `gpt-5.5` via the OpenAI Codex subscription ([20-hermes-agent.md](20-hermes-agent.md#purpose)) |
| **oh-my-pi / pi-*** | gajae-code's upstream lineage (`can1357/oh-my-pi`); explains `pi-natives`, `PI_ROOT`, and stale `can1357` URLs |
| **Phase A–G** | The incremental build phases from the earlier hermes-stack build-log (now retired): jq → hermes brain → bot identity → Discord → clawhip → gjc → automation + 6-repo fan-out |
| **Discord unification** | The 2026-07-06 evening wave (`.omc` plan/progress) that added gjc-relay, route templates, `discord_embed`, and the SOUL.md voice alignment |
| **work-item** | The v2 relay's managed unit of Discord state: a single anchor message the relay updates in place (edits) as an entity's status changes, instead of posting one message per event. Gated by `workitem_surface`; OFF by default. [35-gjc-relay.md](35-gjc-relay.md) · [45-fleet-config.md](45-fleet-config.md) |
| **two-phase durable commit** | The relay-v2 write discipline for a work-item: stage the intended Discord state to durable local `RELAY_STATE_DIR` state, then perform the remote edit, so a crash between the two can't lose or double-apply an update. [35-gjc-relay.md](35-gjc-relay.md) |
| **read-back reconciliation** | On restart, the v2 relay re-reads its durable state and the live Discord anchor to reconcile the two before resuming — the recovery half of the two-phase durable commit. [35-gjc-relay.md](35-gjc-relay.md) |
| **managed / unmanaged surface** | A **managed** surface is a channel opted into the v2 work-item path (`workitem_surface = true` → `RELAY_WORKITEM_CHANNELS`); an **unmanaged** surface is a plain post-per-event channel (the v1 behaviour, and the default for every channel). [45-fleet-config.md](45-fleet-config.md) |
| **deferred-mark** | The HARD B-2 invariant: the one-review policy writes a PR's `#consumed` marker under the per-repo `review-<repo>.lock`, after an in-lock review-id re-check and before release — never "whenever a launch happens" — guaranteeing exactly-one consumption under racing pollers. [40-gjc-bot-automation.md](40-gjc-bot-automation.md#one-review-policy-automated-author-prs) |
| **engine vs brain lane** | The two LLM lanes of the pipeline: the **ENGINE** lane runs coding-work invocations via `lib/engine.sh` on `[review].engine` (gjc default); the **BRAIN** lane runs no-tools VERDICT invocations on NanoGPT (`BRAIN_MODEL`). The split is the injection-safety boundary. [40-gjc-bot-automation.md](40-gjc-bot-automation.md#llm-invocation-lanes-engine-vs-brain) |
| **engine dispatch / `REVIEW_ENGINE`** | The review/policy/ci-fix handlers run coding work via `pipeline/lib/engine.sh` `engine_run` on `[review].engine` (`REVIEW_ENGINE`); **`gjc` is live** (`gjc -p --no-pty "@<prompt>"`), with the legacy headless `claude -p` kept as a selectable fallback (no longer active). `MODEL_PRIMARY`/`MODEL_FAST` apply only to the `claude` engine — inert under gjc, which inherits its own Codex backend. [40-gjc-bot-automation.md](40-gjc-bot-automation.md) |
| **automerge lane** | `pipeline/review/automerge.sh` — synchronous, oldest-first squash-merge of CI-green automated-author PRs under the per-repo `review-<repo>.lock`, re-fetching head + re-checking CI in-lock, merging with `gh pr merge --squash --match-head-commit <sha>`. Fail-closed if `--match-head-commit` is unsupported (one `automerge.escalation` embed, never calls `gh pr merge`). Default-OFF (`automerge_enabled=false`; canary pending). [40-gjc-bot-automation.md](40-gjc-bot-automation.md) |
| **fleet-update lane** | `pipeline/maintenance/fleet-update.sh` — nightly (~03:30) quiesce-then-update orchestrator: blocking-with-timeout on `gjc.lock`+`review.lock` and zero live coordinators, then `tool-update.sh` (headless update-ai port; re-asserts `fleet.toml` tool pins via an EXIT trap) then `hermes-update.sh` (gateway update + health-gated rollback), release, `verify.sh`, one `fleet-update` summary embed. Default-OFF. [40-gjc-bot-automation.md](40-gjc-bot-automation.md) |
| **per-repo review lock (K1)** | `review-<repo>.lock` — `review-run.sh` `_handler` takes it INSIDE the global `review.lock`; `ci-fixer-run.sh` and `automerge.sh` take ONLY the per-repo lock. Deadlock-free by construction; scopes `ensure_checkout`'s `git checkout -f` and every merge critical section per repo. [40-gjc-bot-automation.md](40-gjc-bot-automation.md) |
| **policy re-arm / head containment** | Force-push resilience (D): the policy lane records `#policy-pushed:<sha>`; `review-detector.sh` re-arms the same review-id when that head is **not contained** in the current head (deduped per head lineage), capped by `REVIEW_POLICY_MAX_REARMS` (default 2), escalate-once on cap. Containment via `review-shared.sh` `head_contains()` (compare API: identical/ahead ⇒ no re-arm; behind/diverged ⇒ re-arm; empty ⇒ defer); reused by ci-fixer and automerge defer conditions |
| **`review.backlog` signal** | Embed kind `review-detector.sh` emits (K7) when the oldest-unhandled-PR age exceeds `REVIEW_BACKLOG_ALERT_MINS` (default 120); silent under threshold. Backstop for the fleet-wide serial-review single-flight (per-repo review concurrency remains a documented follow-up, made safe by K1) |
| **UNKNOWN CI state** | New `pipeline/lib/gh-ci.sh` `ci_state` return (K2) on gh API failure after one retry; all callers (merge-gate, ci-fixer, automerge) treat UNKNOWN as **defer**, never as NONE/green |
| **empty-list sentinel (`-`)** | render.sh renders an empty TOML list (e.g. `automated_authors=[]`) as a literal `-` (e.g. `REVIEW_AUTOMATED_AUTHORS=-`) — `-` matches no login, avoiding the `:-` default footgun and subst.sh's empty-var hard-fail. Same pattern on the other new list knobs. [45-fleet-config.md](45-fleet-config.md) |

## The configuration & automation waves (backup-file / git timeline)

This is a current-state rebaseline; prior-wave detail is compressed here and lives in full in git.

**Prior waves (2026-07-06 → 07), compressed.** The Discord-unification evening ran `.bak` order
`phaseg` (16:48) → `g7` (18:31, issue-spool route + 6-repo fan-out) → `discord` (20:49–21:35, relay +
templates + embed helper) → `yolo`/`workdir`/`workspace` (23:19–23:25, hermes approvals-off +
`terminal.cwd` + SOUL.md workspace rules) → `embedbatch` (2026-07-07 01:52, clawhip issue/CI embed
routes + relay multi-envelope batching + design-system 17→23 kinds), standing up gjc-relay and the
embed pipeline; hermes' conversational brain then moved from NanoGPT/`minimax-m3` to the Codex
subscription (`gpt-5.5`). A run of 2026-07-07 structural moves followed: the pipeline repo
`engels74-bot/gjc-bot` → `gjc-bot-scripts` (stage-based reorg into `intake/ run/ review/ maintenance/
lib/ systemd/`, script self-location via `SCRIPTS_DIR`) and `server-tool` → `gjc-server-tool`; the six
working clones + their `*.gajae-code-worktrees/` buckets relocated under
`~/github/engels74-bot/fleet/` (all `GH_ROOT`/monitor-path/hermes-workdir pointers re-pointed); the
component name settled on **gjc-bot** with the on-disk `~/.repo-bot` → `~/.gjc-bot` / `REPO_BOT_*` →
`GJC_BOT_*` rename; the relay crate adopted into its own repo. Then all three component repos
(`gjc-relay`, `gjc-bot-scripts`, this doc set's `gjc-architecture`) were consolidated into the
**`engels74-bot/gjc-fleet`** monorepo (`pipeline/ relay/ render/ systemd/ docs/`, predecessors
archived with pointer READMEs), a new **three-layer config model** introduced (repo templates → host
`~/.config/gjc-fleet/fleet.toml` → `render/render.sh` artifacts, replacing the dated `.bak-*`
hand-edit convention), and every fleet systemd unit cut over system→user-scope (linger, no `sudo`).
`gjc-relay.service` traded namespace sandboxing (`ProtectSystem`/`ProtectHome`/`PrivateTmp`) for
namespace-free hardening to dodge an Ubuntu ≥24.04 AppArmor start-failure; hard-coded numeric Discord
channel defaults were removed from the pipeline scripts in favor of a hard-fail-unless-set
`~/.gjc-bot/gjc-bot.env` contract. The old `/etc/systemd/system/` fleet units were deleted 2026-07-08
(soak skipped; reboot test still pending).

**2026-07-09 — drift fold-back + automation upgrade wave (git-tracked; no `.bak` markers).** The
current-state wave this rebaseline documents. Landed together, **all new lanes default-OFF** (units
run live-from-repo, so committed code is live but gated behind OFF switches):
- **Engine cutover (LIVE):** `REVIEW_ENGINE=gjc` — the review/policy/ci-fix handlers now dispatch
  through `pipeline/lib/engine.sh` `engine_run` running **gjc** by default (`gjc -p --no-pty
  "@<prompt>"`); the legacy headless `claude -p` path stays a selectable fallback (no longer active).
  `MODEL_PRIMARY`/`MODEL_FAST` apply only to the `claude` engine, inert under gjc.
- **Config-truth fold-back (A2):** new `[review] [review.policy] [ci_fixer] [merge] [janitor]
  [updates]` sections folded into host `fleet.toml`, all rendered into `~/.gjc-bot/gjc-bot.env` by
  render.sh (zero hand-pins). Empty-list **sentinel** (`automated_authors=[]` →
  `REVIEW_AUTOMATED_AUTHORS=-`); `unit_live_path()` user-scope-only; `do_diff` NOTEs disabled-lane
  units and `do_apply --units` skips them; `.bak` archive-after-30-days-zero-drift policy.
- **K concurrency hardening:** per-repo `review-<repo>.lock` inside the global `review.lock` (K1);
  UNKNOWN CI state ⇒ defer (K2); exact `ledger_seen` match + atomic ci-fixer count (K4); per-loop
  `flock -n <name>-poll.lock` single-flight (K5); `review.backlog` alert embed (K7).
- **D — force-push resilience:** policy `#policy-pushed:<sha>` snapshot + containment-based re-arm
  (`head_contains()`), capped by `REVIEW_POLICY_MAX_REARMS` (default 2), escalate-once on cap.
- **E — ci-fixer author scope:** `[ci_fixer].authors` → `CI_FIXER_AUTHORS` membership gate (default-OFF).
- **F — automerge lane:** `pipeline/review/automerge.sh` (synchronous oldest-first squash-merge,
  in-lock CI re-check, `--match-head-commit` capability guard, `automerge`/`automerge.escalation`
  embeds, new `systemd/automerge.{service,timer}`); `automerge_enabled=false`, canary pending.
- **I — coordinator tmux reaper + log-prune:** `pipeline/maintenance/gjc-worktree-janitor.sh` gained
  an age-based `gjc-coordinator-*` tmux sweep (reaps via `gjc-reap.sh`, gated
  `[janitor].tmux_reap_enabled`) plus a 14-day per-run log-prune.
- **G — nightly fleet-update lane:** `pipeline/maintenance/fleet-update.sh` orchestrator (quiesce →
  `tool-update.sh` → `hermes-update.sh` → release → `verify.sh` → one `fleet-update` embed), new
  `systemd/fleet-update.{service,timer}`.
- **Design system:** five new embed kinds — `automerge`, `automerge.escalation`, `hermes-update`,
  `fleet-update`, `review.backlog` — in `relay/runtime/design-system.json`.
- **Renovate:** canonical `renovate.json` rolled out to all non-fork engels74 repos (33 repos) — see
  [47-renovate-policy.md](47-renovate-policy.md).

## Open questions

This page's list is the consolidated, system-wide set (the anchor `#open-questions` here is the
canonical link target).

Highest-signal first. Per-page questions are also listed on each component page.

1. **Relay permanence & reliability posture** — is gjc-relay (in-path single point of failure for
   all notifications, compensated only by infinite-restart + out-of-band alarms) the intended end
   state, or is a persistent DLQ/retry layer planned? ([35-gjc-relay.md](35-gjc-relay.md#open-questions))
2. **Per-repo review concurrency (documented follow-up).** Fleet-wide review is still serial
   single-flight (one review handler at a time across all repos). K1's per-repo `review-<repo>.lock`
   makes concurrent per-repo review *safe* but does not yet run it in parallel; genuine per-repo
   concurrency remains a follow-up, with the `review.backlog` alert (K7,
   `REVIEW_BACKLOG_ALERT_MINS` default 120) as the interim backlog-age backstop.
   ([40-gjc-bot-automation.md](40-gjc-bot-automation.md#open-questions))
3. **Automerge canary pending.** The automerge lane (F, `pipeline/review/automerge.sh`) is committed
   and unit-wired but `automerge_enabled=false`; a canary rollout on a single low-risk repo is still
   pending before it is enabled fleet-wide. ([40-gjc-bot-automation.md](40-gjc-bot-automation.md#open-questions))
4. **Interactive-vs-automated lane asymmetry** — the coordinator (hermes→gjc) lane bypasses the
   single-flight launcher by explicit user choice; can it collide with the automated lane on the
   same repo (worktrees differ, but clones/remotes/branches are shared)? The concrete push-race
   sub-case is now closed (D containment re-arm + F in-lock CI re-check + K1 per-repo lock); the
   broader asymmetry — the coordinator lane holding no per-repo lock — remains structurally open.
   ([60-data-flow-and-integration.md](60-data-flow-and-integration.md#open-questions))
5. **Flaky Codex-responses websocket (live ops item).** Under `REVIEW_ENGINE=gjc`, gjc's Codex
   backend intermittently has a flaky responses websocket that slows the gjc coordinator; watched
   operationally, no structural fix yet. ([10-gajae-code.md](10-gajae-code.md))
6. **Kanban's role** — the board exists and the dispatcher machinery is rich, but the live
   pipeline bypasses it. Idle capacity or future direction?
   ([20-hermes-agent.md](20-hermes-agent.md#open-questions))
7. **Relay reliability under the new hardening** — `gjc-relay.service` dropped namespace-based
   sandboxing (`ProtectSystem`/`ProtectHome`/`PrivateTmp`) in favor of namespace-free directives,
   to avoid an AppArmor-related start-failure risk under user-scope systemd on Ubuntu ≥24.04.
   Verified live via a full cutover + DLQ drill, but the trade-off (weaker filesystem isolation for
   an in-path single point of failure) is a standing judgment call, not a fully closed question.
   ([35-gjc-relay.md](35-gjc-relay.md#open-questions))
8. **Old system-level units: reboot test.** The `/etc/systemd/system/` fleet units were deleted
   2026-07-08 (operator skipped the soak); **residual: the reboot test** — linger + user-unit
   boot-start has only been proven across a hot cutover, not a real reboot. Confirm on the next host
   reboot (`bootstrap/verify.sh` afterwards).
   ([70-deployment-and-operations.md](70-deployment-and-operations.md#open-questions))
9. **Thread-permission verification (pre-rollout manual check).** The v2 work-item path relies on the
   bot holding **`CREATE_PUBLIC_THREADS`** + **`SEND_MESSAGES_IN_THREADS`**. These are **DOC-VERIFIED**
   against the Discord permissions docs, **not** test-verified against the live guild — so before the
   managed surface is switched on for any channel, confirm both permissions on the bot role in that
   guild by hand. A missing permission would fail silently at first thread creation.
10. **Digest surface DEFERRED (design guard, not a TODO).** `Surface::Digest` was **removed from v2** —
    there is deliberately no batching/rollup surface today. If a future digest is added it MUST (a)
    explicitly **name the event kinds it absorbs** and (b) emit a **`[digest-drop]` counter metric** so
    "operators miss a notification" is a *checkable* condition, not a judgment call. No silent
    drop-with-an-adjective ("minor", "noisy") is acceptable as a design.
11. **Heartbeat-bounded quiet-period stall (recorded, bounded).** After a relay restart the
    token-cache/flush path can stall until the first inbound traffic primes it; that window is bounded
    to **≤120 s** by the self-priming `gjc-relay-heartbeat` timer (it manufactures a no-op inbound every
    120 s), with the queue-age alarm (`gjc-relay-health-watch`) as the backstop if the heartbeat itself
    fails. Not open so much as a documented invariant — flag if either unit is ever disabled.
12. Smaller items tracked on component pages: `gpu_cache.json` consumer (gjc);
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

- 2026-07-09 (v2-current-state rewrite) — Doc set rebaselined to current state; prior history in git.
  This page: glossary gains engine-dispatch/`REVIEW_ENGINE`, automerge lane, fleet-update lane,
  per-repo review lock (K1), policy re-arm / head containment, `review.backlog` signal, UNKNOWN CI
  state, and the empty-list sentinel (`-`), plus the coordinator tmux reaper folded into the
  janitor/reap row; the wave timeline was rebaselined (prior 2026-07-06→08 waves compressed) with the
  2026-07-09 drift fold-back + automation upgrade wave; the gjc-reap.sh-wiring and cross-lane
  push-race open questions were resolved (by I and by D+F+K), with per-repo review concurrency, the
  automerge canary, and the flaky Codex-responses websocket added as the still-open follow-ups.
