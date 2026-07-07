<!--
status: draft            # draft | reviewed | verified
last_verified: 2026-07-07
sources:
  - ~/github/engels74-bot/gjc-fleet/fleet.toml.example
  - ~/github/engels74-bot/gjc-fleet/render/render.sh
  - ~/.gitconfig, ~/.gitconfig-engels74-bot, ~/.ssh/config (pattern only — no values reproduced)
  - the deployment's own accounts/secrets, referenced by ROLE ONLY, never by value
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  This page is written for an OUTSIDE reader forking gjc-fleet for their own accounts —
  it deliberately uses fleet.toml.example's generic names (example-owner, example-repo, …)
  rather than this deployment's real identities. NEVER add secret values or numeric
  Discord IDs here, even as "example" values — use placeholders only.
  bootstrap/ (00-prereqs.sh through 50-units.sh + verify.sh, orchestrated by bootstrap.sh)
  is the authoritative, scripted version of this same walkthrough — see bootstrap/README.md.
  This page is the prose companion for readers who want to understand or do each step
  by hand; keep the two in sync when either changes.
-->

# Reproduction guide — standing up your own fleet

> A "stand up your own fleet" path for someone forking `gjc-fleet` for their own GitHub account and
> Discord server. No Docker — this fleet runs natively on a Linux host as a regular user. For what
> each piece *is* once running, start at [00-overview.md](00-overview.md); for the config surface
> referenced throughout, see [45-fleet-config.md](45-fleet-config.md). Index: [README.md](README.md).

This is a from-scratch walkthrough, roughly in dependency order. Every account, token, and channel
below is described **by role**, never by value — you'll be creating your own. Steps (b)–(h) below
are also automated by the `bootstrap/` script set at the repo root
(`00-prereqs.sh` → `10-engines.sh` → `20-identity.sh` → `30-config-homes.sh` → `40-secrets.sh` →
`50-units.sh`, run in order by `bootstrap.sh`, every step idempotent and safe to re-run, every step
except `verify.sh` supporting a `--check` dry-run mode); this page walks through the same sequence
by hand, for understanding or for the parts (a) that genuinely can't be scripted.

## (a) Accounts to create manually

Nothing here is automatable from a script running as the accounts don't exist yet:

1. **A dedicated bot GitHub account** (distinct from your own) — this becomes the identity that
   authors every automated commit/PR/comment. Invite it as a **Write collaborator** on each repo
   you want the fleet to manage.
2. **A Discord server** (or a channel category in an existing one) to host the fleet's notifications
   and conversation. You'll want at minimum: one channel per monitored repo, a shared events
   channel, an approvals channel, a conversational "brain" channel, and a low-stakes lab/canary
   channel for drills.
3. **Two separate Discord bot applications** (via the Discord Developer Portal), each invited to
   your server with permission to post/read in the channels above:
   - One is the **notifier** identity — posts everything the event router (clawhip) and the
     pipeline emit. It never receives input; it only ever posts.
   - One is the **conversational** identity — the one you actually talk to, drives the coding
     agent on your behalf, and never touches the notifier's message path.
4. **Tokens by role**, generated once the accounts above exist (values go in step (f), never here):
   - Bot GitHub personal access token (repo scope) — used both as "the" GitHub token and,
     optionally, a second scoped token if you want the event router's GitHub polling on a
     separate credential from the pipeline's `gh` calls.
   - Notifier Discord bot token.
   - Conversational Discord bot token.
   - An API key for whatever OpenAI-compatible endpoint backs your cheap, no-tools triage/merge-gate
     model (this deployment uses a NanoGPT-compatible provider; any compatible endpoint works).
   - Credentials/OAuth for whatever coding-agent-grade model backs your conversational brain and
     the coding agent itself (this deployment uses an OAuth-based subscription; a plain API key
     works too, depending on what the upstream agents support).

## (b) Host prerequisites (`bootstrap/00-prereqs.sh`)

