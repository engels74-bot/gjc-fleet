#!/usr/bin/env bash
# bootstrap.sh — orchestrator for the gjc-fleet bootstrap sequence.
#
# Runs 00-prereqs.sh through 50-units.sh in numeric order on a fresh (or
# drifted) host, stopping at the first failure with a pointer to the failing
# step. `--check` runs every step in dry mode (each step reports what it
# would do without changing anything on disk/host).
#
#   bootstrap.sh            run the full sequence, applying changes
#   bootstrap.sh --check    dry run: every step reports only, changes nothing
#
# Each numbered script is also runnable standalone: bash bootstrap/NN-foo.sh
set -euo pipefail

BOOTSTRAP_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "") : ;;
  *) echo "bootstrap.sh: unknown arg ${1}" >&2; exit 2 ;;
esac

STEPS=(
  00-prereqs.sh
  10-engines.sh
  20-identity.sh
  30-config-homes.sh
  40-secrets.sh
  50-units.sh
)

for step in "${STEPS[@]}"; do
  echo "==> ${step}"
  if [ "$CHECK" -eq 1 ]; then
    if ! bash "$BOOTSTRAP_DIR/$step" --check; then
      echo "bootstrap.sh: FAILED at ${step} (--check mode) — fix the above and re-run." >&2
      exit 1
    fi
  else
    if ! bash "$BOOTSTRAP_DIR/$step"; then
      echo "bootstrap.sh: FAILED at ${step} — fix the above, then re-run just this step:" >&2
      echo "  bash ${BOOTSTRAP_DIR}/${step}" >&2
      exit 1
    fi
  fi
done

echo "bootstrap.sh: all steps completed."
echo "Next: bash ${BOOTSTRAP_DIR}/verify.sh"
