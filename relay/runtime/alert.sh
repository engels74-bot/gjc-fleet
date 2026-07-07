#!/usr/bin/env bash
# gjc-relay-alert — out-of-band operator alarm fired by gjc-relay-alert.service
# (systemd OnFailure) when gjc-relay enters a terminal 'failed' state.
#
# CRITICAL DESIGN CONSTRAINT: this alert MUST NOT traverse clawhip or the relay,
# because those are exactly what may be down. It curls Discord DIRECTLY at
# https://discord.com (NOT the relay), and also emits to journald + local mail.
# The bot token is read from clawhip.env and is NEVER printed/echoed.
set -uo pipefail

# Numeric Discord channel ID for #gjc-approvals. Repo policy: no numeric
# Discord IDs in git — the deployed copy in ~/.gjc-relay/ carries the
# host-local default; here it must come from the environment.
ALERT_CHANNEL="${GJC_ALERT_CHANNEL:-}"
ENVFILE="$HOME/.clawhip/clawhip.env"
HOSTN="$(hostname 2>/dev/null || echo unknown)"
WHEN="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo now)"

logger -t gjc-relay-alert "gjc-relay entered failed state on ${HOSTN}; sending out-of-band alert" 2>/dev/null || true

# Plain-ASCII, no double-quotes/backslashes/newlines -> safe to inline in JSON below.
MSG="gjc-relay is DOWN (systemd failed state) on ${HOSTN} at ${WHEN}. clawhip notifications are being DLQ-buried (silent loss) until it recovers. Investigate: journalctl --user -u gjc-relay -n 80"

TOKEN=""
if [ -r "$ENVFILE" ]; then
  TOKEN="$(grep -E '^CLAWHIP_DISCORD_BOT_TOKEN=' "$ENVFILE" | head -1 | cut -d= -f2-)"
fi

if [ -n "$TOKEN" ] && [ -n "$ALERT_CHANNEL" ]; then
  curl -sS --max-time 10 -X POST \
    "https://discord.com/api/v10/channels/${ALERT_CHANNEL}/messages" \
    -H "Authorization: Bot ${TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"content\": \":warning: ${MSG}\"}" \
    >/dev/null 2>&1 \
    || logger -t gjc-relay-alert "direct-to-Discord alert curl failed" 2>/dev/null || true
else
  logger -t gjc-relay-alert "no CLAWHIP_DISCORD_BOT_TOKEN or GJC_ALERT_CHANNEL readable; alert limited to journald/mail" 2>/dev/null || true
fi

# Local mail fallback (fully independent of Discord). No-op if 'mail' absent.
if command -v mail >/dev/null 2>&1; then
  printf '%s\n' "$MSG" | mail -s "gjc-relay DOWN on ${HOSTN}" cvps 2>/dev/null || true
fi

exit 0
