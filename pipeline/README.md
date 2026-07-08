# gjc-bot-scripts

Host-side automation scripts for the **gjc** GitHub-issue → agent pipeline
(Phase G). These are timer- and event-driven Bash scripts that watch for issues
and pull requests, dispatch agent runs in isolated worktrees, run advisory
review/merge gates, and report status to Discord via `gjc-relay`.

## Layout

Scripts are grouped by their role in the issue → run → review pipeline. Each
script resolves its own repo root at runtime (via `${BASH_SOURCE[0]}`), so the
folders can be relocated or symlinked without editing paths; the
`GJC_BOT_SCRIPTS` env var still overrides the root when needed.

| Path | Purpose |
| --- | --- |
| `intake/issue-spool-adapter.sh` | Reads the clawhip issue spool, dedups via a ledger, triages, and dispatches a `run/gjc-run.sh launch`. |
| `intake/issue-triage-fetch.sh` | Read-only fetch of recent open issues for the weekly triage job. |
| `run/gjc-run.sh` | Single execution entrypoint for a gjc run (print-mode + a unique per-run worktree). |
| `run/gjc-reap.sh` | Kills a hung/stale gjc session and its full pane process tree. |
| `review/review-detector.sh` | Zero-LLM poller. Routes by PR author: bot PRs → the review handler; automated-author PRs (renovate/dependabot) → the B-2 one-review policy lane. |
| `review/review-run.sh` | Launcher for the AI Code Review Handler, run through the fleet coding engine (`lib/engine.sh`: gjc default, legacy claude). |
| `review/review-policy-decide.sh` | Zero-checkout brain decision (APPLY/DISMISS/ESCALATE) for a later review on an already-consumed automated-author PR. |
| `review/review-checkout.sh` | Shared isolated per-repo review-checkout helper (`ensure_checkout`); sourced by `ci-fixer-run.sh`. |
| `review/merge-gate.sh` | Advisory, non-blocking merge gate that reviews green bot PRs (shares `lib/gh-ci.sh` + `lib/github-md.sh`). |
| `review/ci-fixer.sh` | Fix-until-green poller (B-3, **default OFF**): launches a bounded CI-fix run for CI-RED bot PRs; caps + backoff + give-up. |
| `review/ci-fixer-run.sh` | Fire-and-forget launcher for one bounded CI-fix run; classifies the outcome in-shell via `git ls-remote`. |
| `review/ai-code-review-handler-original.md` | The unmodified handler prompt template `review-run.sh` fills in at runtime. |
| `review/ci-fix-handler.md` | The CI-fix handler prompt template `ci-fixer-run.sh` fills in (one-shot, minimal fix, one commit, no PR comments). |
| `review/tests/` | Offline guardrail proofs (`policy-deferred-mark`, `ci-fixer-caps-backoff`) — no network, no live PR. |
| `maintenance/gjc-worktree-janitor.sh` | Crash-net that cleans up orphaned launch worktrees. |
| `maintenance/stale-branches.sh` | Report-only nightly scan for old merged bot branches (never deletes). |
| `lib/discord-embed.sh` | Shared `GJCEMBED1` envelope emitter used by the scripts. |
| `lib/engine.sh` | Coding-engine dispatch (`engine_run gjc|claude`) shared by the review + CI-fix launchers. |
| `lib/gh-ci.sh` | Shared CI-state classifier (`ci_state`/`ci_red_summary`) used by merge-gate + ci-fixer. |
| `lib/ledger.sh` | Shared append-only JSONL ledger helpers (dedup/caps/backoff), per-file locking. |
| `lib/github-md.sh` | House-style GitHub-Flavored-Markdown composition helpers (`docs/46-github-house-style.md`). |
| `systemd/` | `.service` / `.timer` / `.path` unit templates (now at the `gjc-fleet` repo root, rendered by `render/render.sh`). |

Each script's own header comment is the authoritative description of its
behaviour and phase.

## Secrets

No credentials live in this repository. Every script sources its tokens
(`GITHUB_TOKEN`, `NANOGPT_API_KEY`, …) from `~/.hermes/.env` at runtime. Never
hardcode or commit a secret — the `gitleaks` and `detect-private-key` pre-commit
hooks enforce this.

## Deployment

Since the 2026-07-07 monorepo migration this pipeline is the `pipeline/` subdirectory
of the `engels74-bot/gjc-fleet` monorepo, and the unit **templates** live at the
`gjc-fleet` repo **root** `systemd/` (shared with clawhip + relay). The units are
**rendered from `fleet.toml`** by `render/render.sh` (their `ExecStart=` resolves to
`$FLEET_REPO/pipeline/<stage>/<script>.sh`) and installed to `~/.config/systemd/user/`
(**user-scope, no `sudo`**) via `render/render.sh apply --units`, then
`systemctl --user daemon-reload`. Numeric Discord channel IDs and the B-2/B-3 knobs
reach the units through the rendered, 0600 `~/.gjc-bot/gjc-bot.env`
(`EnvironmentFile=-`), never the repo. Each script still self-locates its own root, so
the checkout can be relocated without editing paths.

## Development

This repo uses [prek](https://prek.j178.dev/) for pre-commit quality gates
(builtin hygiene hooks, Conventional Commits, gitleaks, and ShellCheck):

```sh
prek install -t pre-commit -t commit-msg   # activate the git hooks
prek run --all-files                        # lint the whole tree
```
