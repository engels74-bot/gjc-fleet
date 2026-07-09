#!/usr/bin/env bash
# review/review-checkout.sh — shared isolated-checkout helper for the review lane.
#
# The `ensure_checkout` body here is the CANONICAL per-repo checkout logic: it
# guarantees an isolated review clone under $REVIEW_ROOT/<repo> — own .git, reset to
# the default branch — and prints its path. BOTH review-run.sh and ci-fixer-run.sh
# source this file (one shared checkout path, no inline copy). It also arms prek hooks
# in the checkout (best-effort) so bot commits run pre-commit/commit-msg.
#
# Sourceable with NO side effects beyond guarded defaults + function defs.

# Double-source guard (idempotent; safe to source from multiple scripts).
[ -n "${_GJC_REVIEW_CHECKOUT_SH:-}" ] && return 0
_GJC_REVIEW_CHECKOUT_SH=1

# Config — env-overridable, identical defaults to review-run.sh. `:=` leaves any
# value a sourcing script already set (so a real launcher's config always wins).
: "${GJC_BOT_STATE:=$HOME/.gjc-bot}"
: "${GJC_BOT_GH_ROOT:=$HOME/github/engels74-bot/fleet}"
: "${GJC_BOT_GH_OWNER:=engels74}"
: "${GH_ROOT:=$GJC_BOT_GH_ROOT}"
: "${GH_OWNER:=$GJC_BOT_GH_OWNER}"
: "${REVIEW_ROOT:=${REVIEW_CHECKOUT_ROOT:-$GH_ROOT/review}}"
: "${LOG:=$GJC_BOT_STATE/review.log}"
: "${GIT:=${GIT_BIN:-/usr/bin/git}}"
: "${PREK:=${PREK_BIN:-$HOME/.local/bin/prek}}"

# Provide a log() only if the sourcing script has not already defined one, so we
# never clobber a caller's logger (and stay behaviour-identical when review-run.sh
# eventually sources this file).
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '%s [review-checkout] %s\n' "$(date -Is)" "$*" >>"$LOG"; }
fi

# Ensure an isolated review checkout for <repo> exists; print its path.
ensure_checkout() {
  local repo="$1"
  local dir="$REVIEW_ROOT/$repo"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$REVIEW_ROOT"
    "$GIT" clone --quiet "https://github.com/$GH_OWNER/$repo.git" "$dir" >>"$LOG" 2>&1 || { log "clone failed for $repo"; return 1; }
  fi
  # reset to a clean default state so the handler's Phase 0 starts fresh
  "$GIT" -C "$dir" fetch --quiet origin >>"$LOG" 2>&1 || true
  "$GIT" -C "$dir" checkout --quiet -f "$("$GIT" -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || echo main)" >>"$LOG" 2>&1 || true
  # Arm prek hooks in this checkout so bot commits go through pre-commit/commit-msg
  # hooks instead of silently skipping them. Best-effort only: a missing prek binary
  # or no prek/pre-commit config in the repo must never fail the checkout.
  if [ -f "$dir/prek.toml" ] || [ -f "$dir/.pre-commit-config.yaml" ]; then
    local prek_bin="$PREK"
    command -v "$prek_bin" >/dev/null 2>&1 || prek_bin="prek"
    if command -v "$prek_bin" >/dev/null 2>&1; then
      "$prek_bin" install -t pre-commit -t commit-msg -C "$dir" >>"$LOG" 2>&1 \
        || log "prek install failed for $repo (non-fatal)"
    else
      log "prek not found on PATH; skipping hook install for $repo (non-fatal)"
    fi
  fi
  printf '%s' "$dir"
}
