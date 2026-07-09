<!--
status: draft            # draft | reviewed | verified
last_verified: 2026-07-09
sources:
  - ~/github/engels74-bot/gjc-fleet/relay/ (src/{config,http,queue,flush,policy,registry,store,discord,envelope,render,log,main}.rs, Cargo.toml, runtime/)
  - ~/github/engels74-bot/gjc-fleet/relay/runtime/ (design-system.json, relay-heartbeat.sh, relay-health-watch.sh, dlq-watch.sh, alert.sh, check-kind-coverage.sh)
  - ~/github/engels74-bot/gjc-fleet/systemd/gjc-relay*.{service,timer} (+ clawhip.service.d/10-gjc-relay.conf)
  - ~/github/engels74-bot/gjc-fleet/render/{render.sh,templates/relay.env.tmpl,checks/lint-routes.sh}
  - ~/.gjc-relay/ (deployed binary, design-system.json, relay.env, state/, scripts)
  - ~/.config/systemd/user/{gjc-relay,gjc-relay-heartbeat,gjc-relay-health-watch,gjc-dlq-watch,gjc-relay-alert}.{service,timer}
  - ~/.omc/plans/discord-unification-plan.md, ~/.omc/plans/notification-overhaul-plan.md
  - ~/github/engels74/gjc/clawhip/src/{dispatch.rs,discord.rs}, ~/.clawhip/{config.toml,clawhip.env}
maintainer_notes: >
  Edit this file in isolation. Keep headings stable. Changelog is a single current-state
  rebaseline entry — rewrite this page to current state rather than appending; prior history
  lives in git.
  This page was ADDED beyond the originally prescribed doc layout: the relay is a fourth,
  locally-authored component that the earlier hermes-stack build-log (now retired) never mentioned,
  and it is in-path on every production Discord post — it needs its own page.
  ACCURACY RULE: this page is the single source of truth. Every mechanism below is verified against
  the actual relay/ source, not the plan — where code and plan diverged, the code wins and the
  divergence is called out explicitly (see "Where the code diverged from the plan").
  THREE-LAYER CONFIG RULE: never write a real numeric Discord channel ID here. Use names/placeholders.
-->

# gjc-relay (and the Discord embed pipeline)

> Component page for the loopback relay stack added by the 2026-07-06 "Discord unification" wave and
> rebuilt into a stateful v2 by the 2026-07-08 "notification overhaul".
> Producer side: [30-clawhip.md](30-clawhip.md). Index: [README.md](README.md).

## Purpose

**gjc-relay** is a small, locally-authored Rust reverse proxy (crate `gjc-relay` 1.0.0, now **12
source files** totalling ~6.3k lines incl. tests under `relay/src/`; deps `tiny_http` + `ureq` +
`serde`/`serde_json` + `base64` + `chrono`/`chrono-tz`) that sits **in-path** between clawhip and
Discord. clawhip's Discord payload is hardcoded to plain `{"content": "<string>"}` in its source, so
fleet notifications could never be rich embeds without forking clawhip. The chosen fix ("Option A" in
`~/.omc/plans/discord-unification-plan.md`) was: point clawhip's REST base URL at a loopback proxy
(`CLAWHIP_DISCORD_API_BASE=http://127.0.0.1:25295/api/v10` in `~/.clawhip/clawhip.env`) and have the
proxy rewrite specially-marked messages into Discord **embeds** — with **zero source changes** to
clawhip, hermes, or gajae-code (a hard constraint of the plan).

Precision matters here: gjc-relay is **not** a downstream consumer/transform of clawhip events —
it is a **reverse proxy that clawhip's outbound Discord REST traffic flows through**.

## v1 → v2: from stateless rewriter to stateful work-item narrator

The relay has two behavioural modes in the same binary:

