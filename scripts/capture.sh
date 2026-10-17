#!/bin/bash
# Renders dashboard screenshots from dist/Burnless.app.
# Usage: scripts/capture.sh <output-dir> [--demo] [extra app args...]
# Real-data captures belong in a local, untracked folder (local-captures/).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mkdir -p "$1" && cd "$1" && pwd)"; shift
capture() {
  local name="$1" size="$2"; shift 2
  open -n -W --env BURNLESS_CAPTURE="$out/$name.png" --env BURNLESS_CAPTURE_DELAY="${DELAY:-6}" \
    --env BURNLESS_WINDOW_SIZE="$size" "$root/dist/Burnless.app" --args "$@"
  echo "$out/$name.png"
}
capture overview 1180x980 "$@" --route overview
capture claude 1180x980 "$@" --route claude
capture codex 1180x980 "$@" --route codex
capture overview-dark 1180x980 "$@" --route overview --appearance dark
capture overview-small 760x900 "$@" --route overview
capture settings 1000x900 "$@" --route settings
