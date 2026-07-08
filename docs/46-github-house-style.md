<!--
status: draft            # draft | reviewed | verified
last_verified: 2026-07-08
sources:
  - ~/github/engels74-bot/gjc-fleet/pipeline/lib/github-md.sh (gmd_h3/gmd_fence/gmd_details/gmd_footer — the composition helpers this page is normative for)
  - ~/github/engels74-bot/gjc-fleet/pipeline/lib/gh-ci.sh (ci_state/ci_red_summary — advisory-gate CI classifier + <details> companion)
  - ~/github/engels74-bot/gjc-fleet/pipeline/review/merge-gate.sh (skeleton (c) producer — advisory merge-gate comment)
  - ~/github/engels74-bot/gjc-fleet/pipeline/run/gjc-run.sh (launcher() prompt — issue-fix PR-body producer, skeleton (a))
  - ~/github/engels74-bot/gjc-fleet/pipeline/review/ai-code-review-handler-original.md (review replies + fleet commits — skeletons (b), (d), (e))
maintainer_notes: >
  Edit this file in isolation. Keep headings stable; append to Changelog at the bottom.
  This page is NORMATIVE: it is the single canonical style every fleet-authored GitHub artifact
  (PR body, review reply, advisory comment, escalation comment, audit comment, commit) follows.
  When you change a rule here, chase the producers listed in `sources:` above so they still conform —
  the skeletons below are the contract those producers implement, not decoration. The leakage rule
  (no infrastructure/session noise) is the load-bearing one: it is what keeps internal state out of
  public GitHub history. The `augment review` trigger string is the ONE deliberate exemption.
-->

# GitHub House Style — fleet-authored artifacts

Every GitHub-bound artifact the gjc-bot fleet emits — pull-request bodies, review replies, advisory
comments, escalation comments, audit comments, and commits — follows the rules on this page. It is
the canonical style. Producers do not each invent their own formatting: they compose through the
`pipeline/lib/github-md.sh` helpers (`gmd_h3` / `gmd_fence` / `gmd_details` / `gmd_footer`) or embed
the golden skeletons below verbatim, so a reader sees one consistent voice across the whole pipeline
(issue → gjc run → PR → review → merge gate → human merge).

Two audiences read every artifact: the human maintainer deciding whether to merge, and the next
automated stage parsing it. The rules serve both — human-legible prose, machine-stable structure,
and zero internal noise that would leak operational state into permanent public history.

## Global rules

1. **ATX headings only.** Use `#`/`##`/`###` — never Setext underlines (`===`, `---` under text).
   A bare `---` on its own line is a horizontal rule (used only above a footer), never a heading.
2. **Heading level is owned by artifact type.** A **PR body** owns the top-level `##` for its own
   sections (`## Summary`, `## Validation`). A **comment** (review reply, advisory, escalation,
   audit) starts at `###` — it lives inside a thread that already has document-level context, so it
   must not open an `h1`/`h2`. Never skip levels.
3. **Validation checklists are task lists.** Anything the reader should be able to tick off — the
   commands run, the checks that passed — uses GitHub task-list syntax (`- [ ]` / `- [x]`), not
   bare bullets. Checked boxes mean "done and observed", not "intended".
4. **Fenced code blocks are always language-tagged.** Every fence carries an info string:
   ` ```bash `, ` ```diff `, ` ```text `, ` ```json `. An untagged fence is a defect. Compose them
   with `gmd_fence <lang> <content>` so the tag is never forgotten.
5. **Long or bulky content collapses.** Any block longer than **15 lines OR larger than 1000 bytes**
   goes inside a `<details><summary>…</summary>` block (compose with `gmd_details`, which enforces
   both caps and appends a truncation note when it trips). Short, load-bearing content stays inline.
6. **Exactly one attribution footer per top-level artifact.** A PR body, an advisory comment, an
   escalation comment, and an audit comment each carry **exactly one** footer — emitted by
   `gmd_footer <stage> [trigger_url]`, or the literal below for producers that cannot source the
   helper. One, never zero, never two.
7. **No footers on threaded replies.** A verdict-first review reply posted `in_reply_to` a review
   comment carries **no** footer. It is already attributed by the thread and the bot identity;
   a footer on every reply is noise. Footers belong only on top-level artifacts (rule 6).
