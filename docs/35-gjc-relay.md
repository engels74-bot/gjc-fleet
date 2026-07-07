<!--
status: draft            # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/github/engels74-bot/gjc-fleet/relay/ (src/main.rs, Cargo.toml, runtime/)
  - ~/.gjc-relay/ (deployed binary, design-system.json, relay.env, dlq-watch.sh, alert.sh)
  - ~/.config/systemd/user/{gjc-relay,gjc-dlq-watch,gjc-relay-alert}.service
  - ~/.config/systemd/user/clawhip.service.d/10-gjc-relay.conf
  - ~/github/engels74-bot/gjc-fleet/systemd/ (unit templates), ~/github/engels74-bot/gjc-fleet/render/
  - ~/.omc/plans/discord-unification-plan.md
  - ~/github/engels74-bot/gjc-fleet/pipeline/lib/discord-embed.sh
  - ~/github/engels74/gjc/clawhip/src/{dispatch.rs,discord.rs}, ~/.clawhip/{config.toml,clawhip.env}
  - live drill evidence: relay stop/restore + dlq-watch alert cycle (2026-07-07 gjc-fleet migration)
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  This page was ADDED beyond the originally prescribed doc layout: the relay is a fourth,
  locally-authored component that the earlier hermes-stack build-log (now retired) never mentioned,
  and it is in-path on every production Discord post — it needs its own page.
-->

# gjc-relay (and the Discord embed pipeline)

> Component page for the loopback relay stack added by the 2026-07-06 "Discord unification" wave.
> Producer side: [30-clawhip.md](30-clawhip.md). Index: [README.md](README.md).

## Purpose

**gjc-relay** is a small, locally-authored Rust reverse proxy (v1.0.0, 708 lines,
`src/main.rs` in the `relay/` subdir of the `engels74-bot/gjc-fleet` monorepo at
`~/github/engels74-bot/gjc-fleet/relay`; deps `tiny_http` + `ureq` + `chrono`/`chrono-tz`) that sits **in-path**
between clawhip and Discord. clawhip's Discord payload is hardcoded to plain
`{"content": "<string>"}` in its source, so fleet notifications could never be rich embeds without
forking clawhip. The chosen fix ("Option A" in
`~/.omc/plans/discord-unification-plan.md`) was: point clawhip's REST base URL at a loopback proxy
(`CLAWHIP_DISCORD_API_BASE=http://127.0.0.1:25295/api/v10` in `~/.clawhip/clawhip.env`) and have
the proxy rewrite specially-marked messages into Discord **embeds** — with **zero source changes**
to clawhip, hermes, or gajae-code (a hard constraint of the plan).

Precision matters here: gjc-relay is **not** a downstream consumer/transform of clawhip events —
it is a **reverse proxy that clawhip's outbound Discord REST traffic flows through**.

## Structure

Since 2026-07-07 the source lives in the **`relay/` subdirectory of the `engels74-bot/gjc-fleet`
monorepo** (`~/github/engels74-bot/gjc-fleet/relay` — the same repo as the `pipeline/`, `render/`,
`systemd/`, and `docs/` subdirs, committed/pushed as `engels74-bot`), and `~/.gjc-relay/` is purely
the **runtime home**, the same source-repo → deployed-runtime pattern as `~/.clawhip`/`~/.hermes`.
Before that, the crate briefly had its own repo, `engels74-bot/gjc-relay` (now archived, pointer
README, history preserved via merge into `gjc-fleet`); before that it lived un-versioned inside the
runtime dir (`~/.gjc-relay/src`, built in place).

Repo subdir (`~/github/engels74-bot/gjc-fleet/relay/`):

| Path | Role |
|---|---|
| `src/main.rs`, `Cargo.toml`, `Cargo.lock` | The crate (own crate `gjc-relay` 1.0.0, incl. the 17 unit tests) |
| `runtime/` | Versioned copies of the authored runtime artifacts below (`design-system.json`, `dlq-watch.sh`, `alert.sh`, `check-kind-coverage.sh`). The live copies in `~/.gjc-relay/` stay canonical at runtime; the committed alert scripts carry **no** numeric channel-ID default (must come from `GJC_ALERT_CHANNEL` — no numeric Discord IDs in git) |
| `README.md`, `prek.toml`, `.gitignore` | Deploy procedure + sibling-standard pre-commit hooks; `relay.env`, `target/`, and the binary are ignored |

