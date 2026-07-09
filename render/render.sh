#!/usr/bin/env bash
# render.sh — fleet.toml → live-config renderer for the gjc fleet.
#
#   render.sh render [--out DIR]   stage all render targets (never touches live files)
#   render.sh diff                 unified diff staging vs live; exit 1 on drift
#   render.sh apply [--yes]        per-target diff + confirm + atomic install (configs only;
#                                  unit INSTALLATION is bootstrap/50-units.sh's job)
#   render.sh apply --units        also install rendered units into ~/.config/systemd/user/
#   render.sh check [--config F]   CI gate: render from fleet.toml.example, validate syntax,
#                                  route invariants, kind coverage, no numeric IDs in repo
#   render.sh doctor               host checks for files the renderer deliberately does NOT
#                                  own (hermes config.yaml / cron jobs.json, secret custody)
#
# Config: ~/.config/gjc-fleet/fleet.toml (override: --config or $FLEET_TOML).
# The renderer replaces the historical dated .bak-* convention: review the diff,
# then apply. Existing .bak-* files on disk are forensic history — never deleted.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/toml2json.sh
source "$REPO_ROOT/render/lib/toml2json.sh"
# shellcheck source=lib/subst.sh
source "$REPO_ROOT/render/lib/subst.sh"

CONFIG="${FLEET_TOML:-$HOME/.config/gjc-fleet/fleet.toml}"
OUT=""
YES=0
UNITS=0
CMD="${1:-}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    --yes)    YES=1; shift ;;
    --units)  UNITS=1; shift ;;
    *) echo "render.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

CFG_JSON=""
load_config() {
  [ -f "$CONFIG" ] || { echo "render.sh: config not found: $CONFIG" >&2; exit 1; }
  CFG_JSON="$(toml2json "$CONFIG")"
}

cfg() { jq -r "$1 // empty" <<<"$CFG_JSON"; }

# list_or_sentinel <space-joined-list> — echo "-" (single hyphen) when the list is empty,
# else the list unchanged. An explicit `key = []` in TOML jq-joins to an EMPTY string, which
# would trip subst's empty-{{VAR}} guard; the "-" sentinel keeps the value non-empty while
# matching no real login in exact-token compares. Reused by future list knobs (the pattern
# also fits CI_FIXER_AUTHORS, AUTOMERGE_AUTHORS as they land).
list_or_sentinel() { [ -n "$1" ] && printf '%s' "$1" || printf '%s' "-"; }

# Resolve a channel NAME from [discord.channels] to its numeric ID.
ch() {
  local id
  id="$(jq -r --arg n "$1" '.discord.channels[$n] // empty' <<<"$CFG_JSON")"
  [ -n "$id" ] || { echo "render.sh: channel name '$1' missing from [discord.channels]" >&2; exit 1; }
  printf '%s' "$id"
}

