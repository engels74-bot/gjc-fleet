#!/usr/bin/env bash
# 00-prereqs.sh — CHECK-ONLY prerequisite audit for the gjc-fleet bootstrap.
#
# Never installs anything. Reports each required tool's presence + version,
# and on any miss prints one-line install hints (apt/brew/rustup/bun
# one-liners, as comments) plus a non-zero exit, so bootstrap.sh stops here
# first. Safe to re-run any time — it only reads the host.
#
#   00-prereqs.sh [--check]   this script is always check-only; --check is
#                              accepted for orchestrator uniformity (no-op).
set -uo pipefail

missing=0

report() {  # <label> <ok:0|1> <detail>
  local label="$1" ok="$2" detail="$3"
  if [ "$ok" -eq 0 ]; then
    printf 'ok:      %-10s %s\n' "$label" "$detail"
  else
    printf 'MISSING: %-10s %s\n' "$label" "$detail"
    missing=1
  fi
}

check_bin() {  # <label> <bin> <version-args...>
  local label="$1" bin="$2" v
  shift 2
  if command -v "$bin" >/dev/null 2>&1; then
    v="$("$bin" "$@" 2>&1 | head -1)"
    report "$label" 0 "$v"
  else
    report "$label" 1 "not on PATH"
  fi
}

check_bin git   git   --version
check_bin gh    gh    --version
check_bin jq    jq    --version
check_bin curl  curl  --version
check_bin tmux  tmux  -V
check_bin rustc rustc --version
check_bin cargo cargo --version
check_bin bun   bun   --version
check_bin uv    uv    --version

if command -v python3 >/dev/null 2>&1; then
  py_ver="$(python3 --version 2>&1)"
  if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    if python3 -c 'import tomllib' 2>/dev/null; then
      report python3 0 "$py_ver (tomllib ok)"
    else
      report python3 1 "$py_ver but tomllib import failed"
    fi
  else
    report python3 1 "$py_ver (need >= 3.11 for tomllib)"
  fi
else
  report python3 1 "not on PATH"
fi

if [ "$missing" -ne 0 ]; then
  cat >&2 <<'HINTS'

One-line install hints for anything missing above:
  # git/jq/curl/tmux (Debian/Ubuntu): sudo apt install git jq curl tmux
  # git/jq/curl/tmux (macOS):         brew install git jq curl tmux
  # gh (GitHub CLI):                  brew install gh   # or see https://cli.github.com
  # rustc + cargo:                    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  # bun:                              curl -fsSL https://bun.sh/install | bash
  # uv:                               curl -LsSf https://astral.sh/uv/install.sh | sh
  # python3 >= 3.11:                  brew install python@3.11   # or: pyenv install 3.11
HINTS
  echo "00-prereqs.sh: missing prerequisites listed above." >&2
  exit 1
fi

echo "00-prereqs.sh: all prerequisites present."
