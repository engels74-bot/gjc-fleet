# gjc-fleet

The complete, reproducible home of the **gjc autonomous GitHub bot fleet**: GitHub issues on a
set of personal repos are triaged by a cheap LLM, fixed by a coding agent in isolated git
worktrees, reviewed, and advisory-gated for a human merge — with every step narrated to Discord
as styled embeds, and a conversational Discord "brain" on call.

This monorepo consolidates the fleet's locally-authored components (formerly the separate
`gjc-bot-scripts`, `gjc-relay`, and `gjc-architecture` repos — history preserved via merge).
The three upstream engines it orchestrates — [gajae-code](https://github.com/Yeachan-Heo/gajae-code),
[hermes-agent](https://github.com/NousResearch/hermes-agent),
[clawhip](https://github.com/Yeachan-Heo/clawhip) — are **never vendored here**; they install
at pinned versions through their own channels.

## The three-layer source-of-truth model

1. **This repo** — source of truth for code, systemd unit templates, config templates, and docs.
2. **`~/.config/gjc-fleet/fleet.toml`** — source of truth for host-local values (operator
   identity, target repos, Discord channel IDs, path overrides, upstream pins). Untracked,
   holds no tokens.
3. **The `~/.` runtime homes** (`~/.gjc-bot`, `~/.gjc-relay`, `~/.clawhip`, `~/.hermes`,
   `~/.gjc`) — rendered artifacts and state. `render/render.sh diff` verifies they match
   layers 1+2.

Secrets never enter layers 1 or 2: tokens live in `~/.hermes/.env` and `~/.clawhip/clawhip.env`
(referenced by name only), numeric Discord channel IDs only in `fleet.toml`.

## Layout

| Dir | Contents |
|---|---|
| `pipeline/` | The bot's shell automation: `intake/` → `run/` → `review/` + `maintenance/` + shared `lib/` |
| `relay/` | gjc-relay: loopback Rust proxy turning clawhip's plain Discord posts into styled embeds |
| `docs/` | Architecture documentation (start at `docs/00-overview.md`; reproduction guide in `docs/80-reproduction-guide.md`) |
| `systemd/` | User-scope unit templates for every fleet service/timer/path unit |
| `render/` | `fleet.toml` → live-config renderer (`render.sh render|diff|apply|check|doctor`) |
| `bootstrap/` | Fresh-host stand-up scripts + `verify.sh` health harness |

## Quick start

Read `docs/00-overview.md` (five minutes) to understand the system, then
`docs/80-reproduction-guide.md` to stand up your own. Development hooks:
`prek install -t pre-commit -t commit-msg`.
