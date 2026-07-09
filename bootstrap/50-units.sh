#!/usr/bin/env bash
# 50-units.sh — build gjc-relay, deploy its runtime scripts, install the
# systemd user units, and bring the fleet daemons up in dependency order.
#
#   50-units.sh [--check]   report-only: no build, no unit install, no
#                            (re)starts, no `loginctl enable-linger`.
set -uo pipefail

BOOTSTRAP_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "$BOOTSTRAP_DIR/.." && pwd)"
# shellcheck source=../pipeline/lib/userctl.sh
source "$REPO_ROOT/pipeline/lib/userctl.sh"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

GJC_RELAY_HOME="${GJC_RELAY_HOME:-$HOME/.gjc-relay}"
HEALTHZ_URL="${GJC_RELAY_HEALTHZ:-http://127.0.0.1:25295/healthz}"

status=0

# --- 1. build + deploy the relay ---------------------------------------------------
if [ "$CHECK" -eq 1 ]; then
  echo "would run: cargo test && cargo build --release (in $REPO_ROOT/relay), then deploy binary + runtime scripts"
else
  echo "building gjc-relay (cargo test && cargo build --release)…"
  if ! ( cd "$REPO_ROOT/relay" && cargo test && cargo build --release ); then
    echo "50-units.sh: relay build/test FAILED" >&2
    exit 1
  fi
  mkdir -p "$GJC_RELAY_HOME"
  cp --remove-destination "$REPO_ROOT/relay/target/release/gjc-relay" "$GJC_RELAY_HOME/gjc-relay"
  echo "installed: $GJC_RELAY_HOME/gjc-relay"
  for s in alert.sh dlq-watch.sh; do
    cp "$REPO_ROOT/relay/runtime/$s" "$GJC_RELAY_HOME/$s"
    chmod 700 "$GJC_RELAY_HOME/$s"
    echo "installed: $GJC_RELAY_HOME/$s (mode 700)"
  done
  cp "$REPO_ROOT/relay/runtime/check-kind-coverage.sh" "$GJC_RELAY_HOME/check-kind-coverage.sh"
  chmod 755 "$GJC_RELAY_HOME/check-kind-coverage.sh"
  echo "installed: $GJC_RELAY_HOME/check-kind-coverage.sh (mode 755)"
fi

# --- 2. linger ----------------------------------------------------------------------
if [ "$CHECK" -eq 1 ]; then
  echo 'would run: loginctl enable-linger $USER'
elif loginctl enable-linger "$USER"; then
  echo "ok: linger enabled for $USER"
else
  echo "WARN: 'loginctl enable-linger $USER' failed (needs a polkit/dbus session)." >&2
  echo "  # fallback: sudo loginctl enable-linger $USER" >&2
fi

# --- 3. install units + daemon-reload -------------------------------------------------
if [ "$CHECK" -eq 1 ]; then
  echo "would run: render.sh apply --units --yes && userctl daemon-reload"
else
  if bash "$REPO_ROOT/render/render.sh" apply --units --yes; then
    echo "ok: units rendered + installed to ~/.config/systemd/user"
  else
    echo "50-units.sh: render.sh apply --units FAILED" >&2
    exit 1
  fi
  if userctl daemon-reload; then
    echo "ok: daemon-reload"
  else
    echo "50-units.sh: daemon-reload FAILED" >&2
    exit 1
  fi
fi

# --- 4. enable + start in dependency order --------------------------------------------
enable_start() {  # <unit>
  local unit="$1"
  if [ "$CHECK" -eq 1 ]; then
    echo "would run: userctl enable --now $unit"
    return 0
  fi
  if userctl enable --now "$unit"; then
    echo "ok: $unit enabled + started"
  else
    echo "50-units.sh: failed to enable/start $unit" >&2
    return 1
  fi
}

enable_start gjc-relay.service || exit 1

if [ "$CHECK" -eq 1 ]; then
  echo "would gate on: $HEALTHZ_URL (retry up to 15s) before starting clawhip"
else
  echo "waiting for gjc-relay healthz…"
  healthy=0
  for _ in {1..15}; do
    if curl -fsS --max-time 1 "$HEALTHZ_URL" >/dev/null 2>&1; then healthy=1; break; fi
    sleep 1
  done
  if [ "$healthy" -ne 1 ]; then
    echo "50-units.sh: gjc-relay healthz did not come up within 15s ($HEALTHZ_URL) — aborting" >&2
    exit 1
  fi
  echo "ok: gjc-relay healthz up"
fi

enable_start clawhip.service || exit 1
enable_start gjc-dlq-watch.service || exit 1
for t in issue-spool-adapter.timer review-detector.timer merge-gate.timer gjc-worktree-janitor.timer; do
  enable_start "$t" || exit 1
done
enable_start issue-spool-adapter.path || exit 1

# automerge lane (Workstream F) — default OFF, gated by AUTOMERGE_ENABLED via render's
# lane_gate_var. render.sh only INSTALLS the unit when the lane is enabled, so gate the enable
# on the installed unit file: on a default-off host it is simply absent and we skip cleanly.
if [ "$CHECK" -eq 1 ]; then
  echo "would run (iff automerge lane enabled): userctl enable --now automerge.timer"
elif [ -f "$HOME/.config/systemd/user/automerge.timer" ]; then
  enable_start automerge.timer || exit 1
else
  echo "note: automerge lane disabled (automerge.timer not installed) — skipping enable"
fi

# fleet-update lane (Workstream G) — default OFF, gated by TOOL_UPDATE_ENABLED via render's
# lane_gate_var; render.sh only INSTALLS the unit when the lane is enabled, so gate the enable
# on the installed unit file (absent on a default-off host => skip cleanly).
if [ "$CHECK" -eq 1 ]; then
  echo "would run (iff updates lane enabled): userctl enable --now fleet-update.timer"
elif [ -f "$HOME/.config/systemd/user/fleet-update.timer" ]; then
  enable_start fleet-update.timer || exit 1
else
  echo "note: fleet-update lane disabled (fleet-update.timer not installed) — skipping enable"
fi

# --- 5. hermes gateway install ---------------------------------------------------------
HERMES_VENV_PY="$HOME/.hermes/hermes-agent/venv/bin/python"
if [ ! -x "$HERMES_VENV_PY" ]; then
  echo "note: hermes not deployed yet ($HERMES_VENV_PY missing) — skipping 'hermes gateway install'"
elif [ "$CHECK" -eq 1 ]; then
  echo "would run: $HERMES_VENV_PY -m hermes_cli.main gateway install"
elif "$HERMES_VENV_PY" -m hermes_cli.main gateway install; then
  echo "ok: hermes gateway install"
else
  echo "50-units.sh: hermes gateway install FAILED" >&2
  status=1
fi

exit "$status"
