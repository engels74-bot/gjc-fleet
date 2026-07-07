#!/usr/bin/env bash
# 30-config-homes.sh — create the fleet's config/state home directories, then
# render + apply the live configs from fleet.toml via render/render.sh.
#
#   30-config-homes.sh [--check]   create nothing and skip render.sh apply;
#                                   report what's missing/would change.
set -uo pipefail

BOOTSTRAP_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "$BOOTSTRAP_DIR/.." && pwd)"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

FLEET_TOML="${FLEET_TOML:-$HOME/.config/gjc-fleet/fleet.toml}"
HOMES=("$HOME/.clawhip" "$HOME/.hermes" "$HOME/.gjc-bot" "$HOME/.gjc-relay" "$HOME/.gjc")

status=0
for d in "${HOMES[@]}"; do
  if [ -d "$d" ]; then
    echo "ok: $d exists"
  elif [ "$CHECK" -eq 1 ]; then
    echo "would create: $d (mode 700)"
  elif mkdir -p "$d" && chmod 700 "$d"; then
    echo "created: $d (mode 700)"
  else
    echo "FAILED to create $d" >&2
    status=1
  fi
done

spool="$HOME/.gjc-bot/issue-spool.jsonl"
if [ -f "$spool" ]; then
  echo "ok: $spool exists"
elif [ "$CHECK" -eq 1 ]; then
  echo "would create: $spool (empty)"
elif : > "$spool"; then
  echo "created: $spool (empty)"
else
  echo "FAILED to create $spool" >&2
  status=1
fi

if [ ! -f "$FLEET_TOML" ]; then
  echo "MISSING: $FLEET_TOML does not exist." >&2
  echo "  cp $REPO_ROOT/fleet.toml.example $FLEET_TOML" >&2
  echo "  # then fill in [operator]/[discord.channels]/[[repos]] with YOUR values, and re-run this step." >&2
  exit 1
fi
echo "ok: $FLEET_TOML exists"

if [ "$CHECK" -eq 1 ]; then
  echo "would run: render.sh render && render.sh apply --yes"
  bash "$REPO_ROOT/render/render.sh" render >/dev/null
  echo "render.sh render: staged OK (dry — apply skipped in --check mode)"
  exit "$status"
fi

if bash "$REPO_ROOT/render/render.sh" render >/dev/null; then
  echo "render.sh render: staged OK"
else
  echo "render.sh render FAILED" >&2
  exit 1
fi

if bash "$REPO_ROOT/render/render.sh" apply --yes; then
  echo "render.sh apply --yes: configs applied (clawhip config, relay.env, design-system.json, gjc-bot.env)"
else
  echo "render.sh apply FAILED" >&2
  exit 1
fi

exit "$status"
