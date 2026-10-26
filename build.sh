#!/bin/sh
# Builds SunGlasses straight into /Applications and (re)launches it.
# It must live there: macOS 27 only keeps an app's own icon on the allow-list for the copy in /Applications,
# so a copy anywhere else hides its own sunglasses.
set -e
cd "$(dirname "$0")"
APP=/Applications/SunGlasses.app
pkill -x SunGlasses || true
mkdir -p "$APP/Contents/MacOS"
swiftc -O SunGlasses.swift -o "$APP/Contents/MacOS/SunGlasses"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.josearci.SunGlasses</string>
  <key>CFBundleName</key><string>SunGlasses</string>
  <key>CFBundleExecutable</key><string>SunGlasses</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# a real identity keeps the Accessibility grant across rebuilds; ad-hoc signing loses it every time
codesign -s "Apple Development" --force "$APP" 2>/dev/null || codesign -s - --force "$APP"
open "$APP"
echo "Installed and launched $APP"
