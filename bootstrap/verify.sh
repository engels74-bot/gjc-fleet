#!/usr/bin/env bash
# verify.sh — standing health harness for the gjc-fleet (bootstrap + post-change
# on the live host). Runs a fixed set of named checks; each prints "ok: ..."
# or "FAIL: ..." and the script exits non-zero if any check failed.
#
#   verify.sh [--quick]   --quick skips the canary Discord emit (check 9) and
#                          the work-item thread canary (check 14); everything
#                          else still runs.
set -uo pipefail

BOOTSTRAP_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "$BOOTSTRAP_DIR/.." && pwd)"
# shellcheck source=../pipeline/lib/userctl.sh
source "$REPO_ROOT/pipeline/lib/userctl.sh"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

FLEET_TOML="${FLEET_TOML:-$HOME/.config/gjc-fleet/fleet.toml}"
SPOOL="${ISSUE_SPOOL:-$HOME/.gjc-bot/issue-spool.jsonl}"
CLAWHIP_BIN="${CLAWHIP_BIN:-$HOME/.cargo/bin/clawhip}"
RELAY_STATE_DIR="${RELAY_STATE_DIR:-$HOME/.gjc-relay/state}"
RELAY_WORKITEM_CHANNELS="${RELAY_WORKITEM_CHANNELS:-}"
GJC_LAB_CHANNEL="${GJC_LAB_CHANNEL:-}"

