#!/usr/bin/env bash
# lint-routes.sh <rendered-clawhip-config.toml>
#
# Guards the clawhip route invariants that a careless edit (or a future
# "simplification") would silently break. These are load-bearing semantics
# documented in docs/30-clawhip.md and docs/45-fleet-config.md:
#
#   1. NO catch-all route (event = "*" / "github.*" / …) — one would double-post
#      and suppress per-repo monitor-channel fallbacks fleet-wide.
#   2. session.*-keyed routes MUST emit kind=agent.* labels (clawhip emits
#      canonical session.* events; an agent.*-keyed route never matches — the
#      route key and the user-facing taxonomy differ BY DESIGN).
#   3. Embed routes (session.*, github.issue-*, github.ci-*, github.pr-status-*)
#      must be CHANNEL-LESS: target resolution route.channel > event.channel >
#      default preserves each event's per-repo channel.
#   4. github.issue-opened needs BOTH its localfile spool route AND a discord
#      route — any matched route suppresses the monitor-channel fallback, so
#      dropping the discord route silently kills the human-visible notice.
#   5. At most one route per (event, sink) — duplicates double-post.
set -euo pipefail

cfg="${1:?usage: lint-routes.sh <clawhip-config.toml>}"
fail=0
err() { echo "lint-routes: FAIL: $*" >&2; fail=1; }

routes_json="$(python3 - "$cfg" <<'PY'
import tomllib, json, sys
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
print(json.dumps(data.get("routes", [])))
PY
)"

# 1. no catch-all
if jq -e '.[] | select(.event | test("\\*"))' <<<"$routes_json" >/dev/null; then
  err 'catch-all route (event contains "*") present'
fi

# 2. session.* routes emit kind=agent.*
while IFS=$'\t' read -r event template; do
  case "$template" in
    *"kind=agent."*) : ;;
    *) err "route event=$event must emit kind=agent.* (got: $template)" ;;
  esac
done < <(jq -r '.[] | select(.event | startswith("session.")) | [.event, (.template // "")] | @tsv' <<<"$routes_json")

# 3. embed routes are channel-less
while IFS=$'\t' read -r event channel; do
  [ -n "$channel" ] && err "route event=$event must be channel-less (route>event>default resolution)"
done < <(jq -r '.[] | select(
      (.event | startswith("session.")) or
      (.event | startswith("github.issue-")) or
      (.event | startswith("github.ci-")) or
      (.event == "github.pr-status-changed"))
    | [.event, (.channel // "")] | @tsv' <<<"$routes_json")

# 4. issue-opened has both localfile and discord routes
lf=$(jq '[.[] | select(.event == "github.issue-opened" and .sink == "localfile")] | length' <<<"$routes_json")
dc=$(jq '[.[] | select(.event == "github.issue-opened" and .sink == "discord")] | length' <<<"$routes_json")
[ "$lf" -eq 1 ] || err "github.issue-opened localfile spool route count = $lf (want 1)"
[ "$dc" -eq 1 ] || err "github.issue-opened discord route count = $dc (want 1)"

# 5. one route per (event, sink)
dups=$(jq -r 'group_by(.event + "/" + .sink) | .[] | select(length > 1) | .[0].event + "/" + .[0].sink' <<<"$routes_json")
[ -z "$dups" ] || err "duplicate routes for: $dups"

if [ "$fail" -eq 0 ]; then
  echo "lint-routes: OK ($(jq length <<<"$routes_json") routes checked)"
else
  exit 1
fi
