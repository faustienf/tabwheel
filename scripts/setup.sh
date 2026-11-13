#!/usr/bin/env bash
# ⌘Tab Wheel: install, update, develop. Asks what to do:
#
#   scripts/setup.sh
#
# or takes the answer as an argument:
#
#   install   build the app, put it in Applications in place of an older copy, start it
#   dev       debug build into build/, start it from there and follow its log
#   test      run the tests
#   restore   quit the app and give ⌘Tab back to macOS (when the app died without doing it)
#   bundle <binary> <app>   wrap a built binary into an .app (Xcode does this after each build)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

EXECUTABLE="CmdTabWheel"
APP_NAME="$EXECUTABLE.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

fail() {
  echo "✗ $*" >&2
  exit 1
}

menu() {
  echo "⌘Tab Wheel"
  echo "  1) Install or update: build it, put it in Applications, start it"
  echo "  2) Develop: a debug build from build/, with its log in this window"
  echo "  3) Run the tests"
  echo "  4) Quit it and give ⌘Tab back to macOS"
  while true; do
    read -r -p "What to do? [1] " choice || exit 1 # Ctrl+D
    case "${choice:-1}" in
      1) install_app; return ;;
      2) run_dev; return ;;
      3) run_tests; return ;;
      4) restore_switcher; return ;;
    esac
  done
}

# MARK: - Install or update

# A copy already in /Applications or ~/Applications is replaced where it is. Otherwise the app
# goes to /Applications, or to ~/Applications for a user who can't write there.
install_app() {
  check_tools
  local dest stage="build/setup" status
  if [ -d "/Applications/$APP_NAME" ]; then
    dest="/Applications/$APP_NAME"
  elif [ -d "$HOME/Applications/$APP_NAME" ]; then
    dest="$HOME/Applications/$APP_NAME"
  elif [ -w /Applications ]; then
    dest="/Applications/$APP_NAME"
  else
    dest="$HOME/Applications/$APP_NAME"
  fi

  echo "▸ swift build (release)"
  swift build -c release
  rm -rf "$stage"
  bundle_app "$(swift build -c release --show-bin-path)/$EXECUTABLE" "$stage/$APP_NAME"
  "$LSREGISTER" -u "$stage/$APP_NAME" # only the installed copy should be known to the system

  stop_running "$stage/$APP_NAME"
  if [ -e "$dest" ]; then
    echo "▸ replacing $dest"
    # The old copy is moved out (and deleted along with $stage below), not deleted in place:
    # if the new one can't get in, the old one goes back.
    if ! mv "$dest" "$stage/old-$APP_NAME"; then
      open "$dest" # it was quit above
      fail "couldn't move the old $dest out of the way.
  If macOS said your terminal was prevented from modifying apps: System Settings → Privacy & Security
  → App Management → turn your terminal on, then run this again. Or drag $ROOT/$stage/$APP_NAME
  into Applications in Finder yourself."
    fi
    if ! mv "$stage/$APP_NAME" "$dest"; then
      mv "$stage/old-$APP_NAME" "$dest"
      open "$dest"
      fail "couldn't put the new app into $(dirname "$dest"); the old one is back and running"
    fi
    status="updated"
  else
    echo "▸ installing into $(dirname "$dest")"
    mkdir -p "$(dirname "$dest")"
    mv "$stage/$APP_NAME" "$dest"
    status="installed"
  fi
  rm -rf "$stage" || echo "⚠︎ couldn't delete the old copy in $stage: the new one is installed anyway" >&2
  "$LSREGISTER" -f "$dest"

  open "$dest"
  echo "✓ ⌘Tab Wheel $(version_of "$dest") $status: $dest"
  if [ "$status" = "installed" ]; then
    echo "  It's in the menu bar now; its setup window asks for the permissions it needs."
  fi
}

# MARK: - Develop

# Debug build → build/CmdTabWheel.app (where Xcode's ⌘R puts it too) → start it → follow its log.
# Ctrl+C stops following the log; the app keeps running (quit it from the menu bar icon).
run_dev() {
  check_tools
  echo "▸ swift build (debug)"
  swift build
  bundle_app "$(swift build --show-bin-path)/$EXECUTABLE" "build/$APP_NAME"
  stop_running "build/$APP_NAME"
  open "build/$APP_NAME"
  echo "▸ its log (Ctrl+C to stop following it)"
  exec /usr/bin/log stream --style compact --level info \
    --predicate 'subsystem == "com.faustienf.CmdTabWheel"'
}

# MARK: - Test

run_tests() {
  check_tools
  echo "▸ swift test"
  swift test
}

# MARK: - Give ⌘Tab back

restore_switcher() {
  local app
  for app in "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME" "build/$APP_NAME"; do
    [ -x "$app/Contents/MacOS/$EXECUTABLE" ] || continue
    stop_running "$app" # quitting gives ⌘Tab back by itself; this covers a crashed app
    "$app/Contents/MacOS/$EXECUTABLE" --restore-native-switcher
    echo "✓ ⌘Tab is the system switcher again"
    return
  done
  fail "no built app to do it with: install it first"
}

# MARK: - Parts