- **v1 (stateless transform, the original wave).** Every inbound `POST /channels/{id}/messages` is a
  pure, memoryless three-way split on `content`: forward-verbatim, build-embed, or clean-degrade
  (see [How the v1 transform works](#how-the-v1-transform-works-the-gjcembed1-protocol)). No disk
  state, no correlation between events — one inbound message → one outbound Discord call.
- **v2 (stateful, work-item-centric, the notification overhaul).** For channels that **opt in** via
  `RELAY_WORKITEM_CHANNELS`, the relay **absorbs** a well-formed envelope instead of forwarding it:
  it durably enqueues the intended Discord operation, immediately acks clawhip with a synthetic
  `200`, and a single background flush thread later delivers it — **coalescing** a burst of edits
  into one PATCH, **threading** per-item detail, and **dropping** the branch-push CI flood. The
  visible result is a *living summary embed* per issue/PR (edited in place) with a per-item thread,
  instead of v1's one-embed-per-event stream.

**The gate is the whole safety story.** `RELAY_WORKITEM_CHANNELS` is rendered **empty by default**
(`render.sh` emits `RELAY_WORKITEM_CHANNELS=` unless a channel opts in), which parses to
`WorkitemChannels::None`. With it empty, `Config::channel_is_managed()` is `false` for every channel,
the managed absorb branch in `http.rs` is unreachable, and the relay is **byte-identical to v1**. The
v2 modules (`discord`/`policy`/`registry`/`store`/`queue`/`flush`) still load and the flush thread
still runs, but the queue stays permanently empty. This byte-identity is enforced by a unit test
(`managed_path_panic_falls_back_to_byte_identical_v1_output`).

## Module layout (12 source files)

Repo subdir (`~/github/engels74-bot/gjc-fleet/relay/src/`):

| File | Role |
|---|---|
| `main.rs` | Process wiring: load config, **load+reconcile** the durable snapshot against the queue before serving, spawn the single flush thread, spawn the ≤1/s state persister, run 8 HTTP worker threads. |
| `config.rs` | `Config::from_env()` — all `RELAY_*` env parsing incl. `ManagedRate` presets and the two diagnostics (`RELAY_FORCE_429`, `RELAY_FAULT_AFTER_POST`). v2 fields are inert while `workitem_channels` is empty. |
| `http.rs` | Request handling: v1 transform, the v2 managed **absorb** path (`try_absorb`), the in-memory `TokenCache`, and `ManagedCtx`. |
| `envelope.rs` | `GJCEMBED1` primitives: `MAGIC`, the **14** allowed head keys, `parse_envelope`, `t64` base64url title decode, `clean_degrade`, `cap`. |
| `render.rs` | Embed builders: `build_embed` (v1 line) and `build_embed_from_envelope` (v2 managed) + Discord's 6000-char aggregate cap. |
| `policy.rs` | The **A6 surface taxonomy** — pure `decide()` mapping a kind to `NewMessage`/`EditSummary`/`ThreadPost`/`EditAndThread`/`Unmanaged`/`Drop`. |
| `registry.rs` | In-memory `State`: work items keyed `owner/repo#number`, facets (ci/review/pipeline), dedup ledger, fingerprint helpers, TTL prune. |
| `queue.rs` | The **two-phase durable operation queue** (`enqueue`/`mark_committed`/`scan`/`bury`). |
| `flush.rs` | The **single supervised deliverer**: debounce, `ChannelBucket` pacing, retry/backoff, read-back reconciliation, thread/recreate handling. |
| `store.rs` | `state.json` load/save (atomic tmp+fsync+rename, quarantine on corruption) + the `Persister` rate-limit guard. |
| `discord.rs` | `DiscordApi` trait + `UreqDiscord` (prod) + `MockDiscord` (test double). Bearer token is per-call, never stored. |
| `log.rs` | `log_meta(event, msg)` → `gjc-relay [<event>] <msg>` on stdout. **Metadata only** — never headers or bodies. |

`~/.gjc-relay/` remains purely the **runtime home** (binary + `design-system.json` + `relay.env` +
scripts + the new `state/` dir), the same source-repo → deployed-runtime pattern as `~/.clawhip`/
`~/.hermes`. Source lives only in the `gjc-fleet` monorepo's `relay/` subdir.

Runtime home (`~/.gjc-relay/`):

| File / dir | Role |
|---|---|
| `gjc-relay` (ELF) | The compiled static binary the service runs (built from the repo, copied here). |
| `design-system.json` | **Single source of truth** for embed styling. **version 2**: 36 `kind` entries (35 event kinds + `default`, including the 5 new kinds `automerge`/`automerge.escalation`/`hermes-update`/`fleet-update`/`review.backlog`) → color/emoji/title, plus per-managed-kind `surface`/`facet`/`tail_role`/`desc` hints and a top-level `workitem` composer section; timezone Europe/Berlin. Also read by gjc-bot's `lib/discord-embed.sh` so both emitters render identically. The relay treats `version != 2` (or a missing `workitem` section) as "v2 features inert". |
| `state/` | **New in v2.** `state.json` (+ `.tmp`, `.corrupt-<ts>` quarantine), `queue/`, `dead/`, `flush.alive`. See [State dir](#state-directory-the-durability-surface). |
| `relay.env` | Rendered (0600). Holds **no token**. `RELAY_BIND`, `RELAY_DESIGN_SYSTEM`, `RELAY_STATE_DIR`, `RELAY_MANAGED_RATE`, `RELAY_WORKITEM_CHANNELS`, `GJC_LAB_CHANNEL`, `GJC_ALERT_CHANNEL`, optional `RELAY_DEBOUNCE_SECS__<cid>` pins. |
| `relay-heartbeat.sh`, `relay-health-watch.sh`, `dlq-watch.sh`, `alert.sh`, `check-kind-coverage.sh` | Supervision scripts (see [Live services](#live-services-the-supervision-stack)). |

## Build → deploy

From the monorepo checkout (the systemd unit needs **no** change on redeploy —
`ExecStart=%h/.gjc-relay/gjc-relay`; a **user** unit, so no `sudo`):

```sh
cd ~/github/engels74-bot/gjc-fleet/relay
cargo test               # full unit suite across the 12 modules
cargo build --release    # opt-level=z, LTO, stripped → small static binary
cp --remove-destination target/release/gjc-relay ~/.gjc-relay/gjc-relay
systemctl --user restart gjc-relay.service
```

Keep the restart window short — the relay is in-path for every fleet Discord notification and clawhip
DLQ-buries on transport failure with no retry. Post-deploy checks: `systemctl --user is-active
gjc-relay`, `curl http://127.0.0.1:25295/healthz`, a canary embed through `discord_embed`/`clawhip
send` into `#gjc-lab`, and both `gjc-dlq-watch.service` and `gjc-relay-health-watch.timer` active with
no `dead-letter` lines. **In v2** a restart is additionally safe because durability lives in the
on-disk `queue/` (persist-before-ack), not in memory: an in-flight managed op survives the restart and
is replayed by the startup reconciliation scan.

## How the v1 transform works (the `GJCEMBED1` protocol)

The relay intercepts `POST /channels/{id}/messages` and does a **three-way split** on the message
`content` (stable anchors: `MAGIC = "GJCEMBED1 "` and the **14-key** `ALLOWED_KEYS` in
`envelope.rs:7-15`; `transform_body` in `http.rs`):

1. **No `GJCEMBED1 ` prefix** → forward byte-for-byte.
2. **Valid envelope** — `GJCEMBED1 key=value … :: <free-form tail>` → build a Discord **embed** styled
   from `design-system.json`.
3. **Prefix present but malformed** → clean plain-text degrade, stripping envelope artifacts.

The head vocabulary grew from the v1 6 keys (`kind repo status actor branch url`) to **14** — the
overhaul added `number stage sha run passed failed total t64`. `t64` carries a base64url-unpadded
title so arbitrary titles survive the strict slug charset. New keys are **additive**: v1 traffic never
carries them, so v1 rendering is unchanged.

**Multi-envelope batches:** clawhip's routine batcher joins several rendered envelopes with `\n` into
ONE message (`clawhip src/dispatch.rs` `contents.join("\n")`). When every non-empty line starts with
`GJCEMBED1 `, the relay builds **one embed per line** (log label `kind=batch[N]:…`), respecting
Discord's caps (10 embeds/message, 6000 chars aggregate, 2000 chars `content`). Lines that don't fit
or fail to parse degrade to clean text in `content` alongside the embeds.

Everything else (GET channel lookups, non-message POSTs) is proxied verbatim to `https://discord.com`.
`GET /healthz` is answered locally. Discord's exact status and body are mirrored back — **including
429** — so clawhip's rate-limit backoff still works.

## The v2 managed work-item path

### Absorb (http.rs `try_absorb`)

For a channel listed in `RELAY_WORKITEM_CHANNELS`, a well-formed `GJCEMBED1` POST is routed through
`policy::decide` and, if it lands on a managed surface, **absorbed**: the intended Discord operation is
durably enqueued and the caller is acked with a **synthetic 200** (`{"id":"0","channel_id":"…",
"gjc_relay":"accepted"}`). Everything else — unmanaged channel, unmanaged kind, malformed content, flag
unset — falls through to the byte-identical v1 path. The absorb runs entirely **before any ack** and is
wrapped in `catch_unwind`: a panic recovers by falling through to v1 (pre-persist fail-open). A `Drop`
verdict is still acked `200` (so clawhip never DLQ-buries a deliberately-suppressed flood event) and
logged `[dedup-drop]` (replay) or `[drop]` (unknown-item CI flood).

### Surface taxonomy (policy.rs — the flood killer)

`decide()` is a **pure** function; the caller computes `item_known`/`dedup_hit` from a registry
snapshot under the lock, releases the lock, then calls it. Compiled defaults:

| Kind | Item known (anchored) | Item unknown (no anchor) |
|---|---|---|
| `github.issue-opened` | NewMessage | NewMessage |
| `github.issue-commented` | ThreadPost | NewMessage |
| `github.pr-status-changed` (open/reopened) | EditSummary | NewMessage |
| `github.pr-status-changed` (merged/closed) | EditSummary (+ mark terminal) | EditSummary |
| `workitem.dispatched` | EditAndThread | NewMessage |
| `github.ci-started/-passed/-cancelled` | EditSummary | **Drop** (branch-push flood class) |
| `github.ci-failed` | EditAndThread | NewMessage (failures must surface) |
| `workitem.merge-verdict` | NewMessage | NewMessage |
| `agent.approval-requested` | Unmanaged | Unmanaged |
| everything else | Unmanaged | Unmanaged |

Two **non-overridable safety locks** (precedence is safety-critical, do not reorder): (1) a dedup hit
downgrades any managed surface to `Drop`; (2) the unknown-item CI class (Drop for
started/passed/cancelled, NewMessage for failed) is decided *only* by the "is this item known" axis. A
per-kind `design-system` `surface` override may substitute the compiled decision **only** for the
anchored steady state — it can never resurrect the `#easyhdr` reboot-flood class the overhaul exists to
kill. This is the load-bearing property; it has a dedicated regression test
(`flood_drop_cannot_be_overridden_by_per_kind_surface`).

**Where the unknown-item CI drop kills the flood:** a reboot or force-push fires a burst of
`github.ci-*` events for a branch with no tracked work item. In v1 each rendered a separate embed
(the observed `#easyhdr` flood). In v2 they compile to `Drop` (started/passed/cancelled) and are
absorbed silently, while a genuine `ci-failed` still surfaces as a new message.

### Two-phase durable commit (queue.rs)

Every managed delivery is a **persist-before-ack** two-phase commit:

1. **Enqueue.** The op is written to `<state_dir>/queue/<epoch_ms:013>-<seq:010>-<opclass>.json` and
   **fsync'd** (`atomic_write` = `File::create` + `write_all` + `sync_all`) **before** the synthetic
   `200` is returned. `opclass` is one of `new`/`editsummary`/`threadcreate`/`threadpost`. The op file
   **never carries an auth token** (enforced by test) — the token is supplied only at delivery time
   from the in-memory `TokenCache`.
2. **Commit.** When `flush.rs` delivers it, a sibling `<op>.json.committed` marker
   (`message_id` + `fingerprint` + `delivered_at`) is fsync'd **before** the `.json` is unlinked. The
   marker is the crash-recovery record until it is folded back into the snapshot and cleaned up.

**Startup scan + fold-back.** `main.rs` calls `queue::scan()` before serving traffic and, for any op
found with its `.committed` marker still present (a process died in the narrow window between fsyncing
`.committed` and unlinking `.json`), folds the result into the registry and removes both files
(`cleanup_recovered`). `scan()` walks `queue/` in filename order (== chronological + seq order, both
zero-padded), skipping unreadable/corrupt op files rather than losing the rest.

**Read-back reconciliation (the reason it's correct).** Discord's message-create has **no idempotency
key**, so the dangerous window is *after* a successful `POST` but *before* `.committed` is fsync'd — a
crash there would otherwise re-POST and **duplicate** the message on restart. Before re-POSTing any
uncommitted `NewMessage` op, `deliver_new_message` issues `GET
/channels/{id}/messages?limit=50` and **fingerprint-matches** each returned message's `embeds[0]`
against the op's rendered embed (exact JSON value compare). On a match it **adopts** that message's id
instead of posting; on no match it posts exactly once. This closes the post-POST/pre-`.committed`
window with zero duplicates. **Caveat (documented trade-off):** the read-back window is `N=50`; heavy
intervening traffic in the same channel between the crash and the restart can push the already-posted
message past position 50, in which case a duplicate is possible. `N` is sized against the pacing bucket
(managed egress is < ~5/5s per channel) so this is a bounded, accepted edge.

### Supervised flush (flush.rs)

A **single OS thread** is the only code that ever calls `DiscordApi` (the single-deliverer invariant);
HTTP workers only ever enqueue. Properties, all verified in code/tests:

- **Never holds the state lock across a network call.** Op data is read from the durable queue file
  (which already carries the target ids and the rendered embed); the I/O happens with no lock held; the
  lock is briefly re-taken only to fold the result back.
- **Panic + poison recovery.** `main.rs` wraps each tick in `catch_unwind`; a panic logs `[flush-panic]`
  and the loop restarts. Every `state.lock()` site uses `unwrap_or_else(|e| e.into_inner())`, so a
  panic that poisoned the mutex leaves it usable.
- **Liveness marker.** After every tick the thread touches `<state_dir>/flush.alive`'s mtime, which the
  health-watch reads to detect a hung/dead loop.
- **Debounce (edit-class only).** `EditSummary` ops for the same item are grouped and collapse to
  **one** PATCH once the group has been quiet for `RELAY_DEBOUNCE_SECS` (default **5s**) **or** has been
  open for `RELAY_DEBOUNCE_MAX_SECS` (default **20s**), whichever first; the latest embed wins.
  Per-channel overrides come from `RELAY_DEBOUNCE_SECS__<cid>`. All other opclasses are FIFO.
- **Shared per-channel token bucket (`ChannelBucket`).** One bucket per channel spans BOTH managed
  deliveries and the unmanaged verbatim-forward path. The pool is fixed at 5 tokens/window; managed
  traffic may draw only `RELAY_MANAGED_RATE.managed_tokens` (strictly **1..=4**, i.e. always `< 5`),
  reserving `5 - managed_tokens` of structural headroom. The unmanaged/critical path draws with
  **priority** — `take_critical` is accounting-only and never blocks or drops (the real Discord rate
  limit is still faithfully mirrored by the verbatim proxy, which is what actually paces critical
  egress). So the "reservation" is a structural cap on managed traffic, not an active gate on critical.
- **Retry.** `429` → wait `retry_after` (from Discord's body) then retry. `5xx`/transport → exponential
  backoff `1,2,4,…` capped at **60s**. An op older than `RELAY_DELIVERY_MAX_AGE_SECS` (default **600s**)
  is **buried** to `dead/` with a `[dead-letter]` journal line. `RELAY_QUEUE_CAP` (default **500**)
  pending ops → new ops bury immediately rather than growing the queue unbounded.
- **404 / 403 handling.** Edit `404` (summary deleted) → re-POST fresh and fold the new id back
  (`[recreate]`). ThreadCreate/ThreadPost `404` → clear/recreate the thread from the anchor; a missing
  anchor disables threading for the item. `403` → bury (or `thread_disabled`).

### TokenCache

The pass-through Clawhip bot token is captured from the `Authorization` header of **every** inbound
POST and held **in memory only** (`Arc<Mutex<Option<String>>>` in `http.rs`) — **never** serialized to
disk (queue op files and `state.json` both carry none, enforced by tests) and **never** logged
(`log_meta` is metadata-only). The flush thread reads it per delivery; with no token yet captured a
tick returns `Parked` and delivers nothing. The `heartbeat` kind is the deliberate
capture-token-then-drop primer: on a managed channel a `GJCEMBED1 kind=heartbeat` POST is acked `200`
with `{"id":"0","gjc_relay":"heartbeat"}`, logged `[heartbeat]`, and **never forwarded** to Discord.

### State directory (the durability surface)

`~/.gjc-relay/state/` (`RELAY_STATE_DIR`, default `~/.gjc-relay/state`):

| Entry | Role |
|---|---|
| `state.json` | v2 **fast-path cache** of the registry (`version:2`, live items + dedup ledger). Written atomically (tmp + fsync + rename); a corrupt or wrong-version file is quarantined to `state.json.corrupt-<epoch>` and replaced with a fresh empty state rather than crashing the relay. |
| `queue/` | The durable op files + their `.committed` markers. **This is the delivery source of truth.** |
| `dead/` | Buried ops (retry budget / max-age / capacity / 403). |
| `flush.alive` | Liveness marker touched every flush tick. |

**`state.json` is a CACHE, not the durability boundary.** Registry state (anchor ids, facets) can be
fully reconstructed by folding the committed queue markers back on startup; `state.json` only avoids
re-deriving from scratch. The persister thread writes it at most **once per second** when dirty and
prunes stale items (30-day TTL) / dedup fingerprints (7-day TTL) roughly hourly.

## Self-priming heartbeat

`relay-heartbeat.sh` + `gjc-relay-heartbeat.{service,timer}` (oneshot, **120s** cadence
`OnUnitActiveSec=120s`, kill switch `RELAY_HEARTBEAT_ENABLED`, default on both in the script and
`config.rs`). Because the `TokenCache` is populated only from real inbound traffic, a quiet period or a
fresh restart leaves it cold and the flush thread has nothing to authenticate with until the next real
notification. The heartbeat emits a synthetic `GJCEMBED1 kind=heartbeat` inbound through the **normal**
clawhip → relay path (unlike the direct-to-Discord alarm scripts) every ≤120s, so post-restart flush
stall is bounded to roughly one heartbeat interval. It carries the token through the existing
authenticated path only — **no new token store or bot identity** is introduced.

## Live services (the supervision stack)

The relay is in-path on every production Discord post, and clawhip's DLQ is an in-memory `Vec` with no
retry on transport errors. A permanently-down relay would mean **silent, permanent notification loss**.
The stack (all **user-scope** systemd, rendered from `gjc-fleet/systemd/` into `~/.config/systemd/user/`,
linger enabled, no `sudo`):

| Unit | Role |
|---|---|
| `gjc-relay.service` | `ExecStart=%h/.gjc-relay/gjc-relay`; `Restart=always`, `RestartSec=1`, `StartLimitIntervalSec=0` (never stop retrying); `OnFailure=gjc-relay-alert.service`. Hardening is namespace-free (`NoNewPrivileges`, `RestrictRealtime`, `LockPersonality`, `SystemCallArchitectures=native`, `RestrictNamespaces`, `MemoryDenyWriteExecute`) because a user manager needs unprivileged user namespaces for `ProtectSystem`/`ProtectHome`/`PrivateTmp`, which Ubuntu ≥24.04's AppArmor restriction makes a start-failure risk on this single point of failure. |
| `gjc-relay-heartbeat.{service,timer}` | **New (v2).** 120s self-priming token-cache heartbeat (above). |
| `gjc-relay-health-watch.{service,timer}` | **New (v2).** Every **2 min**, curls Discord **directly** (bypassing clawhip + relay, both of which may be stuck) into `#gjc-approvals` when EITHER (a) the oldest file in `state/queue/` is older than `RELAY_DELIVERY_MAX_AGE_SECS`, OR (b) `state/flush.alive` has been stale for > **90s**. **False-alarm-guarded:** an empty/missing `queue/` means nothing is stuck (a never fires); a `flush.alive` that never existed means the relay never completed a flush cycle (b never fires) — only a marker that *was* written and is now stale trips (b). Re-alerts every 2 min while stuck (the timer cadence is the dedup). |
| `gjc-dlq-watch.service` | Follows **both** `clawhip.service` **and** `gjc-relay.service` journals (`journalctl --user -u clawhip -u gjc-relay -f`) and fires a direct-to-Discord alarm into `#gjc-approvals` on `clawhip dlq bury:` (clawhip side) OR `gjc-relay [dead-letter]` (relay side). 300s cooldown. Bot token read from `clawhip.env`, never printed. |
| `clawhip.service.d/10-gjc-relay.conf` | Ordering drop-in: clawhip starts `After=`/`Wants=` the relay. |
| `gjc-relay-alert.service` | Oneshot `OnFailure` target. **Rarely fires by design** — `Restart=always` + `StartLimitIntervalSec=0` means the relay can never reach the `failed` state; the *operative* alarms for real loss are `gjc-dlq-watch` and `gjc-relay-health-watch`. |

## `RELAY_MANAGED_RATE` presets

`config.rs` parses `RELAY_MANAGED_RATE` as a named preset **or** an explicit `<tokens>/<window>s` form;
tokens must be **1..=4**, window ≥ 1s, else the binary panics at startup (rejects bad config even if
`render.sh` missed it). Presets:

| Preset (aliases) | managed_tokens / window | Reserved critical share |
|---|---|---|
| `low` (`conservative`) | 2 / 5s | 3 |
| `medium` (`balanced`) — **default** | 3 / 5s | 2 |
| `high` (`throughput`) | 4 / 5s | 1 |
| explicit | `<t>/<w>s`, e.g. `2/10s` | `5 - t` |

## Greppable log labels

`log_meta` prints `gjc-relay [<label>] <msg>` on stdout (→ journal). The **actual** labels emitted by
the v2 code (verified by grepping `src/`) are:

```
startup  transform  proxy  force429  managed-accept  managed-panic
post  edit  thread  recover  recreate  dedup-drop  drop
heartbeat  queue-full  queue-error  queue-scan  upstream-error
dead-letter  fault-inject  flush-panic  flush-error
```

`[transform]` (with `kind=…`) is the v1 rewrite line; `[proxy]` is a verbatim forward; `[managed-accept]`
is the v2 absorb line. Flush-time delivery emits one line per event: `[post]` (new summary), `[edit]`
(summary PATCH), `[thread]` (thread create/post), `[recover]` (read-back adopted an already-POSTed
message on replay — the zero-duplicate proof), `[recreate]` (404-driven re-POST). Suppression is
`[dedup-drop]` (replay) / `[drop]` (unknown-item CI flood); `[dead-letter]` is a burial; `[fault-inject]`
is the C1 drill; `[flush-panic]` is a recovered tick. Every delivery line carries only the work-item key
+ message/thread id — never a token or body.

## Runbooks (operator-facing)

### Reboot-replay (durable queue survives a restart)

With a managed channel opted in and a CI run in flight, restart clawhip (or the host). Expectation: the
journal shows only `[edit]` and `[dedup-drop]` lines for the in-flight
`github.ci-*` events, **zero** new standalone CI messages, and no duplicate summary — the durable queue
replays the pending op rather than re-emitting from scratch.

### Crash-window drill (C1 — proving read-back reconciliation live)

`RELAY_FAULT_AFTER_POST=<lab-cid>` is a **gated diagnostic** (default empty = inert; modelled on
`RELAY_FORCE_429`). When set, `deliver_new_message` calls `std::process::abort()` **immediately after a
successful `POST` but before `.committed` is written** — exactly the post-POST/pre-commit crash window —
for the listed channel only (`NewMessage`-class only), zero blast radius elsewhere. Drill:

1. Set `RELAY_FAULT_AFTER_POST=<#gjc-lab cid>`, restart the relay.
2. Drive a new-message-class op into `#gjc-lab` (e.g. a canary `github.issue-opened`).
3. The relay POSTs the message, journals `[fault-inject] aborting after POST`, and aborts.
4. systemd restarts it; the same op is still `pending`, the flush loop re-derives it, the read-back
   `GET …?limit=50` **finds the already-posted message and adopts its id** — **zero duplicate**.

Caveat: the read-back window is `N=50` (see the reconciliation note above).

## As-built notes

- **Delivery labels match the plan.** `[post] [edit] [thread] [recover] [recreate]` (deliveries),
  `[dedup-drop]` / `[drop]` (suppression), and `[dead-letter]` (burial) are all emitted — `main.rs`
  consumes the flush `Vec<FlushEvent>` each tick via `flush::log_events`. `[managed-accept]` is the
  absorb line. See [Greppable log labels](#greppable-log-labels).
- **`GJC_LAB_CHANNEL` is rendered** by `render/render.sh` into `relay.env`, so the heartbeat is live;
  `relay-heartbeat.sh` keeps an empty-value graceful no-op guard for hosts where the channel is unset.

## Accepted trade-offs

- **In-memory token residency.** Capturing the pass-through bearer widens its residency from
  per-request to process-lifetime. Bounded and mitigated: memory-only, never on disk, never logged; the
  heartbeat keeps it warm rather than persisting it.
- **`SIGTERM` → `state.json` flush is NOT wired.** `Persister::flush_now` exists but `main.rs`
  deliberately does not install a signal handler (no signal-handling crate is a relay dependency
  today). Because durability lives in the **queue** (persist-before-ack), not in `state.json`, the only
  loss on an abrupt stop is up to ~1s of *cache* staleness (the persister's own period) — re-derived
  from the committed markers on restart.
- **Read-back window `N=50`.** Heavy intervening same-channel traffic between a crash and restart can
  push an already-posted message past position 50, allowing a duplicate. Sized against the managed
  pacing bucket (< ~5/5s per channel); documented rather than engineered away.

## How it connects to the rest of the system

- **clawhip → relay → Discord** is the fleet's entire embed path; see [00-overview.md](00-overview.md).
- The **design system** is shared: relay templates (clawhip side) and `discord_embed()`
  (gjc-bot side) both resolve styling from `~/.gjc-relay/design-system.json`.
- The v2 work-item narration path is walked end-to-end in
  [60-data-flow-and-integration.md](60-data-flow-and-integration.md); the new state surfaces are
  inventoried in [50-configuration-and-state.md](50-configuration-and-state.md).

## Open questions

- Is v2 (`RELAY_WORKITEM_CHANNELS` non-empty) enabled on any **production** channel yet, or is it
  shipped-but-gated pending soak? The rendered default is empty (byte-identical v1); no explicit
  decision of record was found.
- Should successful managed deliveries be logged? Today post/edit/thread are silent, which makes the
  journal quiet but also makes "did it deliver?" answerable only via Discord or the queue depth.

## Changelog

- 2026-07-09 (v2-current-state rewrite) — Doc set rebaselined to current state; prior history in git.
  This page: relay size refreshed to ~6.3k lines (12 modules); design-system kind count refreshed to
  36 (35 event kinds + `default`), covering the 5 new kinds `automerge`/`automerge.escalation`/
  `hermes-update`/`fleet-update`/`review.backlog`.
