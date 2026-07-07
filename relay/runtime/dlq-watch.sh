#!/usr/bin/env bash
# gjc-dlq-watch — follows clawhip's journal for DLQ-bury events and fires an
# out-of-band alert. This is mechanism (b) of the Phase-2 alerting: it must NOT
# traverse clawhip or the relay (both may be down), so it curls Discord DIRECTLY.
# clawhip emits `clawhip dlq bury: {json}` to stderr (verified discord.rs:462-466)
# which systemd routes to the journal.
set -uo pipefail

# Numeric Discord channel ID for #gjc-approvals. Repo policy: no numeric
# Discord IDs in git — the deployed copy in ~/.gjc-relay/ carries the
# host-local default; here it must come from the environment.
ALERT_CHANNEL="${GJC_ALERT_CHANNEL:-}"
ENVFILE="$HOME/.clawhip/clawhip.env"
COOLDOWN="${GJC_DLQ_COOLDOWN:-300}"
last=0

notify() {
  local msg="$1"
  logger -t gjc-dlq-watch "$msg" 2>/dev/null || true
  local tok=""
  [ -r "$ENVFILE" ] && tok="$(grep -E '^CLAWHIP_DISCORD_BOT_TOKEN=' "$ENVFILE" | head -1 | cut -d= -f2-)"
  if [ -n "$tok" ] && [ -n "$ALERT_CHANNEL" ]; then
    curl -sS --max-time 10 -X POST "https://discord.com/api/v10/channels/${ALERT_CHANNEL}/messages" \
      -H "Authorization: Bot ${tok}" -H "Content-Type: application/json" \
      --data "{\"content\": \":rotating_light: ${msg}\"}" >/dev/null 2>&1 || true
  fi
}

# -n0: start at the tail (do not replay history). -o cat: message text only.
journalctl --user -u clawhip.service -f -n0 -o cat 2>/dev/null | while IFS= read -r line; do
  case "$line" in
    *"clawhip dlq bury:"*)
      now="${EPOCHSECONDS:-$(date +%s)}"
      if [ $((now - last)) -ge "$COOLDOWN" ]; then
        last="$now"
        notify "clawhip DLQ-buried a notification (silent, permanent loss). The gjc-relay delivery path likely failed on $(hostname). Check: systemctl --user status gjc-relay ; journalctl --user -u clawhip -n 80"
      fi
      ;;
  esac
done
