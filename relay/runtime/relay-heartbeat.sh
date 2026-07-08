#!/usr/bin/env bash
# gjc-relay-heartbeat — self-priming token-cache heartbeat for gjc-relay.
#
# WHY: gjc-relay's TokenCache is populated from the Authorization header on an
# authenticated inbound clawhip request; the relay never stores the Discord
# bot token itself (see relay.env.tmpl / relay/runtime/alert.sh headers). If no
# real notification arrives for a while (quiet period, or right after a relay
# restart) that cache goes cold and the relay has nothing to forward with
# until the NEXT real notification shows up. This unit closes that gap by
# emitting a synthetic no-op inbound at a fixed cadence (gjc-relay-heartbeat.timer)
# so the token stays warm.
#
# This traverses the NORMAL clawhip -> gjc-relay path (unlike alert.sh/dlq-watch.sh,
# which curl Discord directly to bypass clawhip+relay) — that traversal through the
# relay is the entire point, since it's what refreshes the TokenCache. The relay
# recognizes an inbound `kind=heartbeat` GJCEMBED1 message as "capture the
# pass-through token, then drop": it is NEVER rendered to Discord, so the target
# channel never gets a visible post regardless of which channel is used.
#
# Channel: sent to the fleet's throwaway canary channel (#gjc-lab), resolved from
# a rendered env var — never hardcoded. render/render.sh appends GJC_LAB_CHANNEL to
# the rendered relay.env (alongside GJC_ALERT_CHANNEL), so the heartbeat targets
# #gjc-lab. If the var is unset (older render), this script is a safe, quiet no-op
# rather than misdirecting the heartbeat or hardcoding a numeric channel ID
# (repo policy forbids that outright).
set -euo pipefail

# Kill switch. Contract default: enabled (RELAY_HEARTBEAT_ENABLED defaults to 1
# both here and in relay/src/config.rs).
: "${RELAY_HEARTBEAT_ENABLED:=1}"
if [ "$RELAY_HEARTBEAT_ENABLED" != "1" ]; then
  exit 0
fi

LAB_CHANNEL="${GJC_LAB_CHANNEL:-}"
if [ -z "$LAB_CHANNEL" ]; then
  logger -t gjc-relay-heartbeat "GJC_LAB_CHANNEL not set (relay.env not rendering it yet); skipping heartbeat" 2>/dev/null || true
  exit 0
fi

CLAWHIP_BIN="${CLAWHIP_BIN:-$HOME/.cargo/bin/clawhip}"
if ! command -v "$CLAWHIP_BIN" >/dev/null 2>&1; then
  logger -t gjc-relay-heartbeat "clawhip binary not found at ${CLAWHIP_BIN}; skipping heartbeat" 2>/dev/null || true
  exit 0
fi

# Minimal, idempotent: one no-op inbound per invocation, no local state to track.
"$CLAWHIP_BIN" send --channel "$LAB_CHANNEL" --message "GJCEMBED1 kind=heartbeat :: heartbeat" >/dev/null 2>&1 \
  || logger -t gjc-relay-heartbeat "clawhip send failed" 2>/dev/null || true

exit 0
