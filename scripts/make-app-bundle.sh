#!/usr/bin/env bash
# Build a double-clickable SightsAndSounds.app from the release binary.
#
#   ./scripts/make-app-bundle.sh [output-dir]     (default: ./dist)
#
# The bundle gets keyboard focus, a dock presence and a proper name —
# everything a bare `swift run` executable lacks. Unsigned; on first open
# right-click → Open (or: xattr -dr com.apple.quarantine dist/SightsAndSounds.app).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-dist}"
APP="$OUT/SightsAndSounds.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SightsAndSounds "$APP/Contents/MacOS/SightsAndSounds"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Sights and Sounds</string>
    <key>CFBundleDisplayName</key><string>Sights and Sounds</string>
    <key>CFBundleIdentifier</key><string>com.puttybyte.sightsandsounds</string>
    <key>CFBundleExecutable</key><string>SightsAndSounds</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.8.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Built $APP"
echo "Open with:  open '$APP'"
