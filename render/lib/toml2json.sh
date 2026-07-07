#!/usr/bin/env bash
# toml2json <file> — TOML → JSON on stdout, via the Python 3.11+ stdlib (tomllib).
# The only non-bash/jq dependency in the renderer; deliberately one line of Python
# because pure-bash TOML parsing is a correctness hazard (nested tables, arrays
# of tables, string escaping).
set -euo pipefail
toml2json() {
  python3 -c 'import tomllib, json, sys; print(json.dumps(tomllib.load(open(sys.argv[1], "rb"))))' "$1"
}
