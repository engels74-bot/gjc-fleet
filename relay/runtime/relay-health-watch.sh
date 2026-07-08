#!/usr/bin/env bash
# gjc-relay-health-watch — continuous liveness alarm for gjc-relay's delivery
# pipeline. Run every 2 minutes by gjc-relay-health-watch.timer.
#
# CRITICAL DESIGN CONSTRAINT (same as alert.sh/dlq-watch.sh): this alert MUST NOT
# traverse clawhip or the relay, because those are exactly what may be stuck. It
# curls Discord DIRECTLY at https://discord.com (NOT the relay) into #gjc-approvals.
# The bot token is read from clawhip.env and is NEVER printed/echoed.
#
# Alarms when EITHER:
#   (a) the oldest file in <RELAY_STATE_DIR>/queue/ is older than
#       RELAY_DELIVERY_MAX_AGE_SECS (a queued op has been sitting undelivered
#       past the relay's own staleness threshold), or
#   (b) <RELAY_STATE_DIR>/flush.alive has gone stale for more than 90 seconds
#       (the flush thread that touches it looks dead or stuck).
#
# FALSE-ALARM GUARD (feature-off / fresh-host safety): an empty or missing
# queue/ dir means there is nothing queued, so nothing can be stuck delivering
# -> (a) never fires. A flush.alive that has never been created means the relay
# has never completed a flush cycle yet (fresh host, or a relay build that
# predates the liveness marker) -> there is no prior "alive" state to have gone
# stale, so (b) never fires either. Only a marker that WAS written at least once
# and is now stale trips (b). No queued work + no state dir is normal, not broken.
#
# ALARM-STORM / DEDUP DESIGN: this is invoked every 2 minutes by its timer and
# evaluates current state fresh each run; at most one alert per condition per
# invocation. There is no additional cooldown counter here (unlike dlq-watch.sh's
# event-driven COOLDOWN) — the timer cadence itself IS the dedup. A genuinely
# stuck pipeline re-alerts every 2 minutes for as long as it stays stuck, which is
# the desired "still down" signal for an ongoing outage rather than alarm spam
# (a single alert per fixed interval, not per underlying byte/event).
set -uo pipefail

# Numeric Discord channel ID for #gjc-approvals. Repo policy: no numeric
# Discord IDs in git — the deployed copy in ~/.gjc-relay/ carries the
# host-local default; here it must come from the environment.
ALERT_CHANNEL="${GJC_ALERT_CHANNEL:-}"
ENVFILE="$HOME/.clawhip/clawhip.env"
STATE_DIR="${RELAY_STATE_DIR:-$HOME/.gjc-relay/state}"
MAX_AGE="${RELAY_DELIVERY_MAX_AGE_SECS:-600}"
FLUSH_STALE_SECS=90
HOSTN="$(hostname 2>/dev/null || echo unknown)"

notify() {
  local msg="$1"
  logger -t gjc-relay-health-watch "$msg" 2>/dev/null || true
  local tok=""
  [ -r "$ENVFILE" ] && tok="$(grep -E '^CLAWHIP_DISCORD_BOT_TOKEN=' "$ENVFILE" | head -1 | cut -d= -f2-)"
  if [ -n "$tok" ] && [ -n "$ALERT_CHANNEL" ]; then
    curl -sS --max-time 10 -X POST "https://discord.com/api/v10/channels/${ALERT_CHANNEL}/messages" \
      -H "Authorization: Bot ${tok}" -H "Content-Type: application/json" \
      --data "{\"content\": \":rotating_light: ${msg}\"}" >/dev/null 2>&1 || true
  fi
}

now="${EPOCHSECONDS:-$(date +%s)}"

# --- (a) oldest queued op older than RELAY_DELIVERY_MAX_AGE_SECS ---
queue_dir="$STATE_DIR/queue"
if [ -d "$queue_dir" ]; then
  oldest_mtime=""
  while IFS= read -r -d '' f; do
    m="$(stat -c '%Y' "$f" 2>/dev/null || true)"
    [ -z "$m" ] && continue
    if [ -z "$oldest_mtime" ] || [ "$m" -lt "$oldest_mtime" ]; then
      oldest_mtime="$m"
    fi
  done < <(find "$queue_dir" -maxdepth 1 -type f -print0 2>/dev/null)

  if [ -n "$oldest_mtime" ]; then
    age=$((now - oldest_mtime))
    if [ "$age" -gt "$MAX_AGE" ]; then
      notify "gjc-relay delivery queue looks STUCK on ${HOSTN}: oldest queued op is ${age}s old (threshold ${MAX_AGE}s). Check: systemctl --user status gjc-relay ; ls -la ${queue_dir}"
    fi
  fi
fi

# --- (b) flush.alive stale >90s, only meaningful once it has existed ---
alive_marker="$STATE_DIR/flush.alive"
if [ -f "$alive_marker" ]; then
  alive_mtime="$(stat -c '%Y' "$alive_marker" 2>/dev/null || true)"
  if [ -n "$alive_mtime" ]; then
    stale=$((now - alive_mtime))
    if [ "$stale" -gt "$FLUSH_STALE_SECS" ]; then
      notify "gjc-relay flush thread looks DEAD/STUCK on ${HOSTN}: flush.alive is ${stale}s stale (threshold ${FLUSH_STALE_SECS}s). Check: systemctl --user status gjc-relay ; journalctl --user -u gjc-relay -n 80"
    fi
  fi
fi

exit 0
