#!/usr/bin/env bash
# 40-secrets.sh — presence-by-NAME audit of the secret custody files. Never
# reads or prints a secret VALUE, and never creates an env file (a
# placeholder secret file is worse than a missing one).
#
#   40-secrets.sh [--check]   this script is always check-only; --check is
#                              accepted for orchestrator uniformity (no-op).
set -uo pipefail

BOOTSTRAP_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "$BOOTSTRAP_DIR/.." && pwd)"
# shellcheck source=../render/lib/toml2json.sh
source "$REPO_ROOT/render/lib/toml2json.sh"

FLEET_TOML="${FLEET_TOML:-$HOME/.config/gjc-fleet/fleet.toml}"
[ -f "$FLEET_TOML" ] || { echo "40-secrets.sh: config not found: $FLEET_TOML" >&2; exit 1; }
CFG_JSON="$(toml2json "$FLEET_TOML")"
cfg() { jq -r "$1 // empty" <<<"$CFG_JSON"; }

HERMES_ENV="${HERMES_ENV:-$HOME/.hermes/.env}"
CLAWHIP_ENV="${CLAWHIP_ENV:-$HOME/.clawhip/clawhip.env}"

missing=0
declare -a checklist=()

check_key() {  # <file> <key> <role-note-if-missing>
  local file="$1" key="$2" note="$3"
  if [ ! -f "$file" ]; then
    echo "MISSING: $file does not exist (holds: $key)"
    checklist+=("$note")
    missing=1
    return
  fi
  if grep -q "^${key}=" "$file"; then
    echo "ok: $key present in $file"
  else
    echo "MISSING: $key not set in $file"
    checklist+=("$note")
    missing=1
  fi
}

check_key "$HERMES_ENV" GITHUB_TOKEN          "hermes: a GitHub PAT for the bot account (repo scope)"
check_key "$HERMES_ENV" NANOGPT_API_KEY        "hermes: a NanoGPT API key"
check_key "$HERMES_ENV" DISCORD_BOT_TOKEN      "hermes: the GJC Brain Discord bot token"
check_key "$HERMES_ENV" DISCORD_HOME_CHANNEL   "hermes: the GJC Brain home channel ID"
check_key "$CLAWHIP_ENV" CLAWHIP_GITHUB_TOKEN      "clawhip: a GitHub PAT for the bot account"
check_key "$CLAWHIP_ENV" CLAWHIP_DISCORD_BOT_TOKEN "clawhip: the GJC Clawhip Discord bot token"
check_key "$CLAWHIP_ENV" CLAWHIP_DISCORD_API_BASE  "clawhip: API base override pointing at the relay"

RELAY_BIND="$(cfg '.relay.bind')"; RELAY_BIND="${RELAY_BIND:-127.0.0.1:25295}"
EXPECT_API_BASE="http://${RELAY_BIND}/api/v10"
if [ -f "$CLAWHIP_ENV" ] && grep -q '^CLAWHIP_DISCORD_API_BASE=' "$CLAWHIP_ENV"; then
  actual="$(grep '^CLAWHIP_DISCORD_API_BASE=' "$CLAWHIP_ENV" | head -1 | cut -d= -f2-)"
  if [ "$actual" = "$EXPECT_API_BASE" ]; then
    echo "ok: CLAWHIP_DISCORD_API_BASE points at the relay ($EXPECT_API_BASE)"
  else
    echo "WARN: CLAWHIP_DISCORD_API_BASE differs from the expected relay bind (expected $EXPECT_API_BASE)"
  fi
fi

if [ "$missing" -ne 0 ]; then
  echo
  echo "Provisioning checklist (by role) for the items above:"
  for note in "${checklist[@]}"; do echo "  - $note"; done
  echo "40-secrets.sh: missing secrets listed above (values never shown)." >&2
  exit 1
fi

echo "40-secrets.sh: all secret keys present."