fail=0
ok()  { printf 'ok:   %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

# 1. linger --------------------------------------------------------------------------
if [ -f "/var/lib/systemd/linger/$USER" ]; then
  ok "linger enabled for $USER"
else
  bad "linger not enabled for $USER (/var/lib/systemd/linger/$USER missing)"
fi

# 2. user manager reachable -----------------------------------------------------------
if userctl is-system-running --quiet 2>/dev/null; then
  ok "user systemd manager: running"
else
  state="$(userctl is-system-running 2>/dev/null || true)"
  if [ "$state" = "degraded" ]; then
    ok "user systemd manager: degraded (acceptable)"
  else
    bad "user systemd manager unreachable or in state '$state'"
  fi
fi

# 3. unit + timer + path states --------------------------------------------------------
for u in gjc-relay clawhip gjc-dlq-watch hermes-gateway; do
  if userctl is-enabled --quiet "$u.service" 2>/dev/null && userctl is-active --quiet "$u.service" 2>/dev/null; then
    ok "$u.service: enabled + active"
  else
    bad "$u.service: not both enabled and active"
  fi
done
for t in issue-spool-adapter.timer review-detector.timer merge-gate.timer gjc-worktree-janitor.timer; do
  if userctl list-timers --all --no-legend 2>/dev/null | grep -q "$t"; then
    ok "$t: scheduled"
  else
    bad "$t: not in 'userctl list-timers'"
  fi
done
if userctl is-active --quiet issue-spool-adapter.path 2>/dev/null; then
  ok "issue-spool-adapter.path: active"
else
  bad "issue-spool-adapter.path: not active"
fi
if [ -f "$HOME/.config/systemd/user/gjc-relay-alert.service" ]; then
  ok "gjc-relay-alert.service: unit file present (inactive OK — OnFailure-pulled)"
else
  bad "gjc-relay-alert.service: unit file missing"
fi

# 4. loopback ports listening ----------------------------------------------------------
for p in 25294 25295; do
  if ss -ltn 2>/dev/null | grep -q "127.0.0.1:${p}[[:space:]]"; then
    ok "127.0.0.1:$p listening"
  else
    bad "127.0.0.1:$p not listening"
  fi
done

# 5. healthz -----------------------------------------------------------------------------
if curl -fsS --max-time 3 http://127.0.0.1:25295/healthz >/dev/null 2>&1; then
  ok "gjc-relay /healthz -> 200"
else
  bad "gjc-relay /healthz did not return 200"
fi

# 6. user journal flowing -----------------------------------------------------------------
if [ -n "$(userjournal -u clawhip.service -n 1 --no-pager 2>/dev/null)" ]; then
  ok "clawhip.service journal has entries"
else
  bad "clawhip.service journal is empty"
fi

# 7. dlq-watch armed -----------------------------------------------------------------------
if userctl is-active --quiet gjc-dlq-watch.service 2>/dev/null; then
  # MainPID is the bash script running the `journalctl | while read` pipeline;
  # the journalctl follower itself is a direct child of that PID, not the
  # main process — check the child, not MainPID's own /proc/*/cmdline.
  watcher_pid="$(userctl show -p MainPID --value gjc-dlq-watch.service 2>/dev/null || echo 0)"
  if [ -n "$watcher_pid" ] && [ "$watcher_pid" != "0" ] && pgrep -f -P "$watcher_pid" journalctl >/dev/null 2>&1; then
    ok "gjc-dlq-watch: active with a journalctl follower in its cgroup"
  else
    bad "gjc-dlq-watch: active but no journalctl follower process found"
  fi
else
  bad "gjc-dlq-watch.service: not active"
fi

# 8. spool probe ----------------------------------------------------------------------------
if [ -f "$SPOOL" ]; then
  before_id="$(userctl show -p InvocationID --value issue-spool-adapter.service 2>/dev/null || echo "")"
  printf '%s\n' '{"event_kind":"fleet.verify"}' >> "$SPOOL"
  changed=0
  for _ in {1..10}; do
    after_id="$(userctl show -p InvocationID --value issue-spool-adapter.service 2>/dev/null || echo "")"
    if [ -n "$after_id" ] && [ "$after_id" != "$before_id" ]; then changed=1; break; fi
    sleep 1
  done
  if [ "$changed" -eq 1 ]; then
    ok "spool probe: issue-spool-adapter.service re-invoked (InvocationID changed)"
  else
    bad "spool probe: issue-spool-adapter.service InvocationID did not change within 10s"
  fi
else
  bad "spool probe: $SPOOL does not exist"
fi

# 9. canary (skipped with --quick) -----------------------------------------------------------
if [ "$QUICK" -eq 1 ]; then
  echo "skip: canary emit (--quick)"
elif [ -x "$CLAWHIP_BIN" ]; then
  before_bury="$(userjournal -u clawhip.service --since "-20s" 2>/dev/null | grep -c 'dlq bury:' || true)"
  if "$CLAWHIP_BIN" emit gjc.canary --repo verify --status ok --actor verify.sh --message "fleet verify" >/dev/null 2>&1; then
    canary_seen=0
    for _ in {1..20}; do
      if userjournal -u gjc-relay.service --since "-20s" 2>/dev/null | grep -q '\[transform\]'; then canary_seen=1; break; fi
      sleep 1
    done
    after_bury="$(userjournal -u clawhip.service --since "-20s" 2>/dev/null | grep -c 'dlq bury:' || true)"
    if [ "$canary_seen" -eq 1 ] && [ "${after_bury:-0}" -le "${before_bury:-0}" ]; then
      ok "canary: relay [transform] line seen, no new dlq bury"
    else
      bad "canary: no [transform] line seen, or a new dlq bury was recorded"
    fi
  else
    bad "canary: 'clawhip emit gjc.canary' failed"
  fi
else
  bad "canary: clawhip binary not found at $CLAWHIP_BIN"
fi

# 10. identity -------------------------------------------------------------------------------
if [ -f "$FLEET_TOML" ]; then
  # shellcheck source=../render/lib/toml2json.sh
  source "$REPO_ROOT/render/lib/toml2json.sh"
  bot_login="$(jq -r '.operator.bot_login // empty' <<<"$(toml2json "$FLEET_TOML")")"
  # `gh auth status` has no --user filter; find our account's own block and
  # check its "Active account: true" line, not just that a login exists.
  gh_id_block=""
  if [ -n "$bot_login" ] && command -v gh >/dev/null 2>&1; then
    gh_id_block="$(gh auth status 2>&1 | grep -A2 -E "account ${bot_login}([[:space:]]|\$)")"
  fi
  if printf '%s\n' "$gh_id_block" | grep -q 'Active account: true'; then
    ok "gh auth status: $bot_login active"
  else
    bad "gh auth status: $bot_login not active (or gh/fleet.toml unavailable)"
  fi
  if [ -n "$bot_login" ] && [ -f "$HOME/.gitconfig" ] && grep -qF "gitdir:$HOME/github/$bot_login/" "$HOME/.gitconfig"; then
    ok "includeIf satellite gitconfig block present for $bot_login"
  else
    bad "includeIf satellite gitconfig block missing"
  fi
else
  bad "identity: $FLEET_TOML missing"
fi

# 11. tool bins resolvable ---------------------------------------------------------------------
for bin in gjc clawhip gh jq tmux; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin resolvable on PATH"
  else
    bad "$bin not resolvable on PATH"
  fi
done

# 12. deployed relay scripts match the repo -----------------------------------------------------
for s in alert.sh dlq-watch.sh check-kind-coverage.sh; do
  deployed="$HOME/.gjc-relay/$s"
  src="$REPO_ROOT/relay/runtime/$s"
  if [ -f "$deployed" ] && diff -q "$src" "$deployed" >/dev/null 2>&1; then
    ok "$s: deployed copy matches repo"
  else
    bad "$s: deployed copy missing or drifted from repo"
  fi
done

# 13. relay state sanity (always runs) ----------------------------------------------------------
state_file="$RELAY_STATE_DIR/state.json"
if [ -f "$state_file" ]; then
  if jq -e '.version==2' "$state_file" >/dev/null 2>&1; then
    ok "relay state.json: version==2"
  else
    bad "relay state.json: version!=2 (or unparsable)"
  fi
else
  ok "relay state.json: absent (feature may be off / fresh host)"
fi

queue_dir="$RELAY_STATE_DIR/queue"
queue_stale=0
if [ -d "$queue_dir" ]; then
  now="${EPOCHSECONDS:-$(date +%s)}"
  while IFS= read -r -d '' f; do
    m="$(stat -c '%Y' "$f" 2>/dev/null || echo "$now")"
    if [ $((now - m)) -gt 300 ]; then queue_stale=1; break; fi
  done < <(find "$queue_dir" -maxdepth 1 -type f -print0 2>/dev/null)
fi
if [ "$queue_stale" -eq 0 ]; then
  ok "relay queue: no queued file older than 5m (empty/absent OK)"
else
  bad "relay queue: a queued file is older than 5m (stuck queue)"
fi

# 14. work-item thread canary (SKIPPABLE; only when the feature is on for #gjc-lab) --------------
if [ "$QUICK" -eq 1 ]; then
  echo "skip: work-item thread canary (--quick)"
elif [ -z "$RELAY_WORKITEM_CHANNELS" ] || [ -z "$GJC_LAB_CHANNEL" ] || \
     ! printf ',%s,' "$RELAY_WORKITEM_CHANNELS" | grep -qF ",$GJC_LAB_CHANNEL,"; then
  echo "skip: work-item thread canary (RELAY_WORKITEM_CHANNELS empty or #gjc-lab not opted in)"
elif [ -x "$CLAWHIP_BIN" ]; then
  if "$CLAWHIP_BIN" emit gjc.canary-item --channel "$GJC_LAB_CHANNEL" --repo verify --status ok \
       --actor verify.sh --message "fleet verify workitem canary" >/dev/null 2>&1; then
    workitem_seen=0
    for _ in {1..20}; do
      if userjournal -u gjc-relay.service --since "-20s" 2>/dev/null | grep -qE '\[(edit|thread)\]'; then workitem_seen=1; break; fi
      sleep 1
    done
    if [ "$workitem_seen" -eq 1 ]; then
      ok "work-item canary: relay [edit] or [thread] line seen"
    else
      bad "work-item canary: no [edit]/[thread] line seen within poll window"
    fi
  else
    bad "work-item canary: 'clawhip emit gjc.canary-item' failed"
  fi
else
  bad "work-item canary: clawhip binary not found at $CLAWHIP_BIN"
fi

# 15. kind coverage (always runs) -----------------------------------------------------------------
if kind_coverage_out="$(bash "$REPO_ROOT/relay/runtime/check-kind-coverage.sh" 2>&1)"; then
  ok "check-kind-coverage.sh: exit 0"
else
  bad "check-kind-coverage.sh: non-zero exit"
  printf '%s\n' "$kind_coverage_out" >&2
fi

echo "--- render.sh doctor (warnings non-fatal) ---"
bash "$REPO_ROOT/render/render.sh" doctor || true

if [ "$fail" -ne 0 ]; then
  echo "verify.sh: one or more checks FAILED (see above)." >&2
  exit 1
fi
echo "verify.sh: all checks passed."