The relay crate's own `README.md` carries a `[!IMPORTANT]` pointer at the top of the *old*
`engels74-bot/gjc-relay` repo directing readers here, to `gjc-fleet`'s `relay/` subdir.

Runtime home (`~/.gjc-relay/`):

| File | Role |
|---|---|
| `gjc-relay` (~1.8 MB ELF) | The compiled static binary the service runs (built from the repo, copied here) |
| `design-system.json` | **Single source of truth** for embed styling: 23 `kind`s (22 event kinds + `default`) → color/emoji/title, timezone Europe/Berlin. Also read by gjc-bot's `lib/discord-embed.sh` (`~/github/engels74-bot/gjc-fleet/pipeline/lib/discord-embed.sh`, since the 2026-07-07 monorepo migration) so both emitters render identically |
| `relay.env` | `RELAY_BIND=127.0.0.1:25295`, `RELAY_DESIGN_SYSTEM`. Header comment states it holds **no token** — the bot token arrives per-request in the forwarded `Authorization` header and is never stored |
| `dlq-watch.sh` | Out-of-band DLQ-bury alarm (see below) |
| `alert.sh` | `OnFailure` alarm for the relay itself |
| `check-kind-coverage.sh` | Gate verifying design-system kind coverage |

## Build → deploy

From the monorepo checkout (the systemd unit needs **no** change on redeploy —
`ExecStart=%h/.gjc-relay/gjc-relay`; the unit itself is now a **user** unit, so no `sudo`):

```sh
cd ~/github/engels74-bot/gjc-fleet/relay
cargo test               # 17 unit tests
cargo build --release    # opt-level=z, LTO, stripped → ~1.8 MB static binary
cp --remove-destination target/release/gjc-relay ~/.gjc-relay/gjc-relay
systemctl --user restart gjc-relay.service
```

Keep the restart window short — the relay is in-path for every fleet Discord notification and
clawhip DLQ-buries on transport failure with no retry. Post-deploy checks: `systemctl --user
is-active gjc-relay`, `curl http://127.0.0.1:25295/healthz`, a canary embed through
`discord_embed`/`clawhip send` into `#gjc-lab`, and `gjc-dlq-watch.service` still active with no
`dlq bury` lines. The 2026-07-07 monorepo-adoption deploy was verified exactly this way (repo-built
binary byte-identical to the previously deployed one), and the same-day user-units cutover added a
live **DLQ drill**: relay stopped → a doomed canary event → `clawhip dlq bury:` observed in the
**user** journal (`journalctl --user -u clawhip`) → `gjc-dlq-watch` alerted `#gjc-approvals` in
~6 s → relay restored → a post-drill canary returned 200.

## How it works (the `GJCEMBED1` protocol)

The relay intercepts `POST /channels/{id}/messages` and does a **three-way split** on the message
`content` (line refs are approximate — the 2026-07-07 batch-split insertion shifted offsets;
stable anchors: `MAGIC` at `main.rs:22`, `ALLOWED_KEYS` at `main.rs:23`, batch loop with caps at
`main.rs:244-270`, degrade path at `main.rs:419`):

1. **No `GJCEMBED1 ` prefix** → forward byte-for-byte (e.g. any plain message).
2. **Valid envelope** — `GJCEMBED1 key=value … :: <free-form tail>` (allowed head keys:
   `kind repo status actor branch url`, `main.rs:23`) → build a Discord **embed** styled from
   `design-system.json`.
3. **Prefix present but malformed** → clean plain-text degrade, stripping envelope artifacts.

