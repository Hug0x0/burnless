#!/bin/bash
# Renders dashboard screenshots from dist/Burnless.app.
# Usage: scripts/capture.sh <output-dir> [--demo] [extra app args...]
# Real-data captures belong in a local, untracked folder (local-captures/).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mkdir -p "$1" && cd "$1" && pwd)"; shift
# capture <name> <size> <route> <appearance> [app args...]
capture() {
  local name="$1" size="$2" route="$3" appearance="$4"; shift 4
  open -n -W --env BURNLESS_CAPTURE="$out/$name.png" --env BURNLESS_CAPTURE_DELAY="${DELAY:-6}" \
    --env BURNLESS_WINDOW_SIZE="$size" --env BURNLESS_ROUTE="$route" \
    --env BURNLESS_APPEARANCE="$appearance" --env BURNLESS_PERIOD="${PERIOD:-last30}" \
    "$root/dist/Burnless.app" ${1+--args "$@"}
  if [[ -f "$out/$name.png" ]]; then echo "$out/$name.png"; else echo "capture failed: $name" >&2; fi
}
capture overview 1180x980 overview light "$@"
capture claude 1180x980 claude light "$@"
capture codex 1180x980 codex light "$@"
capture overview-dark 1180x980 overview dark "$@"
capture overview-small 760x900 overview light "$@"
capture settings 1000x900 settings light "$@"
