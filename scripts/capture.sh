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
  # Run the binary directly: capture mode keeps its windows invisible and off
  # screen, so nothing appears or takes focus while it renders.
  BURNLESS_CAPTURE="$out/$name.png" BURNLESS_CAPTURE_DELAY="${DELAY:-6}" \
    BURNLESS_WINDOW_SIZE="$size" BURNLESS_ROUTE="$route" \
    BURNLESS_APPEARANCE="$appearance" BURNLESS_PERIOD="${PERIOD:-last30}" \
    BURNLESS_CAPTURE_WINDOW="${WINDOW:-dashboard}" BURNLESS_SETTINGS_TAB="${TAB:-general}" \
    BURNLESS_POPOVER="$([[ "${WINDOW:-}" == popover ]] && echo 1 || echo 0)" BURNLESS_POPOVER_TAB="${POPOVER_TAB:-general}" \
    "$root/dist/Burnless.app/Contents/MacOS/Burnless" "$@"
  if [[ -f "$out/$name.png" ]]; then echo "$out/$name.png"; else echo "capture failed: $name" >&2; fi
}
capture overview 1240x1000 overview light "$@"
capture claude 1240x1000 claude light "$@"
capture codex 1240x1000 codex light "$@"
capture gemini 1240x1000 gemini light "$@"
capture overview-dark 1240x1000 overview dark "$@"
capture claude-dark 1240x1000 claude dark "$@"
capture overview-small 780x900 overview light "$@"
WINDOW=popover capture menu-bar none overview light "$@"
WINDOW=popover POPOVER_TAB=codex capture menu-bar-codex none overview dark "$@"
WINDOW=popover POPOVER_TAB=gemini capture menu-bar-gemini none overview light "$@"
WINDOW=settings TAB=quotas capture settings-quotas none settings light "$@"
WINDOW=settings TAB=general capture settings-general none settings light "$@"
