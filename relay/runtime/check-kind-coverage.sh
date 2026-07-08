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
kinds_map = ds.get("kinds", {})
kinds = set(kinds_map)
referenced = [l.strip() for l in open(sys.argv[2]) if l.strip()]
errors = []

# 1. Coverage: every referenced kind must exist.
missing = [k for k in referenced if k not in kinds]
for k in missing:
    errors.append(f"MISSING: kind '{k}' referenced but absent from design-system.json")

# 2. Managed surface: every MANAGED kind (the policy.rs compiled_default set that is
#    NOT Unmanaged) must carry a valid `surface`. Vocabulary + normalisation mirror
#    relay/src/policy.rs surface_from_str (case/separator-insensitive).
MANAGED = {
    "github.issue-opened", "github.issue-commented", "github.pr-status-changed",
    "workitem.dispatched", "github.ci-started", "github.ci-passed",
    "github.ci-cancelled", "github.ci-failed", "workitem.merge-verdict",
}
VALID_SURFACES = {"newmessage", "editsummary", "threadpost",
                  "editandthread", "unmanaged", "drop"}
def norm(s):
    return "".join(c for c in s.strip().lower() if c not in "_- ")
for k in sorted(MANAGED):
    entry = kinds_map.get(k)
    if entry is None:
        errors.append(f"MANAGED: kind '{k}' is missing from design-system.json")
        continue
    surf = entry.get("surface")
    if not isinstance(surf, str) or not surf.strip():
        errors.append(f"MANAGED: kind '{k}' has no `surface` (managed kinds require one)")
    elif norm(surf) not in VALID_SURFACES:
        errors.append(f"MANAGED: kind '{k}' surface '{surf}' is not a valid policy surface")

# 3. Work-item section: must parse as an object with a non-empty ordered `facets`
#    list, and every `facet` a kind references must be one of those ids.
wi = ds.get("workitem")
if not isinstance(wi, dict):
    errors.append("WORKITEM: `workitem` section is missing or not an object")
    facets = set()
else:
    fl = wi.get("facets")
    if not isinstance(fl, list) or not fl or not all(isinstance(f, str) for f in fl):
        errors.append("WORKITEM: `workitem.facets` must be a non-empty list of strings")
        facets = set()
    else:
        facets = set(fl)
for k, entry in kinds_map.items():
    if isinstance(entry, dict) and "facet" in entry:
        f = entry.get("facet")
        if f not in facets:
            errors.append(f"WORKITEM: kind '{k}' facet '{f}' is not in workitem.facets")

for e in errors:
    print(e)
print(f"kind-coverage: {len(referenced)} referenced, {len(missing)} missing "
      f"(design-system defines {len(kinds)} kinds incl. default); "
      f"managed-surface + workitem checks: {'OK' if not errors else 'FAIL'}")
sys.exit(1 if errors else 0)
PY
rc=$?
rm -f "$tmp"
exit $rc
