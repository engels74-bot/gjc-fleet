#!/usr/bin/env bash
# ci-fixer-authors.test.sh — Workstream E proof for ci-fixer.sh's author-scoping helper
# (is_ci_fixer_author). No network: the poller is sourced (CI_FIXER_NO_MAIN=1) and the pure
# membership helper is called directly per case. Mirrors review-detector.sh's
# is_automated_author() idiom (glob-safe, exact-token, comma/space accepted, "-" sentinel).
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$HERE/../ci-fixer.sh"

# gh stub: swallow every call, no network.
cat >"$TMP/gh-stub.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$TMP/gh-stub.sh"

# Isolate ALL state under $TMP; source the poller as a library.
export GJC_BOT_STATE="$TMP"
export CI_FIXER_LEDGER="$TMP/ci-fixer.jsonl"
export CI_FIXER_LOG="$TMP/ci-fixer.log"
export GH_BIN="$TMP/gh-stub.sh"
export GJC_BOT_GH_ROOT="$TMP/gh-root"          # empty -> list_bot_repos yields nothing
export CI_FIXER_REPOS="testrepo"               # main() is never called; avoids the scan anyway
export CI_FIXER_ENABLED="1"
export CI_FIXER_MAX_PER_SHA="2"
export CI_FIXER_MAX_PER_PR="5"
export CI_FIXER_BACKOFF_BASE_MINS="10"
export DRY_RUN="0"
export CI_FIXER_NO_MAIN="1"
mkdir -p "$GJC_BOT_GH_ROOT"

# shellcheck source=/dev/null
source "$POLLER"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "===== ci-fixer author-scoping assertions ====="

# ── default CI_FIXER_AUTHORS (bot + renovate[bot] + dependabot[bot]) ──────────────────────
is_ci_fixer_author "engels74-bot"    || fail "default: engels74-bot must be a member"
is_ci_fixer_author "renovate[bot]"   || fail "default: renovate[bot] must be a member"
is_ci_fixer_author "dependabot[bot]" || fail "default: dependabot[bot] must be a member"
if is_ci_fixer_author "some-human"; then fail "default: some-human must NOT be a member"; fi
echo "(default) engels74-bot/renovate[bot]/dependabot[bot] match, some-human does not — OK"

# Glob-safety: a login that looks like a shell glob metachar, or a near-miss without "[bot]",
# must never spuriously match via pattern expansion during the whitespace split.
if is_ci_fixer_author "*"; then fail "default: literal '*' must NOT spuriously match"; fi
if is_ci_fixer_author "renovate"; then fail "default: bare 'renovate' (no [bot]) must NOT match"; fi
echo "(default) glob-unsafe/near-miss logins '*' and 'renovate' do not match — OK"

# ── CI_FIXER_AUTHORS="-" sentinel -> EMPTY set, nobody matches ────────────────────────────
export CI_FIXER_AUTHORS="-"
if is_ci_fixer_author "engels74-bot"; then fail "sentinel '-': engels74-bot must NOT match"; fi
if is_ci_fixer_author "renovate[bot]"; then fail "sentinel '-': renovate[bot] must NOT match"; fi
if is_ci_fixer_author "dependabot[bot]"; then fail "sentinel '-': dependabot[bot] must NOT match"; fi
if is_ci_fixer_author "some-human"; then fail "sentinel '-': some-human must NOT match"; fi
echo "(sentinel -) empty set: nobody matches — OK"

# ── CI_FIXER_AUTHORS="engels74-bot" -> only the bot matches ───────────────────────────────
export CI_FIXER_AUTHORS="engels74-bot"
is_ci_fixer_author "engels74-bot" || fail "single-author: engels74-bot must be a member"
if is_ci_fixer_author "renovate[bot]"; then fail "single-author: renovate[bot] must NOT match"; fi
if is_ci_fixer_author "dependabot[bot]"; then fail "single-author: dependabot[bot] must NOT match"; fi
if is_ci_fixer_author "some-human"; then fail "single-author: some-human must NOT match"; fi
echo "(single-author) only engels74-bot matches — OK"

echo "PASS"
exit 0