setup_vars() {
  FLEET_HOME="$(cfg '.paths.home')"; FLEET_HOME="${FLEET_HOME:-$HOME}"
  BOT_LOGIN="$(cfg '.operator.bot_login')"
  [ -n "$BOT_LOGIN" ] || { echo "render.sh: [operator].bot_login is required" >&2; exit 1; }
  GH_ROOT="$(cfg '.paths.gh_root')"; GH_ROOT="${GH_ROOT:-$FLEET_HOME/github/$BOT_LOGIN/fleet}"
  FLEET_REPO="$(cfg '.paths.fleet_repo')"; FLEET_REPO="${FLEET_REPO:-$FLEET_HOME/github/$BOT_LOGIN/gjc-fleet}"
  RELAY_BIND="$(cfg '.relay.bind')"; RELAY_BIND="${RELAY_BIND:-127.0.0.1:25295}"
  # REVIEW lane coding engine: [review].engine, default "gjc" (claude = legacy).
  # Non-numeric, so it rides in the tracked gjc-bot.env template as {{REVIEW_ENGINE}}.
  REVIEW_ENGINE="$(cfg '.review.engine')"; REVIEW_ENGINE="${REVIEW_ENGINE:-gjc}"
  export GH_ROOT FLEET_REPO RELAY_BIND REVIEW_ENGINE
  # [review.policy] — one-review policy for automated-author PRs. Non-numeric knobs,
  # so they ride in the tracked gjc-bot.env template. AUTHORS is space-joined (the
  # detector splits on whitespace, glob-safely); jq defaults keep an absent block sane.
  # An ABSENT block gets the renovate/dependabot defaults (jq's // substitutes for null).
  # An EXPLICIT `automated_authors = []` is truthy, so // does NOT fire; it joins to "" and
  # the sentinel maps it to "-" (never empty => subst guard satisfied; the "-" token matches
  # no real login, so the policy lane is effectively disabled).
  REVIEW_AUTOMATED_AUTHORS="$(list_or_sentinel "$(jq -r '(.review.policy.automated_authors // ["renovate[bot]","dependabot[bot]"]) | join(" ")' <<<"$CFG_JSON")")"
  REVIEW_POLICY_MAX_HANDLER_RUNS="$(cfg '.review.policy.max_handler_runs')"; REVIEW_POLICY_MAX_HANDLER_RUNS="${REVIEW_POLICY_MAX_HANDLER_RUNS:-2}"
  # Force-push resilience (Workstream D): hard ceiling on policy re-arms per PR.
  REVIEW_POLICY_MAX_REARMS="$(cfg '.review.policy.max_rearms')"; REVIEW_POLICY_MAX_REARMS="${REVIEW_POLICY_MAX_REARMS:-2}"
  REVIEW_POLICY_DECISION_MODE="$(cfg '.review.policy.decision_mode')"; REVIEW_POLICY_DECISION_MODE="${REVIEW_POLICY_DECISION_MODE:-brain}"
  export REVIEW_AUTOMATED_AUTHORS REVIEW_POLICY_MAX_HANDLER_RUNS REVIEW_POLICY_MAX_REARMS REVIEW_POLICY_DECISION_MODE
  # [ci_fixer] — B-3 fix-until-green loop. Non-numeric-ID knobs, so they ride the tracked
  # gjc-bot.env template. DEFAULT OFF: an absent block (or enabled=false) renders
  # CI_FIXER_ENABLED=0; caps/backoff fall back to the shipped defaults. Rendered as "0"/"1"
  # (never empty) so subst never trips its empty-value guard.
  CI_FIXER_ENABLED=0; [ "$(cfg '.ci_fixer.enabled')" = "true" ] && CI_FIXER_ENABLED=1
  CI_FIXER_MAX_PER_SHA="$(cfg '.ci_fixer.max_per_sha')"; CI_FIXER_MAX_PER_SHA="${CI_FIXER_MAX_PER_SHA:-2}"
  CI_FIXER_MAX_PER_PR="$(cfg '.ci_fixer.max_per_pr')"; CI_FIXER_MAX_PER_PR="${CI_FIXER_MAX_PER_PR:-5}"
  CI_FIXER_BACKOFF_BASE_MINS="$(cfg '.ci_fixer.backoff_base_mins')"; CI_FIXER_BACKOFF_BASE_MINS="${CI_FIXER_BACKOFF_BASE_MINS:-10}"
  export CI_FIXER_ENABLED CI_FIXER_MAX_PER_SHA CI_FIXER_MAX_PER_PR CI_FIXER_BACKOFF_BASE_MINS
  CH_DEFAULT="$(ch default)"; export CH_DEFAULT
  CH_GJC_APPROVALS="$(ch gjc-approvals)"; export CH_GJC_APPROVALS
  CH_GJC_LAB="$(ch gjc-lab)"; export CH_GJC_LAB
  CH_GJC_EVENTS="$(ch gjc-events)"; export CH_GJC_EVENTS

  # v2 managed-path knobs. Preset (low|medium|high) or explicit "<t>/<w>s"; the relay
  # re-validates and panics on garbage, so a bad value never ships silently.
  RELAY_MANAGED_RATE="$(cfg '.relay.managed_rate')"; RELAY_MANAGED_RATE="${RELAY_MANAGED_RATE:-medium}"
  export RELAY_MANAGED_RATE
  # RELAY_WORKITEM_CHANNELS: comma-joined numeric IDs of repos opting in via
  # workitem_surface=true, plus any extra named channels in [relay].workitem_channels
  # (for non-repo canary surfaces such as gjc-lab). EMPTY when both selectors are
  # empty => feature fully OFF.
  local row chname cid wic=""
  add_workitem_cid() {
    local candidate="$1"
    case ",$wic," in
      *",$candidate,"*) ;;
      *) wic="${wic:+$wic,}$candidate" ;;
    esac
  }
  while IFS= read -r row; do
    [ "$(jq -r '.workitem_surface // false' <<<"$row")" = "true" ] || continue
    chname="$(jq -r '.channel' <<<"$row")"
    cid="$(ch "$chname")"
    add_workitem_cid "$cid"
  done < <(jq -c '.repos[]' <<<"$CFG_JSON")
  while IFS= read -r chname; do
    [ -n "$chname" ] || continue
    cid="$(ch "$chname")"
    add_workitem_cid "$cid"
  done < <(jq -r '(.relay.workitem_channels // [])[]' <<<"$CFG_JSON")
  RELAY_WORKITEM_CHANNELS="$wic"; export RELAY_WORKITEM_CHANNELS
}

