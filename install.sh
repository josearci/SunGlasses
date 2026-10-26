#!/bin/bash
# Installs the latest SunGlasses release into /Applications and starts it. After this, SunGlasses updates itself.
#
#   curl -fsSL https://raw.githubusercontent.com/josearci/SunGlasses/main/install.sh | bash
#
# (Building from source instead? See build.sh.)
set -euo pipefail

REPO="josearci/SunGlasses"
URL="https://github.com/$REPO/releases/latest/download/SunGlasses.zip"

if [ "$(uname)" != "Darwin" ]; then echo "SunGlasses is a macOS app." >&2; exit 1; fi
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "$MAJOR" -lt 27 ]; then echo "SunGlasses needs macOS 27 or later (this Mac has $(sw_vers -productVersion))." >&2; exit 1; fi
if [ "$(uname -m)" != "arm64" ]; then echo "SunGlasses needs an Apple Silicon Mac." >&2; exit 1; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading the latest SunGlasses…"
curl -fsSL "$URL" -o "$TMP/SunGlasses.zip"
ditto -x -k "$TMP/SunGlasses.zip" "$TMP"
APP="$TMP/SunGlasses.app"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" != "com.josearci.SunGlasses" ]; then
  echo "The download doesn't look like SunGlasses; nothing was installed." >&2
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

# /Applications only: macOS 27 keeps an app's own menu bar icon visible only for the copy there.
DEST=/Applications
if [ ! -w "$DEST" ]; then
  echo "Can't write to /Applications. SunGlasses has to live there, so run this from an admin account." >&2
  exit 1
fi

pkill -x SunGlasses 2>/dev/null && sleep 1 || true
rm -rf "$DEST/SunGlasses.app"
ditto "$APP" "$DEST/SunGlasses.app"
xattr -dr com.apple.quarantine "$DEST/SunGlasses.app" 2>/dev/null || true
open "$DEST/SunGlasses.app"

echo "SunGlasses $VERSION is installed and running: look for the sunglasses in your menu bar."
echo "Allow it in the Accessibility prompt (System Settings › Privacy & Security › Accessibility); that's how it sees you drop icons on it."
echo "Then ⌘-drag any menu bar icon onto the sunglasses to hide it. It keeps itself up to date."
