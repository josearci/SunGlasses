#!/bin/bash
# For development: builds SunGlasses from this checkout and (re)installs it in /Applications.
# It must live there: macOS 27 only keeps an app's own icon on the allow-list for the copy in /Applications,
# so a copy anywhere else hides its own sunglasses.
set -euo pipefail
cd "$(dirname "$0")"
./scripts/build-app.sh
pkill -x SunGlasses || true
sleep 0.5
rm -rf /Applications/SunGlasses.app
cp -R .build/SunGlasses.app /Applications/
open /Applications/SunGlasses.app
echo "Installed /Applications/SunGlasses.app"
