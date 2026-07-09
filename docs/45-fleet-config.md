<!--
status: reviewed         # draft | reviewed | verified
last_verified: 2026-07-09
sources:
  - ~/github/engels74-bot/gjc-fleet/fleet.toml.example
  - ~/github/engels74-bot/gjc-fleet/render/render.sh, render/lib/{toml2json,subst}.sh
  - ~/github/engels74-bot/gjc-fleet/render/templates/*.tmpl
  - ~/github/engels74-bot/gjc-fleet/render/checks/lint-routes.sh
  - ~/github/engels74-bot/gjc-fleet/systemd/{automerge,fleet-update}.{service,timer}
  - ~/github/engels74-bot/gjc-fleet/bootstrap/50-units.sh
  - ~/.config/gjc-fleet/fleet.toml (structure/keys only — untracked, host-local, never quoted here)
maintainer_notes: >
  Edit this file in isolation. Keep headings stable. Changelog is a single current-state
  rebaseline entry — rewrite this page to current state rather than appending; prior
  history lives in git.
  Names/roles only — NEVER add secret values or numeric Discord channel/guild IDs here.
  This page is the detailed companion to the "three-layer config model" summary in
  50-configuration-and-state.md and the repo-layout summary in 00-overview.md.
-->

# fleet.toml & the renderer

> Detailed reference for the fleet's config-custody surface, added by the 2026-07-07 gjc-fleet
> monorepo migration. For the high-level three-layer picture, see
> [50-configuration-and-state.md](50-configuration-and-state.md#the-three-layer-config-model-since-2026-07-07).
> Index: [README.md](README.md).

## Why this exists

Before 2026-07-07, every fleet config file (`~/.clawhip/config.toml`, `~/.gjc-relay/relay.env`,
the systemd units) was hand-edited in place, with dated `.bak-*` snapshots as the only audit trail,
and the numeric Discord channel IDs it needed lived directly inside those hand-edited files and
occasionally inside the pipeline scripts themselves. That doesn't scale past one host or one
operator, and it makes "no secrets/IDs in git" a matter of discipline rather than a gate. The
renderer replaces hand-editing: one host-local file (`fleet.toml`) holds every value that varies
per-deployment, and `render/render.sh` turns it plus repo-tracked templates into the files that
actually run.

## `fleet.toml` key reference

Copy `fleet.toml.example` (committed, value-free) to `~/.config/gjc-fleet/fleet.toml` (untracked,
0600) and fill it in. Each key below is tagged with its **value class**:

- **untracked-sensitive** — never appears in git, in an issue, or in this doc, in any form.
- **host-derived** — has a sensible default computed from `$HOME`/`bot_login`; override only if
  your layout differs from the convention.
- **per-deployment** — must be set; identifies *your* accounts/repos, not a secret.
- **shipping-default** — the example's value is almost always correct as-is.
- **pointer** — a path/name, never the value it points at.

| Section | Key | Value class | Meaning |
|---|---|---|---|
| `[operator]` | `github_owner`, `bot_login`, `bot_git_name`, `bot_git_email` | per-deployment | Human GitHub account owning the target repos; the bot account (`gh` login) authoring all automated commits/PRs |
| `[paths]` | `home`, `gh_root`, `fleet_repo` | host-derived | Commented out by default — the renderer derives all three from `$HOME` + `bot_login` (`gh_root` defaults to `$HOME/github/$bot_login/fleet`, `fleet_repo` to `$HOME/github/$bot_login/gjc-fleet`). Uncomment only on a nonstandard layout |
| `[discord.channels]` | `default`, `gjc-events`, `gjc-approvals`, `gjc-lab`, one per `[[repos]]` | **untracked-sensitive** | The name→numeric-channel-ID map. **This table, plus the env files it renders into, is the ONLY place numeric Discord IDs exist on this host** — `render/render.sh check` fails CI if one leaks anywhere else in the repo (the committed example ships a zero-padded, all-placeholder digit string of the right length for exactly this key, and only that shape, so the example itself never trips the gate — see `fleet.toml.example` directly for the exact placeholder form; never reproduced here) |
| `[relay]` | `bind` | shipping-default | Loopback bind address for gjc-relay (`127.0.0.1:25295`) |
| `[relay]` | `managed_rate` | shipping-default | Token-bucket budget for the v2 managed work-item path. A **preset** (`low` = 2/5s, `medium` = 3/5s (default), `high` = 4/5s) or an **explicit** `"<tokens>/<window>s"` (e.g. `"3/5s"`; tokens 1..=4, window ≥1s). Renders to `RELAY_MANAGED_RATE`; the relay re-validates and panics on garbage, so a bad value never ships silently |
| `[relay]` | `workitem_channels` | shipping-default | Optional list of extra channel **names** to include in `RELAY_WORKITEM_CHANNELS` without adding repo monitors. Use this for canary/lab surfaces such as `gjc-lab`; production repo channels should usually use per-`[[repos]] workitem_surface = true` |
| `[relay.debounce]` | channel-name → seconds | shipping-default | **Optional** per-channel debounce pins for the v2 managed path. Each entry renders to `RELAY_DEBOUNCE_SECS__<numeric-id>`. Omit the whole table (the default) to use the relay's global debounce for every channel |
| `[brain]` | `model`, `nanogpt_base_url` | per-deployment | The no-tools LLM used for gjc-bot triage/merge-gate/**review-policy** verdicts (the BRAIN lane — NanoGPT-compatible endpoint + model id) |
| `[review]` | `engine` | shipping-default | The **ENGINE lane** coding engine for the review handler run: `gjc` (default; inherits gjc's own backend/models) or `claude` (legacy headless). Renders to `REVIEW_ENGINE`. The CI-fix lane **shares** this one knob (one cutover decision — see [40-gjc-bot-automation.md](40-gjc-bot-automation.md#llm-invocation-lanes-engine-vs-brain)); a host MAY pin `claude` until the deploy-time cutover gate passes |
| `[review]` | `model_primary`, `model_fast` | shipping-default | Intended to set the models the claude-path handler fills into its template. **Currently NOT wired through the renderer** — `render.sh` emits no `REVIEW_MODEL_*`, so the `claude` fallback path always uses its hardcoded `opus`/`sonnet` defaults (`review-run.sh:35-36`) regardless of this knob; under `engine = gjc` (the default) it is doubly moot, since gjc inherits its own model config. Left in `fleet.toml` as a forward placeholder — editing it changes nothing today |
| `[review.policy]` | `automated_authors`, `max_handler_runs`, `decision_mode`, `max_rearms`, `backlog_alert_mins` | shipping-default | One-review policy for automated-author PRs (renovate/dependabot). `automated_authors` (space-joined into `REVIEW_AUTOMATED_AUTHORS`) routes those logins through the policy lane; `max_handler_runs` (default 2) caps handler launches per PR; `decision_mode` (`brain`) picks the later-review verdict engine. `max_rearms` (default 2, → `REVIEW_POLICY_MAX_REARMS`) is the force-push-resilience hard ceiling (Workstream D): `review-detector.sh` re-arms the same review-id when the PR head force-moves past a recorded `#policy-pushed:<sha>` (containment decided by `review-shared.sh` `head_contains()`), deduped per head lineage (`#rearm:<sha>`); hitting the cap escalates once to a human instead of looping. `backlog_alert_mins` (default 120, → `REVIEW_BACKLOG_ALERT_MINS`) is the K7 liveness threshold: `review-detector.sh` emits a `review.backlog` embed when a repo's oldest unhandled review is older than this, silent under threshold. Human/bot PRs untouched |
| `[ci_fixer]` | `enabled`, `max_per_sha`, `max_per_pr`, `backoff_base_mins`, `authors` | shipping-default | B-3 fix-until-green loop. **`enabled = false` by default** (renders `CI_FIXER_ENABLED=0`; the other two kill switches are the host `~/.gjc-bot/ci-fixer.disable` marker + `DRY_RUN`). Caps (`max_per_sha`=2, `max_per_pr`=5) + exponential `backoff_base_mins` (10 → 10/20/40/80 min) bound the loop. `authors` (Workstream E, space-joined into `CI_FIXER_AUTHORS`; default `engels74-bot renovate[bot] dependabot[bot]`) gates the lane on PR-author membership in that list, replacing the old hard "bot-authored only" filter — wired but still gated OFF by `enabled=false` |
| `[merge]` | `automerge_enabled`, `automerge_approve`, `automerge_authors`, `automerge_method`, `automerge_min_head_age_mins`, `automerge_review_wait_mins`, `automerge_max_attempts`, `automerge_max_per_poll` | shipping-default | Workstream F automerge lane (`pipeline/review/automerge.sh`): synchronous, oldest-PR-first merge of eligible automated-author PRs via `gh pr merge --squash --match-head-commit` (server-side head pin; feature-probed — a `gh` lacking `--match-head-commit` fails the lane CLOSED with one `automerge.escalation` embed, never calling `gh pr merge`). **`automerge_enabled = false` by default** (canary pending); kill switches are `automerge_enabled=true` **and** no `~/.gjc-bot/automerge.disable` marker **and** `DRY_RUN` unset **and** the repo not excluded **and** no `automerge-hold` label — ALL must allow. `automerge_approve` (default false, → `AUTOMERGE_APPROVE`) makes the bot submit a formal **APPROVE review on the exact head sha** — the bot is NOT the PR author, so its approval satisfies a `required_approving_review_count = 1` branch-protection rule — before merging (in-lock, after the CI re-check, ledger-deduped per sha); leave false unless the repo requires an approving review. `automerge_authors` (default `renovate[bot] dependabot[bot]`) scopes eligible PRs; `automerge_method` (`squash`) is the merge strategy; `automerge_min_head_age_mins` (10) is the post-push quiet period; `automerge_review_wait_mins` (30) bounds waiting for the one-review policy to settle; `automerge_max_attempts` (3) caps real merge attempts; `automerge_max_per_poll` (1, per repo) is the rebase-cascade brake. Merge runs under the per-repo `review-<repo>.lock` with an in-lock head + CI re-check immediately before merging |
| `[janitor]` | `tmux_reap_enabled`, `tmux_grace_mins` | shipping-default | Workstream I coordinator-tmux reaper, run by `gjc-worktree-janitor.sh` before its worktree pass. **`tmux_reap_enabled = false` by default** (→ `JANITOR_TMUX_REAP_ENABLED`); `tmux_grace_mins` (default 30, rendered in **seconds** as `JANITOR_TMUX_GRACE_SECONDS = tmux_grace_mins * 60`) is the minimum age of a `completed`/`stale` + non-live coordinator session before it's reaped via `gjc-reap.sh`; a session with no state file gets a ~24h fallback grace; missing state/live/updated_at fields SKIP (fail-safe). This resolves the historical "`gjc-reap.sh` defined but never wired" open question — it is now the janitor's own reap mechanism |
| `[updates]` | `tool_update_enabled`, `quiesce_timeout_mins` | shipping-default | Workstream G nightly fleet-update lane (`pipeline/maintenance/fleet-update.sh`, ~03:30 via `systemd/fleet-update.{service,timer}`): blocking-with-timeout quiesce on `gjc.lock`+`review.lock` waiting for zero live coordinator sessions (timeout defers to the next night), then `tool-update.sh` (headless update-ai manifest port — uv/prek/bun+globals/skills/ruff/claude — with a `trap … EXIT` that re-runs `bootstrap/10-engines.sh` to re-assert the `[pins]`), then `hermes-update.sh`, then a fleet `verify.sh` pass, then one `fleet-update` summary embed. **`tool_update_enabled = false` by default** (→ `TOOL_UPDATE_ENABLED`); other kill switches are the `~/.gjc-bot/fleet-update.disable` marker + `DRY_RUN`. `quiesce_timeout_mins` (default 45) bounds the wait for a quiet fleet |
| `[pins]` | `clawhip`, `gajae_code`, `hermes_ref` | per-deployment | Upstream engine versions — **never vendored**; installed via their own channels (`cargo install --version`, `bun add -g @version`, a `git checkout` of the hermes-agent ref). Keeping these in `fleet.toml` (not just in a README) means `render/render.sh doctor`-style tooling can eventually check installed-vs-pinned drift |
| `[cadence]` | `janitor_every`, `adapter_backup`, `detector_every`, `gate_every` | shipping-default, informational | Documents the shipped unit templates' timer intervals; changing these values does **not** change the timers — you'd also need to edit `systemd/*.timer` |
| `[secrets]` | `hermes_env`, `clawhip_env` | **pointer** | File paths only, plus (in comments) the env-var *names* expected in each — never a value. `~/.hermes/.env` remains the de-facto shared secret store (see [50-configuration-and-state.md](50-configuration-and-state.md#secrets-custody-names-only)) |
| `[[repos]]` (one block per fleet target repo) | `name`, `github`, `channel` | per-deployment | Drives both the clawhip `[[monitors.git.repos]]` blocks (via `render/templates/clawhip-monitor-repo.toml.tmpl`) and the pipeline's auto-discovery scope (clone the repo under `gh_root` and it's in the fleet — see [40-gjc-bot-automation.md](40-gjc-bot-automation.md)); `channel` is a **name** resolved through `[discord.channels]`, never an ID directly |
| `[[repos]]` | `workitem_surface` | shipping-default | **Optional, default `false`.** Opts this repo's channel into the v2 managed work-item path. The renderer collects every repo with `workitem_surface = true` into `RELAY_WORKITEM_CHANNELS` (comma-joined numeric IDs); while every repo leaves it false/unset, that var renders **empty** → `WorkitemChannels::None` → the managed path is fully OFF and the relay behaves byte-identically to v1 |

## Empty-list sentinel semantics

Every author-list knob added since the notification-overhaul wave (`[review.policy].automated_authors`,
`[ci_fixer].authors`, `[merge].automerge_authors`) shares one rendering contract, implemented once as
`list_or_sentinel()` in `render.sh`: an **absent** block falls back to that knob's shipped defaults (jq's
`//`), but an **explicit `key = []`** is truthy to `//` and jq-joins to an empty string — which would trip
`subst`'s empty-`{{VAR}}` guard and hard-fail the render. The renderer instead maps that empty join to a
single hyphen (`-`), so e.g. `automated_authors = []` renders `REVIEW_AUTOMATED_AUTHORS=-`: a non-empty,
always-valid env value that matches **no real GitHub login** in the lanes' exact-token author compares —
this is how a list-scoped lane is fully disabled by config without special-casing "empty" downstream.

## Renderer command reference

`render/render.sh <command>`, run from anywhere inside the `gjc-fleet` checkout (it resolves its
own repo root the same way the pipeline scripts do):

| Command | What it does |
|---|---|
| `render [--out DIR]` | Stages every render target (config files, env files, systemd units) into a scratch dir under `~/.gjc-bot/render-out/<timestamp>/` (or `--out`). **Touches nothing live.** |
| `diff` | Unified diff of staged vs. live for every target, unit files included; exits 1 if anything differs ("drift"). A unit whose lane gate renders OFF (`CI_FIXER_ENABLED`/`AUTOMERGE_ENABLED`/`TOOL_UPDATE_ENABLED` = `0`) but is deliberately **not installed live** prints a non-drift `NOTE: <unit> belongs to disabled lane (<GATE_VAR>=0) — not installed` and is excluded from the drift verdict, rather than being reported as a missing live unit |
| `apply [--yes]` | Per-target diff + interactive confirm (or `--yes` to skip prompts) + atomic install (`mktemp` + `mv` in the target's own directory) for **config/env files only** |
| `apply --units` | As above, plus installs the rendered systemd units to `~/.config/systemd/user/` (creates `clawhip.service.d/` as needed). Any unit belonging to a disabled lane (same gate check as `diff`'s NOTE) is **skipped** — printed as `skipped unit (disabled lane <GATE_VAR>=0): <unit>` rather than installed inert. Does **not** run `daemon-reload` for you — that's a deliberate separate step |
| `check [--config F]` | The CI gate: renders from `fleet.toml.example` (or `--config`), validates the result parses as TOML, runs [route invariants](#route-invariants) + design-system kind coverage, and greps the whole repo for numeric Discord-scale IDs (15+ digits), allowing only the zero-padded placeholder shape |
| `doctor` | Host checks for files the renderer deliberately does **not** own — hermes' `config.yaml` (gjc MCP command line, workdir roots, `terminal.cwd`, the duplicate `terminal:` block footgun), stale hermes cron workdirs, `~/.gjc/agent/mcp.json` permissions, deployed `~/.gjc-relay/*.sh` vs. `relay/runtime/*.sh` drift, and required keys in `~/.clawhip/clawhip.env` |

**The byte-identical philosophy.** The renderer's design goal is that switching from hand-edited
files to rendered ones changes *nothing* about what runs. The 2026-07-07 migration's acceptance
gate was exactly this: the first `render/render.sh render` on the live host reproduced
`~/.clawhip/config.toml`, `~/.gjc-relay/relay.env`, `~/.gjc-relay/design-system.json`, and all 14
live unit files **byte-for-byte** before anything was applied. `render diff` is meant to stay the
everyday tool after that — it **replaces the historical dated `.bak-*` convention**
(see [50-configuration-and-state.md](50-configuration-and-state.md)) as the way you review a
config change before it goes live. Legacy dated `.bak-*` files on disk are not deleted outright:
`render.sh`'s own header documents an **archive-after-30-days-zero-drift** policy — once a `.bak-*`
file is more than 30 days old **and** `render.sh diff` reports zero drift, it should be tarred into
`~/.gjc-bot/archive/` rather than left as a permanent on-disk pile. This is an operator convention
carried in the header (there is no automated archiver job yet — the one-off sweep is run by hand);
git history remains the primary archive, any tarball a short-lived forensic fallback.

**Units are user-scope only.** `render.sh`'s `unit_live_path()` resolves every unit's live path as
`$HOME/.config/systemd/user/<unit>` unconditionally — there is deliberately no fallback probe of
`/etc/systemd/system/` (that historical fallback was decommissioned; probing it produced misleading
"live unit missing" drift now that every fleet unit is user-scope, see
[50-configuration-and-state.md](50-configuration-and-state.md#systemd-units-templates-vs-renderedinstalled)).

Only the six `[[monitors.git.repos]]` blocks inside `clawhip-config.toml.tmpl` are **generated**
(one per `[[repos]]` entry, via `render/templates/clawhip-monitor-repo.toml.tmpl` and
`build_monitor_blocks()` in `render.sh`). Every other route in that template — all 16 of clawhip's
`[[routes]]` — is **static template text**, never generated, so route semantics can't drift from a
`fleet.toml` edit; see [Route invariants](#route-invariants).

## Rendered env vars (B-2/B-3 + relay v2)

The renderer turns the new `fleet.toml` keys into env lines the units read via `EnvironmentFile=`.
Numeric Discord IDs are appended at render time (never in a tracked template); every other knob rides
a tracked `.tmpl`.

**`~/.gjc-bot/gjc-bot.env`** (from `render/templates/gjc-bot.env.tmpl`, mode 0600) — besides the three
channel IDs (`ISSUE_NOTIFY_CHANNEL`/`MERGE_GATE_CHANNEL`/`REVIEW_NOTIFY_CHANNEL`) it now carries:
`REVIEW_ENGINE` (from `[review].engine`); `REVIEW_AUTOMATED_AUTHORS` (space-joined, sentinel `-` when
`[]`), `REVIEW_POLICY_MAX_HANDLER_RUNS`, `REVIEW_POLICY_DECISION_MODE`, `REVIEW_POLICY_MAX_REARMS`,
`REVIEW_BACKLOG_ALERT_MINS` (from `[review.policy]`); `CI_FIXER_ENABLED` (rendered `0`/`1`, never empty — an absent `[ci_fixer]`
block ⇒ `0`/OFF), `CI_FIXER_MAX_PER_SHA`, `CI_FIXER_MAX_PER_PR`, `CI_FIXER_BACKOFF_BASE_MINS`,
`CI_FIXER_AUTHORS` (space-joined, sentinel `-` when `[]`) (from `[ci_fixer]`); `AUTOMERGE_ENABLED`
(`0`/`1`), `AUTOMERGE_APPROVE` (`0`/`1`), `AUTOMERGE_AUTHORS` (space-joined, sentinel `-` when `[]`), `AUTOMERGE_METHOD`,
`AUTOMERGE_MIN_HEAD_AGE_MINS`, `AUTOMERGE_REVIEW_WAIT_MINS`, `AUTOMERGE_MAX_ATTEMPTS`,
`AUTOMERGE_MAX_PER_POLL` (from `[merge]`); `JANITOR_TMUX_REAP_ENABLED` (`0`/`1`) and
`JANITOR_TMUX_GRACE_SECONDS` (from `[janitor]`, minutes→seconds converted at render time); and
`TOOL_UPDATE_ENABLED` (`0`/`1`) and `QUIESCE_TIMEOUT_MINS` (from `[updates]`).

**`~/.gjc-relay/relay.env`** (from `relay.env.tmpl`, mode 0600) — the v2 managed-path lines are
**appended by `render.sh`** after the tracked template: `RELAY_MANAGED_RATE` (always),
`RELAY_WORKITEM_CHANNELS` (comma-joined numeric IDs of the `workitem_surface = true` repos plus
any `[relay].workitem_channels` extra names — **empty by default** ⇒ managed path OFF),
`GJC_LAB_CHANNEL` (the lab channel numeric ID for
`relay-heartbeat.sh`), and any `RELAY_DEBOUNCE_SECS__<numeric-id>` lines from `[relay.debounce]`
(none by default). See `render.sh` `do_render` for the exact append order.

## New systemd units

`gjc-fleet/systemd/` carries five units added since the B-3 + relay-v2 + F/G waves
(rendered/installed by `render/render.sh apply --units`; `bootstrap/50-units.sh` additionally
enables-and-starts each lane-gated timer only when its rendered unit file is actually present):

**Lane-gated (inert while their `[...]` config knob is OFF, the shipped default for all three):**

- **`ci-fixer.service` / `.timer`** — the gjc-bot fix-until-green poller, every 10 min but **inert
  while `CI_FIXER_ENABLED=0`** (`[ci_fixer].enabled = false`). `Nice=15`, `KillMode=process` (keeps
  the detached fix run alive past the oneshot). Mechanism on
  [40-gjc-bot-automation.md](40-gjc-bot-automation.md#fix-until-green-ci-fixer).
- **`automerge.service` / `.timer`** — the Workstream F automerge poller, every 10 min but **inert
  while `AUTOMERGE_ENABLED=0`** (`[merge].automerge_enabled = false`, canary pending). `Nice=15`, no
  `KillMode` override (the merge runs synchronously inline, no detached handler to protect).
- **`fleet-update.service` / `.timer`** — the Workstream G nightly fleet tool-update lane, once at
  03:30 but **inert while `TOOL_UPDATE_ENABLED=0`** (`[updates].tool_update_enabled = false`).
  `Nice=15`.

None of the three lane-gated units carry the relay units' namespace-free hardening block below —
they ship with `Nice=15` (+ a `KillMode` choice matching whether they detach a child run) only.

**Always-on liveness pings (no config gate — harmless no-ops by design, not "OFF"):**

- **`gjc-relay-heartbeat.service` / `.timer`** — a self-priming token-cache heartbeat (no-op inbound
  via clawhip), every 120 s. Mechanism on [35-gjc-relay.md](35-gjc-relay.md).
- **`gjc-relay-health-watch.service` / `.timer`** — an out-of-band alarm on a stuck delivery queue /
  dead flush thread, every 2 min. Mechanism on [35-gjc-relay.md](35-gjc-relay.md).

These two carry the **namespace-free** hardening the fleet adopted on 2026-07-07
(`NoNewPrivileges`, `RestrictRealtime`, `LockPersonality`, `SystemCallArchitectures=native`,
`RestrictNamespaces`, `MemoryDenyWriteExecute`) — no `ProtectSystem`/`ProtectHome`/`PrivateTmp`, matching
`gjc-relay.service` under this host's AppArmor user-namespace restriction (see
[50-configuration-and-state.md](50-configuration-and-state.md) and
[35-gjc-relay.md](35-gjc-relay.md)). Their timers use fixed literal cadences kept in sync with
`RELAY_HEARTBEAT_SECS` (relay.env) by convention — systemd timers cannot read `EnvironmentFile`
values.

## Secrets custody map (names/roles only)

Unchanged in substance by the renderer — see the full table in
[50-configuration-and-state.md](50-configuration-and-state.md#secrets-custody-names-only). What
the renderer adds is `fleet.toml`'s `[secrets]` table, a **pointer layer**: it names the files
(`~/.hermes/.env`, `~/.clawhip/clawhip.env`) and the env-var keys each holds, so the renderer (and
a fresh operator following [80-reproduction-guide.md](80-reproduction-guide.md)) know where
credentials belong without any value ever passing through `fleet.toml`, `render/`, or this repo.
`render/render.sh doctor` checks that `clawhip.env` has the expected *keys* present — never their
values — and that `~/.gjc/agent/mcp.json` (which holds a literal, non-renderable `EXA_API_KEY`) is
mode 0600.

## `GJC_BOT_SCRIPTS` ≡ `pipeline/`

Every pipeline entry-point script resolves its own repo root at runtime into `SCRIPTS_DIR`
(`GJC_BOT_SCRIPTS` env override still honored — see
[40-gjc-bot-automation.md](40-gjc-bot-automation.md#self-locating-scripts)). Since the monorepo
migration, that root is the **`pipeline/` subdirectory** of `gjc-fleet`, not the repo root — so
`GJC_BOT_SCRIPTS`, when set, must point at `.../gjc-fleet/pipeline`, matching how the renderer
itself exercises the scripts in CI: `render/render.sh check` invokes
`relay/runtime/check-kind-coverage.sh` with `GJC_BOT_SCRIPTS="$REPO_ROOT/pipeline"` explicitly, so
the design-system coverage check resolves the same `lib/discord-embed.sh` the live pipeline units
do. Getting this one level wrong (pointing at `gjc-fleet` itself rather than `gjc-fleet/pipeline`)
is the most likely manual-override mistake post-migration.

## Route invariants

`render/checks/lint-routes.sh` (invoked by `render/render.sh check`) guards five clawhip route
invariants against a careless template edit. Each is documented as a comment directly above the
route block it guards in `render/templates/clawhip-config.toml.tmpl`:

1. **No catch-all route** (`event = "*"` or similar) — one would double-post every event and
   suppress every per-repo monitor-channel fallback fleet-wide.
2. **`session.*`-keyed routes must emit `kind=agent.*` labels** — clawhip emits canonical
   `session.*` events (`clawhip agent started|finished|failed|blocked`), and a route keyed on
   `agent.*` directly would never match; the route *key* and the user-facing embed *taxonomy*
   differ by design (see [30-clawhip.md](30-clawhip.md#event-pipeline)).
3. **Embed routes stay channel-less** — every `session.*`, `github.issue-*`, `github.ci-*`, and
   `github.pr-status-changed` route must omit `channel` so resolution
   (`route.channel > event.channel > default`) preserves each event's own per-repo channel.
4. **`github.issue-opened` needs both its routes** — the localfile spool route (feeds the pipeline
   intake) *and* a Discord route (the human-visible per-repo notice) must both exist, exactly one
   of each; any matched route otherwise suppresses the monitor-channel fallback (see
   [30-clawhip.md](30-clawhip.md#the-issue-spool-producer-side) for the incident this invariant
   prevents from recurring), so the spool-write and the Discord post are a required **duality**,
   not an either/or.
5. **At most one route per `(event, sink)` pair** — a duplicate would double-post.

## Open questions

- Should `fleet.toml`'s `[pins]` table eventually be cross-checked automatically against installed
  versions (`cargo search`/`~/.cargo/.crates2.json`, bun global, the hermes-agent checkout's ref),
  or does that overreach the renderer's current scope (render config, not manage installs)?
- `render/render.sh doctor`'s hermes checks are hard-coded to specific `config.yaml` lines; will
  they need generalizing if hermes' own config shape changes upstream?
- Is there a need for a `render/render.sh check --strict` mode that also fails on *warnings* from
  `doctor`, for use in a pre-deploy gate rather than just informational drift?

## Changelog

- 2026-07-09 (v2-current-state rewrite) — Doc set rebaselined to current state; prior history in git.
  This page: added `[merge]`/`[ci_fixer].authors`/`[review.policy].max_rearms`/`[janitor]`/`[updates]`
  knobs, the engine+model-name claude-only nuance, the empty-list sentinel section, the `do_diff` NOTE
  + `do_apply --units` skip behavior for disabled-lane units, `unit_live_path()`'s user-scope-only
  contract, the `.bak` archive-after-30-days-zero-drift policy, the corrected 16-route count, and the
  `automerge`/`fleet-update` units in New systemd units.
- 2026-07-09 — Folded in `[merge].automerge_approve` (default false → `AUTOMERGE_APPROVE` `0`/`1`): gated
  bot self-approval on the exact head sha for required-review repos before merging.
