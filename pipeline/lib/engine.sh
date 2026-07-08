#!/usr/bin/env bash
# lib/engine.sh — reusable coding-engine dispatch for gjc-bot pipeline scripts.
#
# One entrypoint: `engine_run <engine> <filled_prompt_path> <timeout_secs>`. It runs
# ONE coding-work invocation under a hard timeout, dispatching on the engine name so
# a caller never hardcodes a specific CLI:
#
#   gjc    — the fleet's coding engine (DEFAULT). Runs `gjc -p --no-pty "@<prompt>"`,
#            inheriting gjc's own configured backend/models. Mirrors the proven
#            invocation in pipeline/run/gjc-run.sh (`_exec`), which reads the prompt
#            file via the `@path` argument.
#   claude — LEGACY fallback. Headless `claude -p --dangerously-skip-permissions
#            --model "$MODEL_PRIMARY"`, reading the prompt on stdin. MODEL_PRIMARY is
#            referenced ONLY on this path.
#
# The caller is responsible for cwd: run engine_run inside a `( cd "$dir" && ... )`
# subshell when the engine must execute in a specific checkout (both engines read the
# prompt by absolute path, so cwd only affects the tools they invoke).
#
# Binaries are env-overridable with defaults identical to the pipeline scripts
# (TIMEOUT_BIN / GJC_REAL_BIN / CLAUDE_BIN), or a value the sourcing script already
# exported (TIMEOUT / GJC_REAL / CLAUDE) — resolved lazily inside the function so
# sourcing this file has NO side effects beyond defining `engine_run`.
#
# Shared by pipeline/review/review-run.sh (REVIEW lane) and — by design — the future
# pipeline/ci/ci-fixer-run.sh (B-3): keep it self-contained.
#
# Sourceable with NO side effects: a double-source guard plus a single function
# definition. NEVER interpolates tokens or filesystem paths into output.

# Double-source guard (idempotent; safe to source from multiple libs/scripts).
[ -n "${_GJC_ENGINE_SH:-}" ] && return 0
_GJC_ENGINE_SH=1

# engine_run <engine> <filled_prompt_path> <timeout_secs>
#   Returns the engine's own exit status (124 on timeout), or 64 (EX_USAGE) for a
#   missing argument / unknown engine.
engine_run() {
  local engine="${1:-}" filled="${2:-}" timeout_secs="${3:-}"
  if [ -z "$engine" ] || [ -z "$filled" ] || [ -z "$timeout_secs" ]; then
    printf 'engine_run: usage: engine_run <gjc|claude> <filled_prompt_path> <timeout_secs>\n' >&2
    return 64
  fi

  local timeout_bin gjc_bin claude_bin
  timeout_bin="${TIMEOUT:-${TIMEOUT_BIN:-/usr/bin/timeout}}"

  case "$engine" in
    gjc)
      gjc_bin="${GJC_REAL:-${GJC_REAL_BIN:-$HOME/.bun/bin/gjc}}"
      "$timeout_bin" "$timeout_secs" "$gjc_bin" -p --no-pty "@$filled"
      ;;
    claude)
      claude_bin="${CLAUDE:-${CLAUDE_BIN:-$HOME/.local/bin/claude}}"
      "$timeout_bin" "$timeout_secs" "$claude_bin" -p --dangerously-skip-permissions \
        --model "${MODEL_PRIMARY:-opus}" < "$filled"
      ;;
    *)
      printf 'engine_run: unknown engine %q (want gjc|claude)\n' "$engine" >&2
      return 64
      ;;
  esac
}
