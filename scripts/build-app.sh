#!/bin/bash
# Builds .build/SunGlasses.app: release, Apple Silicon (macOS 27 runs on nothing else).
# Version is 1.0.<number of commits on HEAD>, so a local build of a commit matches its GitHub release.
# Updates come from the GitHub repo in SUNGLASSES_UPDATE_REPO, else the "origin" remote.
#
# Signed with the "SunGlasses Signing" certificate when it's in the keychain (scripts/make-signing-cert.sh),
# otherwise ad-hoc. macOS ties the Accessibility grant to the signature, so every build everyone runs must
# carry the same certificate; an ad-hoc build loses the grant on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
REPO=${SUNGLASSES_UPDATE_REPO:-$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)}
APP=.build/SunGlasses.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos26.0 SunGlasses.swift -o "$APP/Contents/MacOS/SunGlasses"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.josearci.SunGlasses</string>
  <key>CFBundleName</key><string>SunGlasses</string>
  <key>CFBundleExecutable</key><string>SunGlasses</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.$BUILD</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  ${REPO:+<key>SunGlassesUpdateRepo</key><string>$REPO</string>}
</dict></plist>
EOF

if security find-certificate -c "SunGlasses Signing" >/dev/null 2>&1; then
  codesign --force --sign "SunGlasses Signing" "$APP"
else
  echo "warning: no 'SunGlasses Signing' certificate in the keychain; signing ad-hoc (Accessibility must be re-granted after every build)" >&2
  codesign --force --sign - "$APP"
fi
echo "Built $APP — SunGlasses 1.0.$BUILD${REPO:+, updates from github.com/$REPO}"
