#!/usr/bin/env bash
# Dev loop in one command: debug build → .app → restart the app → stream its logs.
# Ctrl+C stops watching the logs; the app keeps running (quit it from the menu bar icon).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▸ swift build (debug)"
swift build
./scripts/bundle-app.sh "$(swift build --show-bin-path)/CmdTabWheel" build/CmdTabWheel.app

# SIGTERM = graceful quit: the app gives the system ⌘Tab back before exiting.
if pkill -x CmdTabWheel; then
  for _ in $(seq 30); do pgrep -x CmdTabWheel >/dev/null || break; sleep 0.1; done
  # Still alive → it runs under Xcode's debugger, which swallows SIGTERM.
  # Force it, and re-enable the system ⌘Tab on its behalf.
  if pgrep -x CmdTabWheel >/dev/null; then
    pkill -9 -x CmdTabWheel || true
    sleep 0.3
    build/CmdTabWheel.app/Contents/MacOS/CmdTabWheel --restore-native-switcher
  fi
fi
open build/CmdTabWheel.app

echo "▸ logs (Ctrl+C to stop watching)"
exec /usr/bin/log stream --style compact --level info \
  --predicate 'subsystem == "com.faustienf.CmdTabWheel"'
