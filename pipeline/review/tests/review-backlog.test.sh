#!/usr/bin/env bash
# review-backlog.test.sh — MUST-FIX (K7, PM4 mitigation). Proves review-detector.sh's K7
# review-backlog signal: when the OLDEST unhandled suggestion review in a repo is older than
# REVIEW_BACKLOG_ALERT_MINS, the detector emits EXACTLY ONE review.backlog design-system embed;
# under the threshold it is SILENT; and it dedups so a fast poll cannot spam.
#
# The detector is sourced (REVIEW_DETECTOR_NO_MAIN=1) and review_backlog_check() is driven
# directly with a stubbed gh (pr list) + an overridden latest_suggestion_review carrying a chosen
# submitted_at + a stubbed discord_embed. Plus a render-level assertion that the review.backlog
# kind is actually defined in design-system.json (so the emit renders, not silently greys).
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="$HERE/../review-detector.sh"
DS="$HERE/../../../relay/runtime/design-system.json"

EMBEDS="$TMP/embeds.log"
: >"$EMBEDS"

# gh stub: `pr list` returns one open renovate PR (tsv: number \t login \t <trailing>); the detector's
# own --jq is bypassed because we override the whole gh call output for pr list.
STUB_PRLIST=$'42\trenovate[bot]\t'
cat >"$TMP/gh-stub.sh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr list"*) printf '%s\n' "\$STUB_PRLIST" ;;
  *) exit 0 ;;
esac
EOF
chmod 755 "$TMP/gh-stub.sh"

export GJC_BOT_STATE="$TMP"
export REVIEW_SEEN="$TMP/reviews.jsonl"
export REVIEW_POLICY_LEDGER="$TMP/review-policy.jsonl"
export GH_BIN="$TMP/gh-stub.sh"
export REVIEW_REPOS="testrepo"
export GJC_BOT_GH_ROOT="$TMP/gh-root"
export GJC_BOT_GH_OWNER="engels74"
export REVIEW_AUTOMATED_AUTHORS="renovate[bot] dependabot[bot]"
export REVIEW_BACKLOG_ALERT_MINS="120"
export REVIEW_BACKLOG_CHANNEL="approvals"
export DRY_RUN="0"
export REVIEW_DETECTOR_NO_MAIN="1"
export STUB_PRLIST
mkdir -p "$GJC_BOT_GH_ROOT"

# shellcheck source=/dev/null
source "$DETECTOR"

# Override the impure seams AFTER sourcing: a suggestion review whose submitted_at we control,
# and an embed sink. `seen` (SEEN ledger) + `#consumed` (policy ledger) stay REAL and empty, so
# the PR reads as UNHANDLED.
STUB_SUBMITTED=""
latest_suggestion_review() { printf '{"id":777,"submitted_at":"%s"}' "$STUB_SUBMITTED"; return 0; }
discord_embed() { printf '%s\n' "$*" >> "$EMBEDS"; return 0; }

fail() { echo "FAIL: $*" >&2; exit 1; }
emits() { grep -c 'review.backlog' "$EMBEDS" 2>/dev/null || true; }

OLD_ISO="$(date -u -d '-200 min' +%Y-%m-%dT%H:%M:%SZ)"
NEW_ISO="$(date -u -d '-5 min'   +%Y-%m-%dT%H:%M:%SZ)"

echo "===== K7 review-backlog signal assertions ====="

# ── (a) design-system kind exists (render-level: the emit renders, not greys) ──────────────
[ -f "$DS" ] || fail "design-system.json not found at $DS"
grep -q '"review.backlog"' "$DS" || fail "review.backlog kind missing from design-system.json"
echo "(a) review.backlog kind defined in design-system.json — OK"

# ── (b) oldest unhandled review 200m old > 120m threshold -> exactly ONE embed ─────────────
: >"$EMBEDS"; STUB_SUBMITTED="$OLD_ISO"
review_backlog_check "testrepo"
[ "$(emits)" -eq 1 ] || fail "(b) expected exactly ONE review.backlog embed over threshold, got $(emits)"
echo "(b) 200m-old unhandled review over 120m threshold -> one review.backlog embed — OK"

# ── (c) dedup: a second poll in the same host-hour -> NO new embed ─────────────────────────
: >"$EMBEDS"; STUB_SUBMITTED="$OLD_ISO"
review_backlog_check "testrepo"
[ "$(emits)" -eq 0 ] || fail "(c) same-hour re-poll must be deduped (0 new embeds), got $(emits)"
echo "(c) same-hour re-poll deduped -> silent — OK"

# ── (d) under threshold -> SILENT (fresh repo to avoid the (b) dedup marker) ───────────────
export STUB_PRLIST=$'43\trenovate[bot]\t'
: >"$EMBEDS"; STUB_SUBMITTED="$NEW_ISO"
review_backlog_check "otherrepo"
[ "$(emits)" -eq 0 ] || fail "(d) under-threshold review must be SILENT, got $(emits)"
echo "(d) 5m-old review under 120m threshold -> silent — OK"

echo "PASS: review.backlog fires once over threshold, dedups within the hour, and stays silent under threshold."
exit 0
