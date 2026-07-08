#!/bin/bash
# Builds Cheatsheet.app (Release) and zips it for sharing.
# Usage: ./build.sh
set -euo pipefail

cd "$(dirname "$0")"

xcodebuild -project Cheatsheet.xcodeproj \
  -scheme Cheatsheet \
  -configuration Release \
  -derivedDataPath build \
  build

APP="build/Build/Products/Release/Cheatsheet.app"

rm -f Cheatsheet.zip
ditto -c -k --keepParent "$APP" Cheatsheet.zip

echo
echo "App: $APP"
echo "Zip: Cheatsheet.zip"
