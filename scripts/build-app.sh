#!/usr/bin/env bash
# Release build → build/CmdTabWheel.app
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ swift build (release)"
swift build -c release
./scripts/bundle-app.sh "$(swift build -c release --show-bin-path)/CmdTabWheel" build/CmdTabWheel.app