check_tools() {
  [ "$(id -u)" -ne 0 ] || fail "run it without sudo"
  [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || fail "⌘Tab Wheel needs macOS 14 or later"
  use_xcode
  xcrun --find swift >/dev/null 2>&1 \
    || fail "no Swift here: install Xcode 16 or later from the App Store, open it once, then run this again"
}

# Xcode's tools even when the Command Line Tools are the selected ones (xcode-select): every
# command builds with the same Swift, and only Xcode has Swift Testing. The two Swifts can
# disagree about what compiles, so building with one and testing with the other hides errors.
use_xcode() {
  if xcode-select -p 2>/dev/null | grep -q CommandLineTools && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
}

# Quits every running copy, whatever folder it runs from. Two copies would fight over ⌘Tab, and
# `open` only brings a running copy forward: it doesn't start a newer one from somewhere else.
# $1: an app whose binary can give ⌘Tab back to macOS if a copy has to be killed.
stop_running() {
  local user_id
  user_id="$(id -u)"
  # SIGTERM = graceful quit: the app gives the system ⌘Tab back before exiting.
  pkill -x -U "$user_id" "$EXECUTABLE" || return 0 # nothing running
  echo "▸ quitting the running ⌘Tab Wheel"
  for _ in $(seq 30); do
    pgrep -x -U "$user_id" "$EXECUTABLE" >/dev/null || return 0
    sleep 0.1
  done
  # Still alive → it runs under Xcode's debugger, which swallows SIGTERM.
  # Force it, and give ⌘Tab back on its behalf.
  pkill -9 -x -U "$user_id" "$EXECUTABLE" || true
  sleep 0.3
  "$1/Contents/MacOS/$EXECUTABLE" --restore-native-switcher
}

# The version: a number that grows by one with every commit (the commit count plus 2, so it
# started at 13), and the commit it was built from — "d97685b, modified" when what goes into the
# app has uncommitted changes. The app shows it in About and writes it to its log.
stamp_version() {
  local plist="$1" number=0 commit="unknown"
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" = true ]; then
      echo "⚠︎ no version number: a shallow clone has no history to count (git fetch --unshallow)" >&2
    else
      number=$(($(git -C "$ROOT" rev-list --count HEAD) + 2))
    fi
    commit="$(git -C "$ROOT" rev-parse --short HEAD)"
    if [ -n "$(git -C "$ROOT" status --porcelain -- Sources Support Package.swift)" ]; then
      commit="$commit, modified"
    fi
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $number" -c "Set :CFBundleVersion $number" \
    -c "Add :GitCommit string $commit" "$plist"
}

# The version an app was stamped with, "v13 (d97685b)".
version_of() {
  local plist="$1/Contents/Info.plist"
  echo "v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" \
    "($(/usr/libexec/PlistBuddy -c 'Print :GitCommit' "$plist"))"
}

# Wraps a built binary into an .app and signs it. An .app is just a folder:
#   CmdTabWheel.app/Contents/Info.plist        ← bundle id, LSUIElement, version…
#   CmdTabWheel.app/Contents/MacOS/CmdTabWheel ← the binary
#   CmdTabWheel.app/Contents/Resources/        ← the icon: Assets.car (macOS 26 glass icon
#                                                 and older systems) + AppIcon.icns (fallback)
bundle_app() {
  local bin="$1" app="$2"
  local info_plist="$ROOT/Support/Info.plist"
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"

  # The icon's source is Support/AppIcon.icon (Icon Composer). actool compiles it; the result is
  # cached in build/icon and redone only when the source changes.
  local icon_source="$ROOT/Support/AppIcon.icon" icon_cache="$ROOT/build/icon"
  if [ ! -f "$icon_cache/Assets.car" ] || [ -n "$(find "$icon_source" -newer "$icon_cache/Assets.car")" ]; then
    # actool comes with Xcode, not the Command Line Tools — use Xcode even if it isn't selected.
    if ! xcrun --find actool >/dev/null 2>&1 && [ -d /Applications/Xcode.app ]; then
      export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
    echo "▸ compiling the app icon"
    rm -rf "$icon_cache"
    mkdir -p "$icon_cache"
    if ! xcrun actool "$icon_source" --compile "$icon_cache" --app-icon AppIcon \
        --platform macosx --minimum-deployment-target 14.0 \
        --output-partial-info-plist "$icon_cache/partial.plist" >/dev/null; then
      rm -rf "$icon_cache"
      echo "⚠︎ no icon: actool failed (it needs Xcode)" >&2
    fi
  fi

  echo "▸ assembling $app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/$EXECUTABLE"
  cp "$info_plist" "$app/Contents/Info.plist"
  stamp_version "$app/Contents/Info.plist"
  if [ -f "$icon_cache/Assets.car" ]; then
    cp "$icon_cache/Assets.car" "$icon_cache/AppIcon.icns" "$app/Contents/Resources/"
  fi

  # Use a real certificate if there is one (SIGN_IDENTITY overrides), else ad-hoc ("-").
  local identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
  identity="${identity:--}"

  echo "▸ codesign with: $identity"
  if [ "$identity" = "-" ]; then
    # Ad-hoc signatures identify the app by its binary hash, which changes on every build,
    # so macOS forgets the Accessibility permission after each rebuild. Pin the designated
    # requirement to the bundle id instead — the permission then survives rebuilds.
    # Dev-only trade-off: any ad-hoc app claiming this bundle id would match too.
    codesign --force --sign - --requirements "=designated => identifier \"$bundle_id\"" "$app"
  else
    codesign --force --sign "$identity" "$app"
  fi
  codesign --verify --strict "$app"
  # Tell Launch Services about the new bundle right away, so Finder, the Dock and System Settings
  # show the current icon instead of a cached (or missing) one.
  "$LSREGISTER" -f "$app"
  echo "✓ $app, $(version_of "$app")"
}

case "${1:-}" in
  "") if [ -t 0 ]; then menu; else install_app; fi ;;
  install) install_app ;;
  dev) run_dev ;;
  test) run_tests ;;
  restore) restore_switcher ;;
  bundle)
    [ $# -eq 3 ] || fail "usage: scripts/setup.sh bundle <binary> <output.app>"
    bundle_app "$2" "$3"
    ;;
  *) fail "unknown command: $1 (there are install, dev, test, restore)" ;;
esac
