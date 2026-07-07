# gjc-relay

Loopback reverse proxy between [clawhip](https://github.com/Yeachan-Heo/clawhip) and the
Discord REST API, part of the gjc fleet. clawhip can only post plain
`{"content": "<string>"}` messages; the relay intercepts its outbound
`POST /channels/{id}/messages` traffic (via `CLAWHIP_DISCORD_API_BASE` pointing at
`127.0.0.1:25295`) and rewrites messages carrying the `GJCEMBED1` envelope into styled
Discord **embeds**, resolved from `design-system.json`. Everything else — including
Discord's exact status codes, 429s included — is proxied verbatim to `https://discord.com`,
so clawhip's rate-limit backoff keeps working. Zero source changes to clawhip.

Single-file Rust crate (`src/main.rs`, deps: `tiny_http`, `ureq`, `serde_json`,
`chrono`/`chrono-tz`). Full architecture documentation lives in the
`gjc-architecture` repo (`35-gjc-relay.md`).

## Layout

| Path | Role |
|---|---|
| `src/main.rs`, `Cargo.toml`, `Cargo.lock` | The crate (includes the unit tests) |
| `runtime/design-system.json` | Embed styling source of truth: `kind` → color/emoji/title. Also read by gjc-bot-scripts' `lib/discord-embed.sh` |
| `runtime/dlq-watch.sh` | Out-of-band DLQ-bury alarm (run by `gjc-dlq-watch.service`) |
| `runtime/alert.sh` | `OnFailure` alarm for the relay itself (`gjc-relay-alert.service`) |
| `runtime/check-kind-coverage.sh` | Deploy-time gate: every emitted `kind` must exist in `design-system.json` |

## Repo vs. runtime home

This repo is the **source of truth for the source**. The **deployed, live copies** in
`~/.gjc-relay/` (binary, `relay.env`, `design-system.json`, the `runtime/` scripts) are
**canonical at runtime** — services read from there, never from this checkout. Two
deliberate differences in the committed copies:

- `runtime/dlq-watch.sh` / `runtime/alert.sh` ship with an **empty**
  `GJC_ALERT_CHANNEL` default. Numeric Discord channel IDs are never committed; the
  deployed copies in `~/.gjc-relay/` carry the host-local default.
- `relay.env` is not committed at all (it holds no token by design — the bot token
  arrives per-request in the forwarded `Authorization` header — but env files stay out
  of git regardless).

## Build & deploy

```sh
cargo test               # unit tests (17)
cargo build --release    # profile: opt-level=z, LTO, stripped (~1.8 MB static binary)
cp target/release/gjc-relay ~/.gjc-relay/gjc-relay
sudo systemctl restart gjc-relay.service
```

The relay is **in-path for every fleet Discord notification** (clawhip DLQ-buries on
transport failure, with no retry), so keep the restart window short and check
`journalctl -u gjc-relay -n 20` plus `gjc-dlq-watch.service` afterwards. The systemd
unit (`ExecStart=%h/.gjc-relay/gjc-relay`) needs no change on redeploy.
