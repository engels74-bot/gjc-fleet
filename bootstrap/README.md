# bootstrap/

One-screen map of the gjc-fleet bootstrap tooling. Every script is idempotent
(check → do-if-missing → report) and safe to re-run; each is runnable
standalone (`bash bootstrap/NN-foo.sh`) or in sequence via `bootstrap.sh`.

| Script | Role |
|---|---|
| `bootstrap.sh` | Orchestrator: runs `00` → `50` in order, stops at the first failure with a pointer to the failing step, suggests `verify.sh` at the end. |
| `00-prereqs.sh` | CHECK-ONLY. Reports presence/version of git, gh, jq, curl, tmux, rustc+cargo, bun, python3 (>= 3.11), uv. Never installs system packages. |
| `10-engines.sh` | Installs/upgrades the pinned upstream engines (clawhip, gajae-code, hermes-agent) from `fleet.toml`'s `[pins]`. Skips whatever already matches its pin. |
| `20-identity.sh` | Interactive checklist: `gh auth status`, the `github.com-<bot_login>` ssh alias, the `~/.gitconfig` `includeIf` block (offers to generate the satellite file, never edits `~/.gitconfig`), and an `ssh -T` handshake. Creates nothing on GitHub/Discord. |
| `30-config-homes.sh` | Creates the `~/.clawhip` `~/.hermes` `~/.gjc-bot` `~/.gjc-relay` `~/.gjc` homes, then runs `render.sh render` + `render.sh apply --yes`. |
| `40-secrets.sh` | Presence-by-NAME audit of `~/.hermes/.env` and `~/.clawhip/clawhip.env`. Never reads or prints a secret value. |
| `50-units.sh` | Builds gjc-relay, deploys its runtime scripts, installs the systemd user units (`render.sh apply --units --yes`), enables `linger`, and brings the daemons up in dependency order (relay → healthz gate → clawhip → dlq-watch → timers/path → hermes gateway install). |
| `verify.sh` | The standing health harness — run after bootstrapping and after any live-host change. `--quick` skips the canary Discord emit. |

## `--check` mode

Every script except `verify.sh` accepts an optional `--check` argument.
`00-prereqs.sh` and `40-secrets.sh` are inherently check-only and treat it as
a no-op; the rest report what they *would* do (install, clone, create,
render, enable, start) without touching the host. `bootstrap.sh --check`
propagates `--check` to every step.

## Order

```
00-prereqs.sh  ->  10-engines.sh  ->  20-identity.sh  ->  30-config-homes.sh  ->  40-secrets.sh  ->  50-units.sh
```

`30-config-homes.sh` will stop and instruct you to copy `fleet.toml.example`
to `~/.config/gjc-fleet/fleet.toml` (and fill it in) if that file doesn't
exist yet — every later step depends on it.

## Narrative version

`docs/80-reproduction-guide.md` is the prose walk-through of this same
sequence, for anyone reproducing the setup by hand instead of running these
scripts.
