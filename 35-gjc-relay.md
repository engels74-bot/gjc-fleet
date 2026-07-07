<!--
status: draft            # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/.gjc-relay/ (src/main.rs, design-system.json, relay.env, dlq-watch.sh, alert.sh)
  - /etc/systemd/system/{gjc-relay,gjc-dlq-watch,gjc-relay-alert}.service
  - /etc/systemd/system/clawhip.service.d/10-gjc-relay.conf
  - ~/.omc/plans/discord-unification-plan.md
  - ~/github/engels74-bot/gjc-bot-scripts/lib/discord-embed.sh
  - ~/github/engels74/gjc/clawhip/src/{dispatch.rs,discord.rs}, ~/.clawhip/{config.toml,clawhip.env}
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
`~/.gjc-relay/src/main.rs`; deps `tiny_http` + `ureq` + `chrono`/`chrono-tz`) that sits **in-path**
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

Everything lives in `~/.gjc-relay/` (deliberately outside the three "protected" repos):

| File | Role |
|---|---|
| `gjc-relay` (~1.8 MB ELF) | The compiled static binary the service runs |
| `src/main.rs`, `Cargo.toml` | Source (own crate `gjc-relay` 1.0.0; build tree out-of-tree) |
| `design-system.json` | **Single source of truth** for embed styling: 23 `kind`s (22 event kinds + `default`) → color/emoji/title, timezone Europe/Berlin. Also read by repo-bot's `lib/discord-embed.sh` (now `~/github/engels74-bot/gjc-bot-scripts/lib/discord-embed.sh`, post `gjc-bot`→`gjc-bot-scripts` reorg) so both emitters render identically |
| `relay.env` | `RELAY_BIND=127.0.0.1:25295`, `RELAY_DESIGN_SYSTEM`. Header comment states it holds **no token** — the bot token arrives per-request in the forwarded `Authorization` header and is never stored |
| `dlq-watch.sh` | Out-of-band DLQ-bury alarm (see below) |
| `alert.sh` | `OnFailure` alarm for the relay itself |
| `check-kind-coverage.sh` | Gate verifying design-system kind coverage |

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
- repo-bot's `lib/discord-embed.sh` (`~/github/engels74-bot/gjc-bot-scripts/lib/discord-embed.sh`),
  which builds the same envelope and sends it via `clawhip send` (see
  [40-repo-bot-automation.md](40-repo-bot-automation.md#shared-lib)).

## Scope — what does and does not flow through it

- **Through the relay:** every clawhip **bot-token channel send** (the only kind the live config
  uses). That covers all GitHub monitor events, all repo-bot narration and verdicts.
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
| `gjc-relay.service` | `ExecStart=/home/cvps/.gjc-relay/gjc-relay`; `Restart=always`, `RestartSec=1`, `StartLimitIntervalSec=0` (never stop retrying); `OnFailure=gjc-relay-alert.service`; hardening (`NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome=read-only`, `PrivateTmp`); `Docs=` points at the unification plan |
| `clawhip.service.d/10-gjc-relay.conf` | Ordering drop-in: clawhip starts `After=`/`Wants=` the relay |
| `gjc-dlq-watch.service` | Tails `journalctl -u clawhip.service -f` for `clawhip dlq bury:`; on a hit, fires a **direct** curl to Discord's API (bypassing clawhip *and* the relay, since either may be down) into `#gjc-approvals`, using the bot token read from `clawhip.env`; 300 s cooldown |
| `gjc-relay-alert.service` | Oneshot `OnFailure` target: direct-to-Discord curl + journald `logger` + local `mail` fallback. **Rarely fires by design** — a unit comment in `gjc-relay.service` notes that `Restart=always` + `StartLimitIntervalSec=0` means the relay can never reach the `failed` state; the *operative* alarm for real notification loss is `gjc-dlq-watch.service` |

Live journal evidence (2026-07-06): `[transform] POST …/messages kind=github.pr-status-changed -> 200`
— the relay is actively rewriting production traffic.

## How it connects to the rest of the system

- **clawhip → relay → Discord** is the fleet's entire embed path; see the topology diagram in
  [00-overview.md](00-overview.md).
- The **design system** is shared: relay templates (clawhip side) and `discord_embed()`
  (`~/github/engels74-bot/gjc-bot-scripts/lib/discord-embed.sh`, repo-bot side) both resolve
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