A single Linux host, one regular (non-root) user, no Docker. Install: `git`, `gh` (GitHub CLI,
authenticated — see (c)), `jq`, `tmux`, `curl`, a Rust toolchain (`rustup` recommended — clawhip and
gjc-relay both build with `cargo`), `bun` (gajae-code's runtime), `python3` (≥ 3.11) + `uv`
(hermes-agent's runtime and this repo's TOML tooling). Everything else the fleet needs (the three
upstream engines) gets installed in step (d), not here. `bootstrap/00-prereqs.sh` is check-only —
it reports what's present/missing and never installs a system package for you.

## (c) Identity wiring (`bootstrap/20-identity.sh`)

If the bot account is separate from your own GitHub identity, you need git and `gh` to pick the
right one *by directory*, without you having to remember to switch:

1. **An SSH host alias** for the bot identity, e.g. a `Host github.com-<bot>` block in
   `~/.ssh/config` pointing `HostName github.com` at a dedicated `IdentityFile`. Clone the bot's
   working repos using that alias as the remote host, not bare `github.com`.
2. **A `~/.gitconfig` `includeIf "gitdir:…"` block** scoped to wherever the bot's repos live
   (e.g. `~/github/<bot-account>/`), loading a satellite config
   (`~/.gitconfig-<bot>`) that sets `user.name`/`user.email` to the bot identity and — if you want
   `gh`-token-based HTTPS auth instead of the SSH alias for some remotes — a `credential.helper`
   that shells out to `gh auth token --user <bot-account>` rather than using your own logged-in
   account's token.
3. **`gh auth login`** for both accounts (by name — `gh auth login --hostname github.com`, then
   `gh auth switch`/multi-account as needed); the includeIf block above is what lets scripts and
   interactive shells resolve the right one automatically based on which directory they're in,
   rather than requiring an explicit `gh auth switch` before every bot-side operation.

`bootstrap/20-identity.sh` verifies all of this against `[operator]` in your `fleet.toml`
(`gh auth status` shows the bot login active, the `github.com-<bot_login>` ssh alias exists, an
`ssh -T` handshake succeeds) and will *offer* — with a y/N prompt — to generate the satellite
`~/.gitconfig-<bot_login>` file for you; it never edits `~/.gitconfig` itself, and it creates
nothing on GitHub or Discord. Run it after (a) and after filling in `[operator]` in (e).

## (d) Engine installs at `[pins]` (`bootstrap/10-engines.sh`)

`fleet.toml`'s `[pins]` table names the exact versions this deployment verified against; install
each via its own channel (see [00-overview.md](00-overview.md#where-each-component-lives-and-runs)
for why these are never vendored into the repo):

- **clawhip**: `cargo install clawhip --version <pin> --locked`
- **gajae-code**: `bun add -g gajae-code@<pin>`
- **hermes-agent**: `git checkout <pin>` of the upstream `hermes-agent` repo into a working
  directory, then follow its own venv/editable-install instructions

`bootstrap/10-engines.sh` does all three from your `fleet.toml`'s `[pins]` table and skips whatever
already matches its pin, so it's safe to re-run after a version bump.

## (e) `fleet.toml` (`bootstrap/30-config-homes.sh` stops here if it's missing)

Copy `fleet.toml.example` (in the repo root) to `~/.config/gjc-fleet/fleet.toml`, `chmod 600` it,
and fill in every section — your bot account/identity, your Discord channel-ID map (only obtainable
once the channels and bots from (a) exist — enable Developer Mode in Discord to copy channel IDs),
your `[[repos]]` blocks (one per repo you want monitored), and your `[pins]`. Full key-by-key
reference: [45-fleet-config.md](45-fleet-config.md#fleettoml-key-reference). This file **never
gets committed** — it's the one artifact in this whole walkthrough that's genuinely
host/deployment-specific and sensitive. `bootstrap/30-config-homes.sh` creates the `~/.clawhip`
`~/.hermes` `~/.gjc-bot` `~/.gjc-relay` `~/.gjc` runtime homes and then runs
`render.sh render && render.sh apply --yes` for you — but it refuses to proceed (with a pointer
back to this step) if `~/.config/gjc-fleet/fleet.toml` doesn't exist yet.

## (f) Secrets provisioning (`bootstrap/40-secrets.sh` audits, never fills in)

Populate the two env files `fleet.toml`'s `[secrets]` table points at (create them 0600; the
renderer never writes secret values into them for you — see
[45-fleet-config.md](45-fleet-config.md#secrets-custody-map-namesroles-only)):

- `~/.hermes/.env` — your bot GitHub PAT (as `GITHUB_TOKEN`), your triage-model API key
  (`NANOGPT_API_KEY` or equivalent), your conversational Discord bot token
  (`DISCORD_BOT_TOKEN`), and the numeric ID of your "brain" home channel
  (`DISCORD_HOME_CHANNEL`).
- `~/.clawhip/clawhip.env` — your (optionally separate) GitHub token for the event router
  (`CLAWHIP_GITHUB_TOKEN`), your notifier Discord bot token (`CLAWHIP_DISCORD_BOT_TOKEN`), and
  `CLAWHIP_DISCORD_API_BASE=http://127.0.0.1:25295/api/v10` (points clawhip at your own gjc-relay
  once it's running — see (g)/(h)).
- Whatever credential store your coding-agent-grade model needs (an OAuth login flow, or a plain
  API key in its own config) — follow gajae-code's own auth setup for this.

`bootstrap/40-secrets.sh` audits presence of every key above **by name only** — it never reads or
prints a value, and it never creates an env file for you (a placeholder secret file would be worse
than a missing one), so it only ever tells you what's still missing and which role needs it.

## (g) Render (`bootstrap/30-config-homes.sh`, folded into step (e) above)

From the `gjc-fleet` checkout:

```sh
render/render.sh render          # stage everything from your fleet.toml; touches nothing live
render/render.sh diff            # should show "no live file" for a first-time setup — expected
render/render.sh apply --units   # write the config files + install the systemd units
```

Full command reference: [45-fleet-config.md](45-fleet-config.md#renderer-command-reference).

## (h) Bring the units up, in order (`bootstrap/50-units.sh`)

The start order after units are installed matters — later units assume earlier ones are already
healthy. `bootstrap/50-units.sh` does the following, in this order, and is what you should actually
run:

1. Builds gjc-relay from `relay/` (`cargo test && cargo build --release`), deploys the binary plus
   its runtime scripts (`alert.sh`, `dlq-watch.sh`, `check-kind-coverage.sh`) to `~/.gjc-relay/`.
2. Enables linger for your user (`loginctl enable-linger`), so every unit below survives without a
   login session — falls back to printing the `sudo loginctl enable-linger` form if it can't reach
   a polkit/dbus session non-interactively.
3. Installs the rendered units (`render.sh apply --units --yes`) and runs
   `systemctl --user daemon-reload`.
4. `systemctl --user enable --now gjc-relay.service`, then polls
   `curl 127.0.0.1:25295/healthz` for up to 15 s — **aborting the whole script** if the relay
   never comes up healthy, since nothing downstream should start against a dead relay.
5. `systemctl --user enable --now clawhip.service`, then `gjc-dlq-watch.service`, then the four
   pipeline timers (`issue-spool-adapter.timer`, `review-detector.timer`, `merge-gate.timer`,
   `gjc-worktree-janitor.timer`) and the `issue-spool-adapter.path` unit.
6. `hermes gateway install` (regenerates `hermes-gateway.service` itself, in user scope) — skipped
   with a note if hermes-agent's venv isn't deployed yet at this point.

`gjc-relay-alert.service` needs no explicit `enable --now` — it's a oneshot `OnFailure` target that
only ever fires when triggered by `gjc-relay.service`'s own `OnFailure=`; installing the unit file
(step 3) is enough. Every script accepts `--check` for a dry run that reports what it would do
without touching the host; `bootstrap.sh --check` runs all of them that way in sequence.

`bootstrap/verify.sh` is the standing health harness — run it after bootstrapping and after any
live-host change. It checks linger, that the user systemd manager is reachable, that every
long-running unit is both enabled and active, that all four timers are scheduled and the path unit
is active, plus (unless run with `--quick`) the canary emit from step (i) below.

## (i) Canary verification

Once everything above is up, confirm the whole path end-to-end without touching any real repo or
issue:

```sh
clawhip emit gjc.canary --repo <any-name> --status ok --actor you --message "hello from a fresh fleet"
```

This should produce a styled embed in your lab channel within a couple of seconds. If it doesn't:
check `curl 127.0.0.1:25295/healthz` first (relay), then `journalctl --user -u clawhip -n 50`
(look for `clawhip dlq bury:` — a buried canary means the relay or your Discord token is the
problem), then `journalctl --user -u gjc-relay -n 50`. A clean canary is the same acceptance check
this deployment used after every relay redeploy (see
[35-gjc-relay.md](35-gjc-relay.md#build--deploy)) — it's worth keeping in your own muscle memory
for any future change to the relay or clawhip's Discord path. `bootstrap/verify.sh` runs this exact
check as its final step (`--quick` skips it, everything else still runs): it emits the canary,
then confirms a relay `[transform]` line appeared in the user journal within a few seconds with no
new DLQ-bury alongside it.

## Open questions

- Should this guide cover a multi-repo-owner scenario (bot account with Write access across repos
  owned by *different* humans), or is single-owner the only supported shape for now?
- No guidance yet on rotating the bootstrap secrets (PATs, bot tokens) after initial setup — worth
  a follow-up section once there's a deployment old enough to need it.
- `bootstrap/20-identity.sh` and `40-secrets.sh` both assume `fleet.toml` already exists (they read
  `[operator]`/`[secrets]` from it); should the guide state the (e)→(c)/(f) dependency more loudly,
  given the numeric `bootstrap/` script order runs `10-engines.sh` before `20-identity.sh` but this
  page's lettering runs identity (c) before engines (d)?

## Changelog

- 2026-07-07 — Initial draft (created by the monorepo migration). Cross-referenced against the
  `bootstrap/` script set (`00-prereqs.sh` … `50-units.sh`, `verify.sh`, `bootstrap.sh`), which
  landed in this same repo during the same migration: each lettered section now names the
  corresponding script, and step (h)'s unit start order and step (i)'s canary check were rewritten
  to match `50-units.sh`/`verify.sh` exactly rather than describing target behavior ahead of an
  implementation.