**Multi-envelope batches (added 2026-07-07):** clawhip's routine batcher joins several rendered
envelopes with `\n` into ONE message (`clawhip src/dispatch.rs` `contents.join("\n")`), which
previously rendered as a single embed with raw envelope lines inside its description. When every
non-empty line starts with `GJCEMBED1 `, the relay now builds **one embed per line** (log label
`kind=batch[N]:…`), respecting Discord's caps: 10 embeds/message, 6000 chars aggregate across
embeds, 2000 chars `content`. Lines that don't fit or fail to parse degrade to clean text in
`content` alongside the embeds.

Everything else (GET channel lookups, non-message POSTs) is proxied verbatim to
`https://discord.com`. `GET /healthz` is answered locally. Discord's exact status and body are
mirrored back — **including 429** — so clawhip's rate-limit backoff still works.
A `RELAY_FORCE_429` diagnostic env can force a synthetic 429 on a single test channel to drill
backoff with zero production blast radius (`main.rs:~44-51,~127-140`). 17 unit tests cover charset,
degrade, 429 mirroring, caps, UTF-8 (test module `main.rs:518-708`).

Producers of `GJCEMBED1` envelopes:
- clawhip route `template = "GJCEMBED1 kind=… :: …"` lines (`~/.clawhip/config.toml:58-83`).
- gjc-bot's `lib/discord-embed.sh` (`~/github/engels74-bot/gjc-fleet/pipeline/lib/discord-embed.sh`),
  which builds the same envelope and sends it via `clawhip send` (see
  [40-gjc-bot-automation.md](40-gjc-bot-automation.md#shared-lib)).

## Scope — what does and does not flow through it

- **Through the relay:** every clawhip **bot-token channel send** (the only kind the live config
  uses). That covers all GitHub monitor events, all gjc-bot narration and verdicts.
- **Not through the relay:** hermes' conversational replies (own bot identity, plain markdown —
  deliberately excluded because hermes' Discord adapter is content-only and the plan forbade
  source changes); clawhip **webhook-URL** sends, which use a separate HTTP client that ignores
  the api-base override (`clawhip src/discord.rs:79`) — none are configured live.

## Live services (the supervision stack)

The relay is in-path on every production Discord post, and clawhip's DLQ is an in-memory `Vec`
with no retry on transport errors ([30-clawhip.md](30-clawhip.md#dlq-bury-semantics--the-load-bearing-fragility)).
A permanently-down relay would therefore mean **silent, permanent notification loss**. Four
systemd units manage that risk:

| Unit | Role |
|---|---|
| `gjc-relay.service` (user-scope) | `ExecStart=%h/.gjc-relay/gjc-relay`; `Restart=always`, `RestartSec=1`, `StartLimitIntervalSec=0` (never stop retrying); `OnFailure=gjc-relay-alert.service`; `Documentation=` points at this page. Hardening **changed 2026-07-07**: namespace-based sandboxing (`ProtectSystem`/`ProtectHome`/`PrivateTmp`) was **dropped** — a user manager needs unprivileged user namespaces for that, and Ubuntu ≥24.04's AppArmor restriction on unprivileged userns makes it a start-failure risk on this single point of failure. Replaced with directives that don't need namespaces: `NoNewPrivileges`, `RestrictRealtime`, `LockPersonality`, `SystemCallArchitectures=native`, `RestrictNamespaces`, `MemoryDenyWriteExecute` |
| `clawhip.service.d/10-gjc-relay.conf` (user-scope) | Ordering drop-in: clawhip starts `After=`/`Wants=` the relay |
| `gjc-dlq-watch.service` (user-scope) | Tails `journalctl --user -u clawhip.service -f` for `clawhip dlq bury:`; on a hit, fires a **direct** curl to Discord's API (bypassing clawhip *and* the relay, since either may be down) into `#gjc-approvals`, using the bot token read from `clawhip.env`; 300 s cooldown |
| `gjc-relay-alert.service` (user-scope) | Oneshot `OnFailure` target: direct-to-Discord curl + journald `logger` + local `mail` fallback. **Rarely fires by design** — a unit comment in `gjc-relay.service` notes that `Restart=always` + `StartLimitIntervalSec=0` means the relay can never reach the `failed` state; the *operative* alarm for real notification loss is `gjc-dlq-watch.service` |

All four units are rendered from `gjc-fleet/systemd/*.service{,.d/*.conf}` and installed to
`~/.config/systemd/user/` by `render/render.sh apply --units`; `WantedBy=default.target` +
lingering enabled means they start at boot without a login session, with no `sudo` anywhere in
their lifecycle.

Live journal evidence (2026-07-06): `[transform] POST …/messages kind=github.pr-status-changed -> 200`
— the relay is actively rewriting production traffic. Re-confirmed post-cutover (2026-07-07) via the
DLQ drill above (see [Build → deploy](#build--deploy)).

## How it connects to the rest of the system

- **clawhip → relay → Discord** is the fleet's entire embed path; see the topology diagram in
  [00-overview.md](00-overview.md).
- The **design system** is shared: relay templates (clawhip side) and `discord_embed()`
  (`~/github/engels74-bot/gjc-fleet/pipeline/lib/discord-embed.sh`, gjc-bot side) both resolve
  styling from `~/.gjc-relay/design-system.json`, so a given `kind` looks identical regardless of
  emitter.
- Documented in `~/.omc/plans/discord-unification-plan.md` (design),
  `~/.omc/research/discord-unification-findings.md` (pre-plan investigation), and
  `~/.omc/progress.txt` (execution log, all phases verified). **The earlier hermes-stack build-log
  (now retired) predated the relay entirely and never mentioned it.**

## Open questions

- Is the relay considered **permanent production** or still probationary? (The unification run
  ended "Ready for cancel"; the relay is live on all production traffic, so effectively permanent —
  but no explicit decision of record.)
- Reliability posture: infinite restart + DLQ-watch alarm is the current answer for an in-path
  single point of failure. Is that the intended end state, or is a persistent DLQ / retry layer
  planned?
- `~/.gjc-relay/.omc/` subdir contains only `sessions/` and `state/` — this looks like
  oh-my-claudecode's own per-repo working state from development sessions in this repo, not
  anything relay-runtime-relevant. Contents of those subdirs were not inspected further.
- Fallback "Option C" (per-route webhook URLs) is documented in the plan as the security-hardened
  fallback — under what conditions would it be activated?

## Changelog

- 2026-07-06 — Initial draft (relay deployed and verified the same day by the Discord-unification
  wave; this page added beyond the originally prescribed layout — see maintainer_notes).
- 2026-07-07 — Multi-envelope batch splitting added to `transform_body` (one embed per `GJCEMBED1`
  line, +2 unit tests) after the EasyHDR RUSTSEC run exposed batched issue-closure notifications
  rendering as plain text. design-system.json grew from 17 to 23 kinds
  (`github.issue-closed/-commented`, `github.ci-passed/-failed/-started/-cancelled`) to back the
  new clawhip issue/CI embed routes (see [30-clawhip.md](30-clawhip.md) changelog). Canary-verified
  end-to-end in #gjc-lab (`kind=batch[3]:… -> 200`).
- 2026-07-07 (later) — Verification pass: stale figures refreshed (main.rs ~640→~710 lines; unit
  tests corrected to 17 — the earlier "23" was the kind count, not the test count; kind count 17→23
  in the Structure table to match the changelog); post-batch-split line refs re-anchored/softened;
  noted that `gjc-relay-alert` rarely fires by design (dlq-watch is the operative alarm).
- 2026-07-07 (repo-move pass) — Re-verified against live source following the `gjc-architecture`
  repo move and the `gjc-bot`→`gjc-bot-scripts` reorg. Updated all `lib/discord-embed.sh` references
  to the new path `~/github/engels74-bot/gjc-bot-scripts/lib/discord-embed.sh` (Structure table,
  producers list, and cross-system-connection bullet). Confirmed figures directly against source:
  `main.rs` is exactly 708 lines (was "~710", now exact); `MAGIC`/`ALLOWED_KEYS` still at
  `main.rs:22-23`; test module confirmed at `main.rs:518-708` (17 `#[test]` functions, unchanged);
  `design-system.json` confirmed at exactly 23 `kind` entries (22 event kinds + `default`), unchanged
  since the prior pass. Re-verified the full systemd supervision stack against the live unit files
  (`gjc-relay.service`, `gjc-dlq-watch.service`, `gjc-relay-alert.service`,
  `clawhip.service.d/10-gjc-relay.conf`) and `systemctl is-active` — all match the page's description
  exactly, all three long-running units `active`. Confirmed `clawhip src/discord.rs:79` (api_base
  fallback) and `~/.clawhip/clawhip.env` (`CLAWHIP_DISCORD_API_BASE=http://127.0.0.1:25295/api/v10`)
  and `clawhip src/dispatch.rs:375` (`contents.join("\n")`) still match. Resolved the
  `~/.gjc-relay/.omc/` open question (contains only oh-my-claudecode `sessions/`/`state/` dirs from
  dev sessions — not relay-runtime-relevant).
- 2026-07-07 (runbook-retirement pass) — Reframed the two references to the earlier hermes-stack
  build-log/runbook (maintainer note + the "predated the relay" line) to past tense; that build-log
  has been deleted and this doc set is the single source of truth. No path now points at it.
- 2026-07-07 (fleet/ move + component rename) — Terminology only: repo-bot → **gjc-bot**;
  cross-links updated to `40-gjc-bot-automation.md`. No relay behavior change.
- 2026-07-07 (repo adoption) — Source moved under version control: new repo
  **`engels74-bot/gjc-relay`** at `~/github/engels74-bot/gjc-relay` (pushed, public like its
  siblings) holding the crate + `runtime/` copies of the authored runtime artifacts + README +
  prek.toml. Structure section split into repo vs runtime home; new "Build → deploy" section.
  Rebuilt from the repo (17 tests passed; binary byte-identical to the deployed one), redeployed,
  and canary-verified end-to-end in `#gjc-lab` (`kind=agent.finished -> 200`, no DLQ burials).
  `~/.gjc-relay/{src,Cargo.toml,Cargo.lock,target}`, the `.bak-embedbatch-*` files, and the stale
  out-of-tree `~/.gjc-relay-build` cache removed — the runtime dir now holds only
  binary + env + design-system + scripts. Committed alert scripts drop the numeric channel-ID
  default (env-only, `GJC_ALERT_CHANNEL`); live copies in `~/.gjc-relay/` stay canonical.
- 2026-07-07 (gjc-fleet monorepo + user-units migration) — The short-lived standalone
  `engels74-bot/gjc-relay` repo is now itself archived (pointer README, history preserved via
  merge): the crate lives on as the `relay/` subdirectory of the new `engels74-bot/gjc-fleet`
  monorepo (`~/github/engels74-bot/gjc-fleet/relay`), alongside `pipeline/`, `render/`, `systemd/`,
  `docs/`. Build → deploy `cd` path updated accordingly; `sudo systemctl restart` replaced by
  `systemctl --user restart` throughout. All four relay-stack units (`gjc-relay`, `gjc-dlq-watch`,
  `gjc-relay-alert`, the `clawhip.service.d/10-gjc-relay.conf` drop-in) moved from system-level to
  **user-scope** systemd, rendered from `gjc-fleet/systemd/` and installed to
  `~/.config/systemd/user/` by `render/render.sh apply --units`; `gjc-relay.service`'s hardening
  changed as part of the same move — `ProtectSystem`/`ProtectHome`/`PrivateTmp` dropped (would
  require unprivileged user namespaces, a start-failure risk under Ubuntu ≥24.04's AppArmor
  restriction) in favor of `NoNewPrivileges`/`RestrictRealtime`/`LockPersonality`/
  `SystemCallArchitectures=native`/`RestrictNamespaces`/`MemoryDenyWriteExecute`. `gjc-dlq-watch`
  now tails the **user** journal (`journalctl --user -u clawhip.service`). Verified live with a
  full cutover + DLQ drill: relay stopped, a doomed canary DLQ-buried, `gjc-dlq-watch` alerted
  `#gjc-approvals` in ~6 s, relay restored, post-drill canary 200 — see
  [Build → deploy](#build--deploy). Deployed copies in `~/.gjc-relay/` reconfirmed byte-identical
  to `relay/runtime/` (checked by `render/render.sh doctor`).
