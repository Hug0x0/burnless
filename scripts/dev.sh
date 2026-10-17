#!/bin/bash
# Development run: builds the release engine, then launches the app with
# `swift run` (it finds engine/target/release/burnless-engine automatically).
# Pass --demo to use generated sample data instead of your history.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$root/engine" && cargo build --release --locked)
swift run --package-path "$root/app" Burnless "$@"