8. **Zero infrastructure / session noise.** GitHub text is permanent and public. It MUST NOT contain
   any of: session names (`gjc-<repo>-issue<N>`), lock or spool paths (`*.lock`, `~/.gjc-bot/…`,
   spool files), filesystem paths under `~`/`/home`, worktree paths, internal tokens or secrets,
   numeric internal IDs (run ids, PID stamps), or BLOCKED-state / single-flight / flock jargon. If a
   check failed, name the *check* and its *conclusion* (from `ci_red_summary`), never the machine or
   path that ran it. This is enforced by construction in `github-md.sh` (the helpers only format the
   caller's argument text and read no environment) — the producer's job is to never PASS such values.

## The standard footer

The one canonical footer literal, emitted by `gmd_footer` and reproduced verbatim by producers that
compose their PR body outside the shell helpers (e.g. the gjc coding agent writing its own PR):

```text
---
<sub>🤖 gjc fleet · issue-fix</sub>
```

`gmd_footer <stage> [url]` swaps `issue-fix` for the emitting stage (`issue-fix`, `merge-gate`,
`ci-fix`, `policy`) and, when a trigger URL is supplied, renders the stage as
`… · <a href="URL">trigger</a>`. The leading `---` horizontal rule and the single `<sub>` line are
fixed. There is one footer per artifact and it is the last thing in the artifact.

## Golden skeletons

These are the contract. A producer either composes byte-equivalent output through the helpers, or
embeds the matching skeleton. Fill the `<…>` placeholders; keep the structure.

### (a) Issue-fix PR body

Produced by the gjc coding agent (`pipeline/run/gjc-run.sh` launcher prompt). Top-level `##`
sections; `Fixes #N` closes the issue; validation is a task list; exactly one footer.

````markdown
## Summary

<one or two sentences: what was broken and the minimal change that fixes it>

Fixes #<issue-number>

## Changes

- `<path/to/file>`: <what changed and why>
- `<path/to/other>`: <what changed and why>

## Validation

- [x] `<exact command run, e.g. cargo test>` — <passed / N passed>
- [x] `<exact command run, e.g. cargo clippy -- -D warnings>` — clean
- [ ] <anything intentionally not run, with a one-line reason>

---
<sub>🤖 gjc fleet · issue-fix</sub>
````

### (b) Verdict-first review reply

Posted `in_reply_to` an augmentcode[bot] review comment (`ai-code-review-handler-original.md`
Phase 6). The **verdict is the first token** so a scanning human and the loop-termination logic both
read it instantly. No heading, no footer — it is a threaded reply.

````markdown
**Valid.** <the bug, one sentence>. Fixed by <the change>.
````

The three canonical shapes, verdict-first every time:

````markdown
**Valid.** <bug>. Fixed by <fix>.

**Valid — implementation differs.** <bug>. Fixed as <what you did> rather than the suggestion because <why>.

**Not an issue.** <why the claim does not hold>.
````

### (c) Merge-gate advisory comment

Posted by `pipeline/review/merge-gate.sh` on a CI-green bot PR. A `###` heading, the verdict inline,
an explicit "advisory only" disclaimer, failing-check detail (if any) collapsed via `gmd_details`,
and exactly one footer. Composed through `gmd_h3` / `gmd_details` / `gmd_footer`.

````markdown
### Advisory merge gate — CI green

**MERGE_READY** — <short reason the diff looks safe to merge>

_Advisory only — no formal review, no auto-merge; a human decides._

---
<sub>🤖 gjc fleet · merge-gate</sub>
````

The `REQUEST_CHANGES` form is identical with the verdict swapped and, when CI detail is worth
surfacing, a collapsed block from `ci_red_summary`:

````markdown
### Advisory merge gate — CI green

**REQUEST_CHANGES** — <short reason a human should look closer>

<details><summary>Details</summary>

```
- <check name>: <conclusion>
```
</details>

_Advisory only — no formal review, no auto-merge; a human decides._

---
<sub>🤖 gjc fleet · merge-gate</sub>
````

### (d) CI-fix escalation comment

Posted when automated CI repair could not fully fix a red build and a human should look. A `###`
heading, a plain statement of what is red and what was attempted, failing-check names collapsed, and
one footer. Names checks and conclusions only — never run ids, log paths, or the machine.

````markdown
### CI still red after automated fix attempt

Fixed <what was fixed, or "nothing fixable was found">. The following checks are still failing and
need a human:

<details><summary>Failing checks</summary>

```
- <check name>: <conclusion>
- <check name>: <conclusion>
```
</details>

<one sentence: likely category — pre-existing / flaky / needs-human>

---
<sub>🤖 gjc fleet · ci-fix</sub>
````

### (e) Policy-dismissal audit comment

Posted when the fleet declines to act on a claim (rejected review suggestion, out-of-policy request)
and wants an auditable record. A `###` heading, the claim restated neutrally, the reason it was
declined, and one footer. Neutral, cites policy, no internal jargon.

````markdown
### Declined — out of policy

**Claim:** <the suggestion or request, restated in one neutral sentence>

**Decision:** Not actioned. <the policy or code reason it does not hold, citing the guideline line
or code line that backs the call>.

This is recorded for audit; no change was made.

---
<sub>🤖 gjc fleet · policy</sub>
````

## Conventional Commit rules

Fleet-authored commits (the gjc coding agent's fix commit, the review handler's
`fix: address code review comments …`, the CI fixer's `fix: resolve CI failures …`) follow
[Conventional Commits](https://www.conventionalcommits.org):

- **Subject:** `type(scope): subject` — `type` ∈ `feat|fix|docs|style|refactor|perf|test|build|ci|chore`;
  `scope` optional but preferred (the affected module); `subject` imperative mood, lower-case, no
  trailing period, ≤ 72 chars.
- **Body:** optional, blank line after the subject; one bullet per accepted change (`- <change>`);
  wrap at ~72 columns; explain *why*, not *what the diff already shows*.
- **Footer:** optional; `Fixes #<n>` / `Refs #<n>` for issue linkage; `BREAKING CHANGE: …` when the
  change is incompatible. The commit footer is issue/breaking metadata — it is **not** the artifact
  attribution footer (that belongs only to the GitHub-facing body, per Global rule 6).
- **Same leakage rule.** Commit messages are permanent public history: no session names, lock/spool
  paths, `~`/`/home` paths, tokens, or internal ids. Rule 8 applies to commits exactly as to
  comments.

Example:

```text
fix(auth): reject tokens with a future issued-at claim

- clamp iat comparison to now so a skewed clock cannot backdate a token
- add a regression test covering the 30s leeway boundary

Fixes #142
```

## Exemption

The literal trigger string **`augment review`** is exempt from every prose rule on this page. It is
a machine trigger consumed by augmentcode[bot], not human-facing prose — it must be posted as the
exact bare string (`^augment review$`), with no heading, no footer, no formatting, no decoration.
This is the only exemption; everything else GitHub-bound conforms to the rules above.

## Open questions

- Should `gmd_footer`'s stage vocabulary (`issue-fix` / `merge-gate` / `ci-fix` / `policy`) be
  frozen as an enum somewhere machine-checkable, so a producer cannot silently coin a new stage
  label that drifts from this page?
- The 15-line / 1000-byte `<details>` threshold (Global rule 5) is currently a `gmd_details`
  default overridable per-call; should it be a hard project constant instead, to keep every
  artifact's collapse behaviour identical regardless of caller overrides?
- Is a lightweight CI lint worth adding — grep every fleet-emitted artifact (or the composition
  code paths) for the Global-rule-8 forbidden-token set before it can reach GitHub — rather than
  relying on the by-construction guarantee plus reviewer vigilance?

## Changelog

- 2026-07-08 — Initial draft. Establishes the normative GitHub house style for all fleet-authored
  artifacts: global rules (ATX headings, heading-level ownership, task-list checklists,
  language-tagged fences, `<details>` cap, one-footer/no-footer-on-replies, zero infra noise), the
  standard footer literal, five golden skeletons (issue-fix PR body, verdict-first review reply,
  merge-gate advisory, CI-fix escalation, policy-dismissal audit), Conventional Commit rules for
  fleet commits, and the single `augment review` machine-trigger exemption. Created alongside the
  Phase B-0 `github-md.sh` / `gh-ci.sh` helpers this page is normative for.