build_monitor_blocks() {
  local blocks="" row name github chname pre id block
  while IFS= read -r row; do
    name="$(jq -r '.name' <<<"$row")"
    github="$(jq -r '.github' <<<"$row")"
    chname="$(jq -r '.channel' <<<"$row")"
    pre="$(jq -r '.pre_comment // ""' <<<"$row")"
    id="$(ch "$chname")"
    block="$(REPO_NAME="$name" REPO_GITHUB="$github" REPO_CHANNEL_ID="$id" \
             subst "$REPO_ROOT/render/templates/clawhip-monitor-repo.toml.tmpl")"
    [ -n "$pre" ] && block="$pre"$'\n'"$block"
    blocks="${blocks:+$blocks$'\n\n'}$block"
  done < <(jq -c '.repos[]' <<<"$CFG_JSON")
  printf '%s' "$blocks"
}

# target map: staged-name<TAB>live-path<TAB>mode(- = default)
target_map() {
  cat <<EOF
clawhip-config.toml	$FLEET_HOME/.clawhip/config.toml	-
relay.env	$FLEET_HOME/.gjc-relay/relay.env	600
design-system.json	$FLEET_HOME/.gjc-relay/design-system.json	-
EOF
  if [ -f "$REPO_ROOT/render/templates/gjc-bot.env.tmpl" ]; then
    echo "gjc-bot.env	$FLEET_HOME/.gjc-bot/gjc-bot.env	600"
  fi
}

# Units are installed to the systemd USER scope only. The historical /etc/systemd/system
# fallback was decommissioned — probing it produced misleading "live unit missing" drift.
unit_live_path() {
  local u="$1"
  printf '%s' "$HOME/.config/systemd/user/$u"
}

# lane_gate_var <unit-basename> — echo the env var that gates the unit's lane, or empty
# if the unit is always installed. Extend as more optional lanes ship (each lane's units
# map to its CI_FIXER_ENABLED-style gate: AUTOMERGE_ENABLED, etc.).
lane_gate_var() {
  case "$1" in
    ci-fixer.service|ci-fixer.timer) printf '%s' "CI_FIXER_ENABLED" ;;
    *) printf '%s' "" ;;
  esac
}

