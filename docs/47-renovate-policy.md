<!--
status: reviewed         # draft | reviewed | verified
last_verified: 2026-07-09
sources:
  - ~/github/engels74-bot/gjc-fleet/docs/40-gjc-bot-automation.md (automerge lane; fleet owns merging)
  - ~/github/engels74-bot/gjc-fleet/pipeline/review/automerge.sh (the merge owner)
  - engels74 org renovate.json across all non-fork repos (structure only — host-side, not vendored here)
maintainer_notes: >
  Canonical, org-wide renovate policy for the engels74 fleet, added when the fleet took ownership
  of merging (the bot-side automerge lane). It documents the single renovate.json block every
  non-fork engels74 repo carries, why each key is set, and the direct-push rollout + revert
  mechanics. Renovate OPENS and REBASES dependency PRs; the fleet (automerge.sh / merge-gate) is
  the merge authority — so renovate configs deliberately omit all automerge keys.
-->

> The fleet's single renovate policy: one `renovate.json` block shared across every non-fork
> engels74 repo, so PR volume, rebase behaviour, and the bot⇄renovate interaction are uniform and
> predictable. For how the fleet then MERGES those PRs, see
> [40-gjc-bot-automation.md](40-gjc-bot-automation.md) (automerge lane + advisory merge gate).
> Index: [README.md](README.md).

## Canonical `renovate.json`

Every non-fork engels74 repo carries this block. Repo-specific `customManagers` and `packageRules`
(grouping, custom datasources, etc.) are **preserved** alongside it — the fleet policy is merged
IN, never overwritten over a repo's own rules.

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended", "group:allNonMajor"],
  "gitIgnoredAuthors": [
    "41898282+github-actions[bot]@users.noreply.github.com",
    "300104067+engels74-bot@users.noreply.github.com"
  ],
  "rebaseWhen": "conflicted",
  "prConcurrentLimit": 10
}
```

## Why each key

| Key | Rationale |
|-----|-----------|
| `gitIgnoredAuthors` + the `engels74-bot` email | Renovate treats a PR branch as manually edited (and posts **"Edited/Blocked — will not rebase"**, then stops auto-rebasing) when a non-ignored author pushes to it. The fleet's automation commits as `engels74-bot`; listing that email here tells renovate to keep auto-rebasing after a bot fix-commit. The `github-actions[bot]` email is the upstream default and is kept. |
| `extends: group:allNonMajor` | Batches all non-major (minor + patch) updates into a single PR (`renovate/all-minor-patch`) instead of one PR per dependency — the **single biggest reducer of PR floods and rebase cascades**. Major updates stay separate (they warrant individual review). Repos with their own `packageRules` grouping keep those alongside. |
| `rebaseWhen: "conflicted"` | Renovate only force-pushes a branch on a true conflict or a new version — so a bot fix-commit on a PR survives in the common case (the force-push-resilience re-arm lane covers the loss case). |
| `prConcurrentLimit: 10` | Documents the volume cap explicitly (matches the recommended default) so a dependency spike can't open unbounded PRs. |
| *(no `automerge` / `platformAutomerge` keys)* | **The fleet owns merging**, not renovate: `pipeline/review/automerge.sh` merges eligible automated-author PRs (server-side head-pinned via `gh pr merge --match-head-commit`, policy- and CI-gated) and `merge-gate.sh` posts advisory verdicts on bot-authored PRs. Renovate-native automerge is deliberately omitted so there is one merge authority with one set of kill-switches and one observability surface. |

## Scope

All **non-fork, non-archived** engels74 repos (forks are excluded — a renovate config in a fork is
inert for us and only pollutes upstream PRs) — **33 repos at the 2026-07-09 rollout**. This includes the six fleet app repos; their bot
working clones under `~/github/engels74-bot/fleet/` pick the change up on their next fetch, so no
separate PR lane is needed.

## Rollout & revert mechanics

Direct-push (operator-authorized), not via PRs:

1. Clone missing repos into `~/github/engels74/` via the `git@github.com-engels74:` SSH alias
   (engels74 identity); sync existing clones to a clean default branch first.
2. Resolve each repo's **actual** default branch (several are not `main`: e.g. `master`, `release`,
   `workflows`) before recording SHAs or pushing.
3. Merge the canonical block into an existing `renovate.json` (preserving repo-specific
   `customManagers`/`packageRules`) or create the file; skip repos already compliant (idempotent).
4. Commit as `engels74-bot` with a Conventional-Commit message using `--no-verify` (small, policy-
   only change), then push directly to the default branch.

**Safety rails** (this is a wide production mutation): a **first-repo canary** (`zondarr`) is run
first — its diff reviewed and renovate confirmed to resume auto-rebase with no "Edited/Blocked" —
before the fleet-wide push; every subsequent repo's merged diff is captured to a per-repo log
(`~/.gjc-bot/renovate-rollout/diff-<repo>.txt`) before pushing (no blind overwrites); and each
repo's pre-change default-branch SHA is recorded in the audit TSV.

**Revert** any repo to its recorded pre-change SHA:

```bash
git -C ~/github/engels74/<repo> push --force-with-lease origin <pre_sha>:<default-branch>
```

## Changelog

- **2026-07-09** — New page. Canonical org-wide renovate policy documented when the fleet took over
  merging (automerge lane). Records the shared `renovate.json` block, per-key rationale, the
  all-non-fork-engels74 scope, and the canary-gated direct-push rollout + revert playbook.
