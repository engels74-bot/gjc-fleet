#!/usr/bin/env bash
# 10-engines.sh — install/upgrade the pinned upstream engines (clawhip,
# gajae-code, hermes-agent) per fleet.toml's [pins]. Idempotent: skips
# whatever already matches its pin, so it is safe to re-run.
#
#   10-engines.sh [--check]   report current vs. pinned versions only;
#                              installs/clones nothing.
set -uo pipefail

BOOTSTRAP_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "$BOOTSTRAP_DIR/.." && pwd)"
# shellcheck source=../render/lib/toml2json.sh
source "$REPO_ROOT/render/lib/toml2json.sh"

FLEET_TOML="${FLEET_TOML:-$HOME/.config/gjc-fleet/fleet.toml}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

[ -f "$FLEET_TOML" ] || {
  echo "10-engines.sh: config not found: $FLEET_TOML (see 30-config-homes.sh)" >&2
  exit 1
}
CFG_JSON="$(toml2json "$FLEET_TOML")"
cfg() { jq -r "$1 // empty" <<<"$CFG_JSON"; }

CLAWHIP_PIN="$(cfg '.pins.clawhip')"
GAJAE_PIN="$(cfg '.pins.gajae_code')"
HERMES_REF="$(cfg '.pins.hermes_ref')"
if [ -z "$CLAWHIP_PIN" ] || [ -z "$GAJAE_PIN" ] || [ -z "$HERMES_REF" ]; then
  echo "10-engines.sh: [pins] clawhip/gajae_code/hermes_ref must all be set in $FLEET_TOML" >&2
  exit 1
fi

status=0

# --- clawhip -------------------------------------------------------------------
current_clawhip=""
if command -v clawhip >/dev/null 2>&1; then
  current_clawhip="$(clawhip --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
if [ "$current_clawhip" = "$CLAWHIP_PIN" ]; then
  echo "clawhip: already at pinned version $CLAWHIP_PIN"
elif [ "$CHECK" -eq 1 ]; then
  echo "clawhip: would install --version $CLAWHIP_PIN (current: ${current_clawhip:-none})"
else
  echo "clawhip: installing $CLAWHIP_PIN (current: ${current_clawhip:-none})"
  if cargo install clawhip --version "$CLAWHIP_PIN" --locked; then
    echo "clawhip: installed $CLAWHIP_PIN"
  else
    echo "clawhip: cargo install FAILED" >&2
    status=1
  fi
fi

# --- gajae-code (gjc) ------------------------------------------------------------
current_gajae=""
if command -v gjc >/dev/null 2>&1; then
  current_gajae="$(gjc --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
if [ "$current_gajae" = "$GAJAE_PIN" ]; then
  echo "gajae-code: already at pinned version $GAJAE_PIN"
elif [ "$CHECK" -eq 1 ]; then
  echo "gajae-code: would install bun global gajae-code@${GAJAE_PIN} (current: ${current_gajae:-none})"
else
  echo "gajae-code: installing $GAJAE_PIN (current: ${current_gajae:-none})"
  if bun add -g "gajae-code@${GAJAE_PIN}"; then
    echo "gajae-code: installed $GAJAE_PIN"
  else
    echo "gajae-code: bun install FAILED" >&2
    status=1
  fi
fi

# --- hermes-agent ------------------------------------------------------------------
if [ -d "$HERMES_HOME/hermes-agent" ]; then
  current_hermes_ref="$(git -C "$HERMES_HOME/hermes-agent" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [ "$current_hermes_ref" = "$HERMES_REF" ]; then
    echo "hermes-agent: already at pinned ref $HERMES_REF"
  else
    # Hermes TRACKS LATEST via pipeline/maintenance/hermes-update.sh (health-gated,
    # with rollback) — it is NOT ref-pinned by this bootstrap. We only report drift here
    # and delegate the actual update; never auto-run hermes-update from here.
    echo "hermes-agent: deployed ref is $current_hermes_ref, pin is $HERMES_REF — hermes updates are owned by pipeline/maintenance/hermes-update.sh (track-latest, health-gated)"
    if [ "$CHECK" -ne 1 ]; then
      echo "hermes-agent: to update, run: $REPO_ROOT/pipeline/maintenance/hermes-update.sh --apply (not auto-run from here)"
    fi
  fi
elif [ "$CHECK" -eq 1 ]; then
  echo "hermes-agent: would clone NousResearch/hermes-agent @ $HERMES_REF into $HERMES_HOME/hermes-agent (venv/, not .venv/)"
else
  echo "hermes-agent: cloning @ $HERMES_REF into $HERMES_HOME/hermes-agent"
  if git clone https://github.com/NousResearch/hermes-agent "$HERMES_HOME/hermes-agent" \
    && git -C "$HERMES_HOME/hermes-agent" checkout "$HERMES_REF" \
    && python3 -m venv "$HERMES_HOME/hermes-agent/venv" \
    && "$HERMES_HOME/hermes-agent/venv/bin/pip" install -e "$HERMES_HOME/hermes-agent"; then
    echo "hermes-agent: cloned + installed @ $HERMES_REF (venv/)"
  else
    echo "hermes-agent: clone/checkout/venv install FAILED" >&2
    status=1
  fi
fi

exit "$status"
