#!/usr/bin/env bash
# 20-identity.sh — interactive identity checklist for the bot GitHub/git/SSH
# setup. Creates NOTHING on GitHub or Discord. Verifies:
#   1. `gh auth status` shows [operator].bot_login as ACTIVE
#   2. an ssh config alias `github.com-<bot_login>` exists
#   3. ~/.gitconfig has `user.useConfigOnly` + an includeIf block for the
#      bot's github tree (OFFERS — with a y/N prompt — to GENERATE the
#      satellite ~/.gitconfig-<bot_login> file; never edits ~/.gitconfig)
#   4. an `ssh -T git@github.com-<bot_login>` handshake succeeds
#
#   20-identity.sh [--check]   run every verification but skip the offer to
#                              generate the satellite gitconfig (report only)
set -uo pipefail

BOOTSTRAP_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd -- "$BOOTSTRAP_DIR/.." && pwd)"
# shellcheck source=../render/lib/toml2json.sh
source "$REPO_ROOT/render/lib/toml2json.sh"

FLEET_TOML="${FLEET_TOML:-$HOME/.config/gjc-fleet/fleet.toml}"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

[ -f "$FLEET_TOML" ] || { echo "20-identity.sh: config not found: $FLEET_TOML" >&2; exit 1; }
CFG_JSON="$(toml2json "$FLEET_TOML")"
cfg() { jq -r "$1 // empty" <<<"$CFG_JSON"; }

BOT_LOGIN="$(cfg '.operator.bot_login')"
BOT_NAME="$(cfg '.operator.bot_git_name')"
BOT_EMAIL="$(cfg '.operator.bot_git_email')"
[ -n "$BOT_LOGIN" ] || { echo "20-identity.sh: [operator].bot_login missing from $FLEET_TOML" >&2; exit 1; }

fail=0

echo "--- 1. gh auth status ($BOT_LOGIN) ---"
if command -v gh >/dev/null 2>&1; then
  # `gh auth status` has no --user filter; it lists every logged-in account
  # with its own "Active account: true/false" line. Find our account's block
  # and check that flag within it, rather than just the presence of a login.
  gh_status_out="$(gh auth status 2>&1)"
  gh_block="$(printf '%s\n' "$gh_status_out" | grep -A2 -E "account ${BOT_LOGIN}([[:space:]]|\$)")"
  if printf '%s\n' "$gh_block" | grep -q 'Active account: true'; then
    echo "ok: gh auth status shows $BOT_LOGIN active"
  else
    echo "MISSING: $BOT_LOGIN is not an active gh login. Run:"
    echo "  gh auth login --hostname github.com"
    echo "  # then, if another account is already active: gh auth switch --user $BOT_LOGIN"
    fail=1
  fi
else
  echo "MISSING: gh not on PATH — cannot verify"
  fail=1
fi

echo "--- 2. ssh alias github.com-$BOT_LOGIN ---"
if [ -f "$HOME/.ssh/config" ] && grep -q "^Host github.com-$BOT_LOGIN\$" "$HOME/.ssh/config"; then
  echo "ok: ssh alias present in ~/.ssh/config"
else
  echo "MISSING: no 'Host github.com-$BOT_LOGIN' block in ~/.ssh/config. Add:"
  printf '  Host github.com-%s\n    HostName github.com\n    User git\n    IdentityFile ~/.ssh/id_ed25519_%s\n    IdentitiesOnly yes\n' \
    "$BOT_LOGIN" "$BOT_LOGIN"
  echo "  # generate a key first if needed: ssh-keygen -t ed25519 -C \"$BOT_EMAIL\" -f ~/.ssh/id_ed25519_$BOT_LOGIN"
  fail=1
fi

echo "--- 3. ~/.gitconfig useConfigOnly + includeIf ---"
GITDIR="$HOME/github/$BOT_LOGIN/"
if [ -f "$HOME/.gitconfig" ] && grep -q '^[[:space:]]*useConfigOnly[[:space:]]*=[[:space:]]*true' "$HOME/.gitconfig"; then
  echo "ok: user.useConfigOnly is set"
else
  echo "MISSING: ~/.gitconfig has no [user] useConfigOnly = true"
  fail=1
fi
if [ -f "$HOME/.gitconfig" ] && grep -qF "gitdir:$GITDIR" "$HOME/.gitconfig"; then
  echo "ok: includeIf block for $GITDIR present"
else
  echo "MISSING: ~/.gitconfig has no includeIf block for $GITDIR"
  satellite="$HOME/.gitconfig-$BOT_LOGIN"
  if [ "$CHECK" -eq 1 ]; then
    echo "  (--check mode: would offer to generate $satellite)"
  else
    ans=""
    read -r -p "  Generate $satellite from [operator] values now? [y/N] " ans || true
    if [ "$ans" = "y" ]; then
      if [ -e "$satellite" ]; then
        echo "  refusing to overwrite existing $satellite"
      else
        printf '[user]\n\tname = %s\n\temail = %s\n' "$BOT_NAME" "$BOT_EMAIL" > "$satellite"
        echo "  wrote $satellite"
      fi
    fi
  fi
  echo "  Append this to ~/.gitconfig yourself (never auto-edited):"
  printf '  [includeIf "gitdir:%s"]\n\tpath = %s\n' "$GITDIR" "$satellite"
  fail=1
fi

echo "--- 4. ssh -T git@github.com-$BOT_LOGIN handshake ---"
if command -v ssh >/dev/null 2>&1; then
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -T "git@github.com-$BOT_LOGIN" 2>&1 || true)"
  if printf '%s' "$out" | grep -qi "successfully authenticated"; then
    echo "ok: ssh handshake succeeded ($BOT_LOGIN)"
  else
    echo "MISSING: ssh handshake did not report success. Output:"
    printf '  %s\n' "$out"
    fail=1
  fi
else
  echo "MISSING: ssh not on PATH — cannot verify"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "20-identity.sh: identity checklist OK"
else
  echo "20-identity.sh: unresolved items above" >&2
fi
exit "$fail"
