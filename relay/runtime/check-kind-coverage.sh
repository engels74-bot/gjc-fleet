#!/usr/bin/env bash
# Deploy-time gate (plan Phase 1 check 8 / acceptance #5):
# every `kind=` used by a clawhip route template OR by the gjc-bot discord-embed.sh
# helper MUST have an entry in design-system.json — fail loudly here, not silently
# grey at runtime.
set -uo pipefail
DS="${RELAY_DESIGN_SYSTEM:-$HOME/.gjc-relay/design-system.json}"
CFG="${CLAWHIP_CONFIG:-$HOME/.clawhip/config.toml}"
SCRIPTS_DIR="${GJC_BOT_SCRIPTS:-$HOME/github/engels74-bot/gjc-fleet/pipeline}"

# Collect every RELAY kind actually emitted:
#   * config route templates:            kind=<k>   (NOT the route `event=` names,
#                                         which are session.*/github.* wire kinds,
#                                         mapped to relay kinds by the template's kind=)
#   * gjc-bot discord_embed calls:      --kind <k>
#   * gjc-bot notify() positional kind: notify <k> ...  (issue-spool-adapter.sh)
tmp="$(mktemp)"
{
  [ -f "$CFG" ] && grep -hoE 'kind=[A-Za-z0-9._:/-]+' "$CFG" 2>/dev/null | sed 's/^kind=//'
  if [ -d "$SCRIPTS_DIR" ]; then
    # --include='*.sh' so timestamped .bak backups are never scanned.
    grep -rhoE --include='*.sh' -- '--kind[[:space:]]+[A-Za-z0-9._:/-]+' "$SCRIPTS_DIR" 2>/dev/null | sed -E 's/^--kind[[:space:]]+//'
    grep -rhoE --include='*.sh' '\bnotify[[:space:]]+[a-z][A-Za-z0-9._-]+' "$SCRIPTS_DIR" 2>/dev/null | sed -E 's/^notify[[:space:]]+//'
  fi
} | grep -vE '^(default)$' | grep -E '\.[a-z]' | sort -u > "$tmp"

python3 - "$DS" "$tmp" <<'PY'
import json, sys
ds = json.load(open(sys.argv[1]))
kinds = set(ds.get("kinds", {}))
referenced = [l.strip() for l in open(sys.argv[2]) if l.strip()]
missing = [k for k in referenced if k not in kinds]
for k in missing:
    print(f"MISSING: kind '{k}' referenced but absent from design-system.json")
print(f"kind-coverage: {len(referenced)} referenced, {len(missing)} missing "
      f"(design-system defines {len(kinds)} kinds incl. default)")
sys.exit(1 if missing else 0)
PY
rc=$?
rm -f "$tmp"
exit $rc