# lane_disabled <unit-basename> — 0 (true) when the unit's lane gate is present and its
# rendered value is "0"/empty; 1 otherwise (no gate => always enabled). Reads the gate
# var indirectly from the current render env (set by setup_vars).
lane_disabled() {
  local gate val
  gate="$(lane_gate_var "$1")"
  [ -n "$gate" ] || return 1
  val="${!gate:-}"
  [ "$val" = "0" ] || [ -z "$val" ]
}

do_render() {
  load_config; setup_vars
  OUT="${OUT:-$FLEET_HOME/.gjc-bot/render-out/$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$OUT/units/clawhip.service.d"
  MONITOR_BLOCKS="$(build_monitor_blocks)"; export MONITOR_BLOCKS
  HOME="$FLEET_HOME" subst "$REPO_ROOT/render/templates/clawhip-config.toml.tmpl" > "$OUT/clawhip-config.toml"
  HOME="$FLEET_HOME" subst "$REPO_ROOT/render/templates/relay.env.tmpl" > "$OUT/relay.env"
  # Append the v2 managed-path env (numeric IDs never live in the tracked template).
  # RELAY_MANAGED_RATE always; RELAY_WORKITEM_CHANNELS empty by default => feature OFF.
  {
    printf 'RELAY_MANAGED_RATE=%s\n' "$RELAY_MANAGED_RATE"
    printf 'RELAY_WORKITEM_CHANNELS=%s\n' "$RELAY_WORKITEM_CHANNELS"
    # Numeric lab channel ID for relay-heartbeat.sh (out-of-band liveness ping).
    # Kept OUT of the tracked template — appended here like the managed-path IDs above.
    printf 'GJC_LAB_CHANNEL=%s\n' "$CH_GJC_LAB"
  } >> "$OUT/relay.env"
  # Optional per-channel debounce pins: [relay.debounce] maps a channel NAME -> seconds,
  # rendered as RELAY_DEBOUNCE_SECS__<numeric-id>. Absent by default => no lines emitted.
  local dname dsecs dcid
  while IFS=$'\t' read -r dname dsecs; do
    [ -n "$dname" ] || continue
    dcid="$(ch "$dname")"
    printf 'RELAY_DEBOUNCE_SECS__%s=%s\n' "$dcid" "$dsecs" >> "$OUT/relay.env"
  done < <(jq -r '(.relay.debounce // {}) | to_entries[] | [.key, (.value|tostring)] | @tsv' <<<"$CFG_JSON")
  if [ -f "$REPO_ROOT/render/templates/gjc-bot.env.tmpl" ]; then
    HOME="$FLEET_HOME" subst "$REPO_ROOT/render/templates/gjc-bot.env.tmpl" > "$OUT/gjc-bot.env"
  fi
  cp "$REPO_ROOT/relay/runtime/design-system.json" "$OUT/design-system.json"
  local u base
  for u in "$REPO_ROOT"/systemd/*.service "$REPO_ROOT"/systemd/*.timer "$REPO_ROOT"/systemd/*.path; do
    [ -e "$u" ] || continue
    base="$(basename "$u")"
    HOME="$FLEET_HOME" subst "$u" > "$OUT/units/$base"
  done
  HOME="$FLEET_HOME" subst "$REPO_ROOT/systemd/clawhip.service.d/10-gjc-relay.conf" \
    > "$OUT/units/clawhip.service.d/10-gjc-relay.conf"
  echo "$OUT"
}

resolve_staging() {
  load_config; setup_vars
  if [ -z "$OUT" ]; then
    OUT="$(do_render)"
  fi
}

do_diff() {
  resolve_staging
  local drift=0 staged live mode u
  while IFS=$'\t' read -r staged live mode; do
    [ -f "$OUT/$staged" ] || continue
    if ! diff -u --label "live:$live" --label "staged:$staged" "$live" "$OUT/$staged"; then drift=1; fi
  done < <(target_map)
  for u in "$OUT"/units/*.service "$OUT"/units/*.timer "$OUT"/units/*.path "$OUT"/units/clawhip.service.d/*.conf; do
    [ -e "$u" ] || continue
    local base rel
    if [[ "$u" == */clawhip.service.d/* ]]; then base="clawhip.service.d/$(basename "$u")"; else base="$(basename "$u")"; fi
    rel="$(unit_live_path "$base")"
    if [ ! -f "$rel" ]; then
      # A unit whose lane is disabled is deliberately NOT installed live — that is
      # expected state, not drift. Report it as a NOTE and move on.
      if lane_disabled "$(basename "$base")"; then
        echo "diff: NOTE: $(basename "$base") belongs to disabled lane ($(lane_gate_var "$(basename "$base")")=0) — not installed"
        continue
      fi
      echo "diff: live unit missing: $rel"; drift=1; continue
    fi
    if ! diff -u --label "live:$rel" --label "staged:units/$base" "$rel" "$OUT/units/$base"; then drift=1; fi
  done
  if [ "$drift" -eq 0 ]; then echo "render diff: zero drift"; else echo "render diff: DRIFT (see above)"; fi
  return "$drift"
}

install_file() {  # staged live mode
  local staged="$1" live="$2" mode="$3" tmp
  tmp="$(mktemp "$(dirname "$live")/.render.XXXXXX")"
  cp "$staged" "$tmp"
  [ "$mode" != "-" ] && chmod "$mode" "$tmp"
  mv "$tmp" "$live"
  echo "applied: $live"
}

do_apply() {
  resolve_staging
  local staged live mode
  while IFS=$'\t' read -r staged live mode; do
    [ -f "$OUT/$staged" ] || continue
    if diff -q "$live" "$OUT/$staged" >/dev/null 2>&1; then continue; fi
    diff -u --label "live:$live" --label "staged:$staged" "$live" "$OUT/$staged" || true
    if [ "$YES" -ne 1 ]; then
      read -r -p "apply $staged -> $live ? [y/N] " a
      [ "$a" = "y" ] || { echo "skipped: $live"; continue; }
    fi
    install_file "$OUT/$staged" "$live" "$mode"
  done < <(target_map)
  if [ "$UNITS" -eq 1 ]; then
    mkdir -p "$HOME/.config/systemd/user/clawhip.service.d"
    local u base dest
    for u in "$OUT"/units/*.service "$OUT"/units/*.timer "$OUT"/units/*.path; do
      [ -e "$u" ] || continue
      base="$(basename "$u")"
      if lane_disabled "$base"; then
        echo "skipped unit (disabled lane $(lane_gate_var "$base")=0): $base"
        continue
      fi
      dest="$HOME/.config/systemd/user/$base"
      diff -q "$dest" "$u" >/dev/null 2>&1 || install_file "$u" "$dest" "-"
    done
    install_file "$OUT/units/clawhip.service.d/10-gjc-relay.conf" \
      "$HOME/.config/systemd/user/clawhip.service.d/10-gjc-relay.conf" "-"
    echo "units installed to ~/.config/systemd/user (run: systemctl --user daemon-reload)"
  fi
}

do_check() {
  # CI gate — renders from the committed example unless --config was given.
  CONFIG="${CONFIG_OVERRIDE:-$REPO_ROOT/fleet.toml.example}"
  OUT="$(mktemp -d)"
  trap 'rm -rf "$OUT"' EXIT
  load_config; setup_vars
  do_render >/dev/null
  python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$OUT/clawhip-config.toml" \
    && echo "check: rendered clawhip config parses as TOML"
  bash "$REPO_ROOT/render/checks/lint-routes.sh" "$OUT/clawhip-config.toml"
  RELAY_DESIGN_SYSTEM="$REPO_ROOT/relay/runtime/design-system.json" \
    CLAWHIP_CONFIG="$OUT/clawhip-config.toml" \
    GJC_BOT_SCRIPTS="$REPO_ROOT/pipeline" \
    bash "$REPO_ROOT/relay/runtime/check-kind-coverage.sh"
  grep -E '^[A-Za-z_]+=' "$OUT/relay.env" >/dev/null && echo "check: relay.env shape ok"
  # Discord-scale numeric IDs are banned repo-wide. The ONLY allowed shape is the
  # zero-padded placeholder used by fleet.toml.example (000…00N) — a real ID pasted
  # anywhere, example included, still fails.
  if git -C "$REPO_ROOT" grep -nE '[0-9]{15,}' -- ':!relay/Cargo.lock' | grep -vE '0{14,}[0-9]' >/dev/null 2>&1; then
    echo "check: FAIL — numeric Discord-scale IDs found in repo:" >&2
    git -C "$REPO_ROOT" grep -nE '[0-9]{15,}' -- ':!relay/Cargo.lock' | grep -vE '0{14,}[0-9]' >&2
    exit 1
  fi
  echo "check: no numeric IDs in repo (zero-padded example placeholders allowed)"
  echo "check: ALL OK"
}

do_doctor() {
  load_config; setup_vars
  local warn=0
  w() { echo "doctor: WARN: $*"; warn=1; }
  local hcy="$FLEET_HOME/.hermes/config.yaml"
  if [ -f "$hcy" ]; then
    grep -qF "command: $FLEET_HOME/.bun/bin/gjc" "$hcy" || w "hermes config.yaml: gjc mcp command line differs (expect: command: $FLEET_HOME/.bun/bin/gjc)"
    grep -qF "GJC_COORDINATOR_MCP_WORKDIR_ROOTS: $GH_ROOT" "$hcy" || w "hermes config.yaml: workdir roots line differs (expect: GJC_COORDINATOR_MCP_WORKDIR_ROOTS: $GH_ROOT)"
    grep -qF "cwd: $GH_ROOT" "$hcy" || w "hermes config.yaml: terminal cwd differs (expect: cwd: $GH_ROOT)"
    [ "$(grep -c '^terminal:' "$hcy")" -le 1 ] || w "hermes config.yaml: duplicate top-level 'terminal:' block (YAML last-key-wins — the fleet-path block must win)"
  fi
  local jobs="$FLEET_HOME/.hermes/cron/jobs.json"
  if [ -f "$jobs" ]; then
    while IFS= read -r wd; do
      [ -d "$wd" ] || w "hermes cron job workdir does not exist: $wd"
    done < <(jq -r '.jobs[]?.workdir // empty' "$jobs" 2>/dev/null || jq -r '.[]?.workdir // empty' "$jobs" 2>/dev/null)
  fi
  local mcp="$FLEET_HOME/.gjc/agent/mcp.json"
  if [ -f "$mcp" ]; then
    [ "$(stat -c %a "$mcp")" = "600" ] || w "mcp.json is $(stat -c %a "$mcp"), want 600 (holds a literal API key)"
  fi
  local s
  for s in alert.sh dlq-watch.sh check-kind-coverage.sh; do
    if [ -f "$FLEET_HOME/.gjc-relay/$s" ] && ! diff -q "$REPO_ROOT/relay/runtime/$s" "$FLEET_HOME/.gjc-relay/$s" >/dev/null; then
      w "deployed ~/.gjc-relay/$s drifts from relay/runtime/$s"
    fi
  done
  local cenv="$FLEET_HOME/.clawhip/clawhip.env"
  if [ -f "$cenv" ]; then
    local k
    for k in CLAWHIP_GITHUB_TOKEN CLAWHIP_DISCORD_BOT_TOKEN CLAWHIP_DISCORD_API_BASE; do
      grep -q "^$k=" "$cenv" || w "clawhip.env missing key: $k"
    done
  fi
  [ "$warn" -eq 0 ] && echo "doctor: all clear" || echo "doctor: warnings above"
  return 0
}

case "$CMD" in
  render) do_render ;;
  diff)   do_diff ;;
  apply)  do_apply ;;
  check)  CONFIG_OVERRIDE="${FLEET_TOML:-}"; do_check ;;
  doctor) do_doctor ;;
  *) grep '^#' "$0" | head -20; exit 2 ;;
esac
