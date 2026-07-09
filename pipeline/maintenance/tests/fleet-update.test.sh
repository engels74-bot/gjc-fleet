#!/usr/bin/env bash
# fleet-update.test.sh — Workstream G proof for the nightly fleet tool-update lane
# orchestrator (fleet-update.sh), driven fully offline.
#
# NEVER touches the live host toolchain, real locks, hermes, or Discord: fleet-update.sh
# is run as a subprocess with EVERY external binding repointed under $TMP — a stub
# lib/discord-embed.sh (records embeds, sends nothing), stub tool-update.sh /
# hermes-update.sh / verify.sh children (record any invocation, mutate nothing), and
# $TMP lock paths. Cases:
#
#   (a) TOOL_UPDATE_ENABLED unset            -> exit 0, zero actions (no children, no embed)
#   (b) disable marker present               -> exit 0, zero actions
#   (c) DRY_RUN=1 (enabled)                  -> logs intents (tool-update + hermes-update + verify),
#                                               executes NO child, mutates nothing
#   (d) quiesce timeout (gjc.lock held)      -> DEFER notice embed, exit 0, no child called
set -uo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$HERE/../fleet-update.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# ── stub tree under $TMP ──────────────────────────────────────────────────────
mkdir -p "$TMP/lib" "$TMP/coord"
EMBEDS="$TMP/embeds.log"
: >"$EMBEDS"

# Stub design-system embed lib: record the embed, send NOTHING.
cat >"$TMP/lib/discord-embed.sh" <<EOF
#!/usr/bin/env bash
discord_embed() { printf '%s\n' "\$*" >> "$EMBEDS"; return 0; }
EOF

# Stub children: record ANY invocation to a marker; mutate nothing.
for child in tool-update hermes-update verify; do
  cat >"$TMP/$child.sh" <<EOF
#!/usr/bin/env bash
printf 'called %s\n' "\$*" >> "$TMP/$child.called"
exit 0
EOF
  chmod 755 "$TMP/$child.sh"
done

LOG="$TMP/fleet-update.log"

# run_fleet <extra env assignments...> — invoke fleet-update.sh as an isolated subprocess.
run_fleet() {
  : >"$LOG"; : >"$EMBEDS"
  rm -f "$TMP"/tool-update.called "$TMP"/hermes-update.called "$TMP"/verify.called 2>/dev/null || true
  env \
    GJC_BOT_STATE="$TMP" \
    GJC_BOT_SCRIPTS="$TMP" \
    FLEET_UPDATE_LOG="$LOG" \
    FLEET_TOOL_UPDATE_SH="$TMP/tool-update.sh" \
    FLEET_HERMES_UPDATE_SH="$TMP/hermes-update.sh" \
    FLEET_VERIFY_SH="$TMP/verify.sh" \
    FLEET_UPDATE_COORD_STATE_ROOT="$TMP/coord" \
    FLEET_UPDATE_CHANNEL="testchan" \
    GJC_LOCK="$TMP/gjc.lock" \
    REVIEW_LOCK="$TMP/review.lock" \
    TOOL_UPDATE_RESULTS="$TMP/results.tsv" \
    "$@" \
    bash "$FLEET"
}

no_child_called() {
  [ ! -s "$TMP/tool-update.called" ] && [ ! -s "$TMP/hermes-update.called" ] && [ ! -s "$TMP/verify.called" ]
}

echo "===== fleet-update orchestrator assertions (offline) ====="

# ── (a) TOOL_UPDATE_ENABLED unset -> exit 0, zero actions ─────────────────────
run_fleet; rc=$?
echo "(a) rc=$rc"
[ "$rc" -eq 0 ] || fail "(a) enable unset must exit 0, got $rc"
grep -q "disabled (TOOL_UPDATE_ENABLED=" "$LOG" || fail "(a) expected a 'disabled' log line"
no_child_called || fail "(a) no child script may run when disabled"
[ ! -s "$EMBEDS" ] || fail "(a) no embed may be sent when disabled"

# ── (b) disable marker present -> exit 0, zero actions ────────────────────────
touch "$TMP/fleet-update.disable"
run_fleet TOOL_UPDATE_ENABLED=1; rc=$?
rm -f "$TMP/fleet-update.disable"
echo "(b) rc=$rc"
[ "$rc" -eq 0 ] || fail "(b) disable marker must exit 0, got $rc"
grep -q "disable marker present" "$LOG" || fail "(b) expected a 'disable marker present' log line"
no_child_called || fail "(b) no child script may run when marker present"
[ ! -s "$EMBEDS" ] || fail "(b) no embed may be sent when marker present"

# ── (c) DRY_RUN=1 (enabled) -> logs intents, executes no child, mutates nothing ─
run_fleet TOOL_UPDATE_ENABLED=1 DRY_RUN=1; rc=$?
echo "(c) rc=$rc"
[ "$rc" -eq 0 ] || fail "(c) DRY_RUN must exit 0, got $rc"
grep -q "DRY_RUN would run: tool-update"  "$LOG" || fail "(c) missing tool-update intent"
grep -q "DRY_RUN would run: hermes-update" "$LOG" || fail "(c) missing hermes-update intent"
grep -q "DRY_RUN would run: verify"        "$LOG" || fail "(c) missing verify intent"
no_child_called || fail "(c) DRY_RUN must NOT execute any child script"
[ ! -s "$EMBEDS" ] || fail "(c) DRY_RUN plan-only must not emit an embed"

# ── (d) quiesce timeout (gjc.lock held) -> DEFER embed, exit 0, no child ───────
exec 9>"$TMP/gjc.lock"
flock -n 9 || fail "(d) test could not take gjc.lock for the held-lock fixture"
run_fleet TOOL_UPDATE_ENABLED=1 QUIESCE_TIMEOUT_SECS=1; rc=$?
flock -u 9; exec 9>&-
echo "(d) rc=$rc  embed=$(tr '\n' '|' <"$EMBEDS")"
[ "$rc" -eq 0 ] || fail "(d) quiesce timeout must DEFER with exit 0, got $rc"
grep -q "fleet-update" "$EMBEDS" || fail "(d) expected a fleet-update DEFER embed"
grep -q "deferred"     "$EMBEDS" || fail "(d) DEFER embed must carry status=deferred"
grep -q "DEFER to next night" "$LOG" || fail "(d) expected a DEFER log line"
no_child_called || fail "(d) no child may run when quiesce times out"

echo "PASS: enable+marker gates exit-0-quietly, DRY_RUN logs intents with zero execution, and quiesce-timeout DEFERs without forcing."
exit 0
