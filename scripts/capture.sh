#!/bin/bash
# Renders dashboard screenshots from dist/Burnless.app.
# Usage: scripts/capture.sh <output-dir> [--demo] [extra app args...]
# Real-data captures belong in a local, untracked folder (local-captures/).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mkdir -p "$1" && cd "$1" && pwd)"; shift
# capture <name> <size> <route> <appearance> [app args...]
# WINDOW=settings|popover captures that window; TAB picks the settings tab.
capture() {
  local name="$1" size="$2" route="$3" appearance="$4"; shift 4
  open -n -W --env BURNLESS_CAPTURE="$out/$name.png" --env BURNLESS_CAPTURE_DELAY="${DELAY:-6}" \
    --env BURNLESS_WINDOW_SIZE="$size" --env BURNLESS_ROUTE="$route" \
    --env BURNLESS_APPEARANCE="$appearance" --env BURNLESS_PERIOD="${PERIOD:-last30}" \
    --env BURNLESS_CAPTURE_WINDOW="${WINDOW:-dashboard}" --env BURNLESS_SETTINGS_TAB="${TAB:-general}" \
    --env BURNLESS_POPOVER="$([[ "${WINDOW:-}" == popover ]] && echo 1 || echo 0)" \
    "$root/dist/Burnless.app" ${1+--args "$@"}
  if [[ -f "$out/$name.png" ]]; then echo "$out/$name.png"; else echo "capture failed: $name" >&2; fi
}
capture overview 1240x1000 overview light "$@"
capture claude 1240x1000 claude light "$@"
capture codex 1240x1000 codex light "$@"
capture overview-dark 1240x1000 overview dark "$@"
capture claude-dark 1240x1000 claude dark "$@"
capture overview-small 780x900 overview light "$@"
WINDOW=popover capture menu-bar none overview light "$@"
WINDOW=settings TAB=quotas capture settings-quotas none settings light "$@"
WINDOW=settings TAB=general capture settings-general none settings light "$@"
