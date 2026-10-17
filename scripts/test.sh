#!/bin/bash
# Runs every test: Rust engine (unit + synthetic-fixture tests) and Swift core.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> Engine tests"
(cd "$root/engine" && cargo test --locked)
echo "==> App core tests"
swift test --package-path "$root/app" --disable-xctest
