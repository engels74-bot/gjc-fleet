# gjc-bot-scripts

Host-side automation scripts for the **gjc** GitHub-issue → agent pipeline
(Phase G). These are timer- and event-driven Bash scripts that watch for issues
and pull requests, dispatch agent runs in isolated worktrees, run advisory
review/merge gates, and report status to Discord via `gjc-relay`.

## Layout

Scripts are grouped by their role in the issue → run → review pipeline. Each
script resolves its own repo root at runtime (via `${BASH_SOURCE[0]}`), so the
folders can be relocated or symlinked without editing paths; the
`REPO_BOT_SCRIPTS` env var still overrides the root when needed.

| Path | Purpose |
| --- | --- |
| `intake/issue-spool-adapter.sh` | Reads the clawhip issue spool, dedups via a ledger, triages, and dispatches a `run/gjc-run.sh launch`. |
| `intake/issue-triage-fetch.sh` | Read-only fetch of recent open issues for the weekly triage job. |
| `run/gjc-run.sh` | Single execution entrypoint for a gjc run (print-mode + a unique per-run worktree). |
| `run/gjc-reap.sh` | Kills a hung/stale gjc session and its full pane process tree. |
| `review/review-detector.sh` | Zero-LLM poller that launches the review handler on new bot reviews. |
| `review/review-run.sh` | Launcher for the AI Code Review Handler (headless Claude Code). |
| `review/merge-gate.sh` | Advisory, non-blocking merge gate that reviews green bot PRs. |
| `review/ai-code-review-handler-original.md` | The unmodified handler prompt template `review-run.sh` fills in at runtime. |
| `maintenance/gjc-worktree-janitor.sh` | Crash-net that cleans up orphaned launch worktrees. |
| `maintenance/stale-branches.sh` | Report-only nightly scan for old merged bot branches (never deletes). |
| `lib/discord-embed.sh` | Shared `GJCEMBED1` envelope emitter used by the scripts. |
| `systemd/` | `.service` / `.timer` / `.path` units that drive the scripts on the host. |

Each script's own header comment is the authoritative description of its
behaviour and phase.

## Secrets

No credentials live in this repository. Every script sources its tokens
(`GITHUB_TOKEN`, `NANOGPT_API_KEY`, …) from `~/.hermes/.env` at runtime. Never
hardcode or commit a secret — the `gitleaks` and `detect-private-key` pre-commit
hooks enforce this.

## Deployment

The `systemd/` units reference the scripts by absolute path under
`/home/cvps/github/engels74-bot/gjc-bot-scripts/` (e.g.
`review/merge-gate.sh`). Install the units into `/etc/systemd/system/`, then
`sudo systemctl daemon-reload` and enable the relevant timers/paths. If you
relocate the checkout, update the `ExecStart=` lines to match (the scripts
themselves are location-independent).

## Development

This repo uses [prek](https://prek.j178.dev/) for pre-commit quality gates
(builtin hygiene hooks, Conventional Commits, gitleaks, and ShellCheck):

```sh
prek install -t pre-commit -t commit-msg   # activate the git hooks
prek run --all-files                        # lint the whole tree
```
