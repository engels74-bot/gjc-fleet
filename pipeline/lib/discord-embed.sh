#!/usr/bin/env bash
# lib/discord-embed.sh — shared GJCEMBED1 envelope emitter for gjc-bot scripts.
#
# Source this file, then call `discord_embed`. It builds the GJCEMBED1 delimiter
# envelope and sends it via `clawhip send`, so the message flows through gjc-relay
# and renders as a design-system embed (single source of truth for colour/emoji/
# layout: ~/.gjc-relay/design-system.json — the SAME file the clawhip route
# templates use, so a given kind looks identical whether it came from clawhip or
# from a gjc-bot script).
#
# Usage:
#   discord_embed --channel <id> --kind <kind> [--repo R] [--status S] \
#                 [--actor A] [--branch B] [--url U] --message "free-form text"
#
# Protocol safety (mirrors the clawhip templates):
#   * Free-form text (--message) goes ONLY in the post-`::` tail — quotes,
#     backslashes and newlines are safe there; the relay owns all JSON construction.
#   * Head slots take space-free constrained-charset tokens only; this helper
#     SANITISES head values to [A-Za-z0-9._:/-] and omits any that become empty,
#     so a stray space or quote can never corrupt the envelope.
#   * `clawhip send` uses kind=custom -> compact rendering, which returns the
#     message byte-for-byte (render/default.rs). Do NOT add a config route for
#     kind=custom (a template would replace the message) and do NOT let it resolve
#     to `alert` format (which prepends an emoji and would break the leading prefix).

_GJC_CLAWHIP="${CLAWHIP_BIN:-/home/cvps/.cargo/bin/clawhip}"

# Keep only characters allowed in an envelope head slot; strips spaces and anything
# that could break tokenisation (so a value is never able to corrupt the envelope).
_gjc_clean_head() { printf '%s' "${1-}" | tr -cd 'A-Za-z0-9._:/-'; }
# URLs additionally keep query/fragment characters (still whitespace-free, so the head
# stays tokenisable) — matches the relay's URL-tolerant head validation.
_gjc_clean_url()  { printf '%s' "${1-}" | tr -cd 'A-Za-z0-9._:/?=&#%~+,@-'; }

discord_embed() {
  # note: `estatus` not `status` — `status` is a read-only special var in zsh.
  local channel="" kind="default" repo="" estatus="" actor="" branch="" url="" message=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --channel) channel="${2-}"; shift 2 ;;
      --kind)    kind="${2-}"; shift 2 ;;
      --repo)    repo="${2-}"; shift 2 ;;
      --status)  estatus="${2-}"; shift 2 ;;
      --actor)   actor="${2-}"; shift 2 ;;
      --branch)  branch="${2-}"; shift 2 ;;
      --url)     url="${2-}"; shift 2 ;;
      --message) message="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$channel" ] || return 1

  local head v
  head="GJCEMBED1 kind=$(_gjc_clean_head "$kind")"
  v="$(_gjc_clean_head "$repo")";    [ -n "$v" ] && head="$head repo=$v"
  v="$(_gjc_clean_head "$estatus")"; [ -n "$v" ] && head="$head status=$v"
  v="$(_gjc_clean_head "$actor")";  [ -n "$v" ] && head="$head actor=$v"
  v="$(_gjc_clean_head "$branch")"; [ -n "$v" ] && head="$head branch=$v"
  v="$(_gjc_clean_url "$url")";      [ -n "$v" ] && head="$head url=$v"

  "$_GJC_CLAWHIP" send --channel "$channel" --message "$head :: $message" >/dev/null 2>&1 || return 1
}
