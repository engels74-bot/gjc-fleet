#!/usr/bin/env bash
# lib/userctl.sh — user-scope systemctl/journalctl wrappers for fleet scripts.
#
# The fleet runs entirely as USER units. From cron, hooks, or any non-login
# shell, `systemctl --user` fails without XDG_RUNTIME_DIR pointing at the
# user's runtime dir — these wrappers make that unconditional. Source this
# file, then call `userctl` / `userjournal` instead of bare systemctl/journalctl.
userctl() {
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" systemctl --user "$@"
}
userjournal() {
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" journalctl --user "$@"
}
