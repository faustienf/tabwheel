#!/usr/bin/env bash
# Wraps an already built CmdTabWheel binary into an .app bundle and signs it.
# Used by build-app.sh, run.sh and the Xcode scheme (post-build action).
#
#   scripts/bundle-app.sh <binary> <output.app>
#
# A macOS .app is just a folder:
#   CmdTabWheel.app/Contents/Info.plist        ← bundle id, LSUIElement, version…
#   CmdTabWheel.app/Contents/MacOS/CmdTabWheel ← the binary
#   CmdTabWheel.app/Contents/Resources/        ← the icon: Assets.car (macOS 26 glass icon
#                                                 and older systems) + AppIcon.icns (fallback)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$1"
APP="$2"
INFO_PLIST="$ROOT/Support/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"

# The icon's source is Support/AppIcon.icon (Icon Composer). actool compiles it; the result is
# cached in build/icon and redone only when the source changes.
ICON_SOURCE="$ROOT/Support/AppIcon.icon"
ICON_CACHE="$ROOT/build/icon"
if [ ! -f "$ICON_CACHE/Assets.car" ] || [ -n "$(find "$ICON_SOURCE" -newer "$ICON_CACHE/Assets.car")" ]; then
  # actool comes with Xcode, not the Command Line Tools — use Xcode even if it isn't selected.
  if ! xcrun --find actool >/dev/null 2>&1 && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  echo "▸ compiling the app icon"
  rm -rf "$ICON_CACHE"
  mkdir -p "$ICON_CACHE"
  if ! xcrun actool "$ICON_SOURCE" --compile "$ICON_CACHE" --app-icon AppIcon \
      --platform macosx --minimum-deployment-target 14.0 \
      --output-partial-info-plist "$ICON_CACHE/partial.plist" >/dev/null; then
    rm -rf "$ICON_CACHE"
    echo "⚠︎ no icon: actool failed (it needs Xcode)" >&2
  fi
fi

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
if [ -f "$ICON_CACHE/Assets.car" ]; then
  cp "$ICON_CACHE/Assets.car" "$ICON_CACHE/AppIcon.icns" "$APP/Contents/Resources/"
fi

# Use a real certificate if there is one (SIGN_IDENTITY overrides), else ad-hoc ("-").
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"

echo "▸ codesign with: $IDENTITY"
if [ "$IDENTITY" = "-" ]; then
  # Ad-hoc signatures identify the app by its binary hash, which changes on every build,
  # so macOS forgets the Accessibility permission after each rebuild. Pin the designated
  # requirement to the bundle id instead — the permission then survives rebuilds.
  # Dev-only trade-off: any ad-hoc app claiming this bundle id would match too.
  codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
else
  codesign --force --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
# Tell Launch Services about the new bundle right away, so Finder, the Dock and System Settings
# show the current icon instead of a cached (or missing) one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "✓ $APP"
