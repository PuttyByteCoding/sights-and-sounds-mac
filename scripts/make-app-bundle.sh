#!/usr/bin/env bash
# Build a double-clickable SightsAndSounds.app from the release binary.
#
#   ./scripts/make-app-bundle.sh [output-dir]     (default: ./dist)
#
# The bundle gets keyboard focus, a dock presence and a proper name —
# everything a bare `swift run` executable lacks. Signed ad hoc (no
# developer identity), so on first open from a download right-click → Open
# (or: xattr -dr com.apple.quarantine dist/SightsAndSounds.app).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-dist}"
APP="$OUT/SightsAndSounds.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SightsAndSounds "$APP/Contents/MacOS/SightsAndSounds"

# SPM emits each target's resources as a .bundle beside the binary. They
# have to travel with it: Contents/Resources is where Bundle.main looks,
# and without them the app runs in the system font instead of Archivo.
for resource_bundle in .build/release/*.bundle; do
    [ -e "$resource_bundle" ] || continue
    cp -R "$resource_bundle" "$APP/Contents/Resources/"
done

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
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
    <key>NSLocalNetworkUsageDescription</key><string>Sights and Sounds connects to other Macs on your network only when you pair them with a code: to open a library another Mac holds, or to let an approved Mac open this one's.</string>
    <!-- What macOS shows when it asks for access to a library's media. -->
    <key>NSRemovableVolumesUsageDescription</key><string>Sights and Sounds reads and organises the media files in libraries kept on external drives.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Sights and Sounds reads and organises the media files in libraries kept on network shares.</string>
</dict>
</plist>
PLIST

# One ad-hoc signature over the finished bundle. The linker's signature
# on the binary alone does not cover Info.plist and changes identity on
# every build, so macOS kept asking again for access it had been given.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Open with:  open '$APP'"
