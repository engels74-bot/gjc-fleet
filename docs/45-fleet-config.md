<!--
status: reviewed         # draft | reviewed | verified
last_verified: 2026-07-08
sources:
  - ~/github/engels74-bot/gjc-fleet/fleet.toml.example
  - ~/github/engels74-bot/gjc-fleet/render/render.sh, render/lib/{toml2json,subst}.sh
  - ~/github/engels74-bot/gjc-fleet/render/templates/*.tmpl
  - ~/github/engels74-bot/gjc-fleet/render/checks/lint-routes.sh
  - ~/.config/gjc-fleet/fleet.toml (structure/keys only — untracked, host-local, never quoted here)
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
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
| `[review]` | `model_primary`, `model_fast` | shipping-default | Models the handler fills into its template (`opus`/`sonnet` by default). **Consumed ONLY on the `engine = "claude"` path**; ignored for gjc, which inherits its own model config |
| `[review.policy]` | `automated_authors`, `max_handler_runs`, `decision_mode` | shipping-default | One-review policy for automated-author PRs (renovate/dependabot). `automated_authors` (space-joined into `REVIEW_AUTOMATED_AUTHORS`) routes those logins through the policy lane; `max_handler_runs` (default 2) caps handler launches per PR; `decision_mode` (`brain`) picks the later-review verdict engine. Human/bot PRs untouched |
| `[ci_fixer]` | `enabled`, `max_per_sha`, `max_per_pr`, `backoff_base_mins` | shipping-default | B-3 fix-until-green loop. **`enabled = false` by default** (renders `CI_FIXER_ENABLED=0`; the other two kill switches are the host `~/.gjc-bot/ci-fixer.disable` marker + `DRY_RUN`). Caps (`max_per_sha`=2, `max_per_pr`=5) + exponential `backoff_base_mins` (10 → 10/20/40/80 min) bound the loop |
| `[pins]` | `clawhip`, `gajae_code`, `hermes_ref` | per-deployment | Upstream engine versions — **never vendored**; installed via their own channels (`cargo install --version`, `bun add -g @version`, a `git checkout` of the hermes-agent ref). Keeping these in `fleet.toml` (not just in a README) means `render/render.sh doctor`-style tooling can eventually check installed-vs-pinned drift |
| `[cadence]` | `janitor_every`, `adapter_backup`, `detector_every`, `gate_every` | shipping-default, informational | Documents the shipped unit templates' timer intervals; changing these values does **not** change the timers — you'd also need to edit `systemd/*.timer` |
| `[secrets]` | `hermes_env`, `clawhip_env` | **pointer** | File paths only, plus (in comments) the env-var *names* expected in each — never a value. `~/.hermes/.env` remains the de-facto shared secret store (see [50-configuration-and-state.md](50-configuration-and-state.md#secrets-custody-names-only)) |
| `[[repos]]` (one block per fleet target repo) | `name`, `github`, `channel` | per-deployment | Drives both the clawhip `[[monitors.git.repos]]` blocks (via `render/templates/clawhip-monitor-repo.toml.tmpl`) and the pipeline's auto-discovery scope (clone the repo under `gh_root` and it's in the fleet — see [40-gjc-bot-automation.md](40-gjc-bot-automation.md)); `channel` is a **name** resolved through `[discord.channels]`, never an ID directly |
| `[[repos]]` | `workitem_surface` | shipping-default | **Optional, default `false`.** Opts this repo's channel into the v2 managed work-item path. The renderer collects every repo with `workitem_surface = true` into `RELAY_WORKITEM_CHANNELS` (comma-joined numeric IDs); while every repo leaves it false/unset, that var renders **empty** → `WorkitemChannels::None` → the managed path is fully OFF and the relay behaves byte-identically to v1 |

## Renderer command reference

`render/render.sh <command>`, run from anywhere inside the `gjc-fleet` checkout (it resolves its
own repo root the same way the pipeline scripts do):

| Command | What it does |
|---|---|
| `render [--out DIR]` | Stages every render target (config files, env files, systemd units) into a scratch dir under `~/.gjc-bot/render-out/<timestamp>/` (or `--out`). **Touches nothing live.** |
| `diff` | Unified diff of staged vs. live for every target, unit files included; exits 1 if anything differs ("drift") |
| `apply [--yes]` | Per-target diff + interactive confirm (or `--yes` to skip prompts) + atomic install (`mktemp` + `mv` in the target's own directory) for **config/env files only** |
| `apply --units` | As above, plus installs the rendered systemd units to `~/.config/systemd/user/` (creates `clawhip.service.d/` as needed). Does **not** run `daemon-reload` for you — that's a deliberate separate step |
| `check [--config F]` | The CI gate: renders from `fleet.toml.example` (or `--config`), validates the result parses as TOML, runs [route invariants](#route-invariants) + design-system kind coverage, and greps the whole repo for numeric Discord-scale IDs (15+ digits), allowing only the zero-padded placeholder shape |
| `doctor` | Host checks for files the renderer deliberately does **not** own — hermes' `config.yaml` (gjc MCP command line, workdir roots, `terminal.cwd`, the duplicate `terminal:` block footgun), stale hermes cron workdirs, `~/.gjc/agent/mcp.json` permissions, deployed `~/.gjc-relay/*.sh` vs. `relay/runtime/*.sh` drift, and required keys in `~/.clawhip/clawhip.env` |

**The byte-identical philosophy.** The renderer's design goal is that switching from hand-edited
files to rendered ones changes *nothing* about what runs. The 2026-07-07 migration's acceptance
gate was exactly this: the first `render/render.sh render` on the live host reproduced
`~/.clawhip/config.toml`, `~/.gjc-relay/relay.env`, `~/.gjc-relay/design-system.json`, and all 14
live unit files **byte-for-byte** before anything was applied. `render diff` is meant to stay the
everyday tool after that — it **replaces the historical dated `.bak-*` convention**
(see [50-configuration-and-state.md](50-configuration-and-state.md)) as the way you review a
config change before it goes live; existing `.bak-*` files on disk are untouched, kept as forensic
history of the pre-renderer waves.

Only the six `[[monitors.git.repos]]` blocks inside `clawhip-config.toml.tmpl` are **generated**
(one per `[[repos]]` entry, via `render/templates/clawhip-monitor-repo.toml.tmpl` and
`build_monitor_blocks()` in `render.sh`). Every other route in that template — all 15 of clawhip's
`[[routes]]` — is **static template text**, never generated, so route semantics can't drift from a
`fleet.toml` edit; see [Route invariants](#route-invariants).

## Rendered env vars (B-2/B-3 + relay v2)

The renderer turns the new `fleet.toml` keys into env lines the units read via `EnvironmentFile=`.
Numeric Discord IDs are appended at render time (never in a tracked template); every other knob rides
a tracked `.tmpl`.

**`~/.gjc-bot/gjc-bot.env`** (from `render/templates/gjc-bot.env.tmpl`, mode 0600) — besides the three
channel IDs (`ISSUE_NOTIFY_CHANNEL`/`MERGE_GATE_CHANNEL`/`REVIEW_NOTIFY_CHANNEL`) it now carries:
`REVIEW_ENGINE` (from `[review].engine`); `REVIEW_AUTOMATED_AUTHORS` (space-joined),
`REVIEW_POLICY_MAX_HANDLER_RUNS`, `REVIEW_POLICY_DECISION_MODE` (from `[review.policy]`); and
`CI_FIXER_ENABLED` (rendered `0`/`1`, never empty — an absent `[ci_fixer]` block ⇒ `0`/OFF),
`CI_FIXER_MAX_PER_SHA`, `CI_FIXER_MAX_PER_PR`, `CI_FIXER_BACKOFF_BASE_MINS` (from `[ci_fixer]`).

**`~/.gjc-relay/relay.env`** (from `relay.env.tmpl`, mode 0600) — the v2 managed-path lines are
**appended by `render.sh`** after the tracked template: `RELAY_MANAGED_RATE` (always),
`RELAY_WORKITEM_CHANNELS` (comma-joined numeric IDs of the `workitem_surface = true` repos plus
any `[relay].workitem_channels` extra names — **empty by default** ⇒ managed path OFF),
`GJC_LAB_CHANNEL` (the lab channel numeric ID for
`relay-heartbeat.sh`), and any `RELAY_DEBOUNCE_SECS__<numeric-id>` lines from `[relay.debounce]`
(none by default). See `render.sh` `do_render` for the exact append order.

## New systemd units (all inert / OFF by default)

The B-3 + relay-v2 waves add three units to `gjc-fleet/systemd/` (rendered/installed by
`render/render.sh apply --units`), each shipped in a **do-nothing** state:

- **`ci-fixer.service` / `.timer`** — the gjc-bot fix-until-green poller, every 10 min but **inert
  while `CI_FIXER_ENABLED=0`** (the default; `enabled = false` in `[ci_fixer]`). `Nice=15`,
  `KillMode=process` (keeps the detached fix run alive past the oneshot). Mechanism on
  [40-gjc-bot-automation.md](40-gjc-bot-automation.md#fix-until-green-ci-fixer).
- **`gjc-relay-heartbeat.service` / `.timer`** — a self-priming token-cache heartbeat (no-op inbound
  via clawhip), every 120 s; a pure liveness ping. Mechanism on [35-gjc-relay.md](35-gjc-relay.md).
- **`gjc-relay-health-watch.service` / `.timer`** — an out-of-band alarm on a stuck delivery queue /
  dead flush thread, every 2 min. Mechanism on [35-gjc-relay.md](35-gjc-relay.md).

All three carry only the **namespace-free** hardening the fleet adopted on 2026-07-07
(`NoNewPrivileges`, `RestrictRealtime`, `LockPersonality`, `SystemCallArchitectures=native`,
`RestrictNamespaces`, `MemoryDenyWriteExecute`) — no `ProtectSystem`/`ProtectHome`/`PrivateTmp`, matching
`gjc-relay.service` under this host's AppArmor user-namespace restriction (see
[50-configuration-and-state.md](50-configuration-and-state.md) and
[35-gjc-relay.md](35-gjc-relay.md)). The heartbeat/health-watch timers use fixed literal cadences kept
in sync with `RELAY_HEARTBEAT_SECS` (relay.env) by convention — systemd timers cannot read
`EnvironmentFile` values.

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

- 2026-07-07 — Initial draft (created by the monorepo migration).
- 2026-07-08 (notification-overhaul config surface) — Documented the new `fleet.toml` sections against
  the renderer + example: `[relay].managed_rate` (presets low/medium/high + explicit) and optional
  `[relay.debounce]` per-channel pins; per-`[[repos]]` `workitem_surface` (default false ⇒ empty
  `RELAY_WORKITEM_CHANNELS` ⇒ managed path OFF); `[review].engine` (with model_primary/fast now
  documented as claude-only); `[review.policy]` (automated_authors/max_handler_runs/decision_mode);
  and `[ci_fixer]` (enabled=false/max_per_sha/max_per_pr/backoff_base_mins). Added a **Rendered env
  vars** section (the new `gjc-bot.env` + appended `relay.env` lines) and a **New systemd units**
  section (`ci-fixer`, `gjc-relay-heartbeat`, `gjc-relay-health-watch` — all inert/OFF by default,
  namespace-free hardening). Status → reviewed; last_verified → 2026-07-08.
