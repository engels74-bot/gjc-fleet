#!/usr/bin/env bash
# subst <template-file> — replace {{VAR}} placeholders from the environment.
# awk-based so replacement values are never re-interpreted (no sed-escape traps,
# no envsubst $-collision with shell vars inside templates). A placeholder whose
# variable is unset or empty is an ERROR: templates must never render half-filled.
set -euo pipefail
subst() {
  awk '
    {
      line = $0
      out = ""
      while (match(line, /\{\{[A-Z0-9_]+\}\}/)) {
        var = substr(line, RSTART + 2, RLENGTH - 4)
        val = ENVIRON[var]
        if (val == "") {
          printf "subst: unset or empty template variable {{%s}}\n", var > "/dev/stderr"
          exit 1
        }
        out = out substr(line, 1, RSTART - 1) val
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  ' "$1"
}
