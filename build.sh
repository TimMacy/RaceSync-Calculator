#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
app="RaceSync Calculator.app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk macosx --show-sdk-path)"

for arch in arm64 x86_64; do
    xcrun swiftc -sdk "$sdk" -target "${arch}-apple-macos15.2" \
        -parse-as-library -O "RaceSync Calculator.swift" \
        -framework SwiftUI -framework AppKit -framework Vision -framework ScreenCaptureKit \
        -o "$work/$arch"
done

lipo -create "$work/arm64" "$work/x86_64" -output "$work/RaceSync Calculator"
mkdir -p "$work/$app/Contents/MacOS" "$work/$app/Contents/Resources"
cp Credits.rtf "$work/$app/Contents/Resources/Credits.rtf"
cp "$work/RaceSync Calculator" "$work/$app/Contents/MacOS/RaceSync Calculator"
cat > "$work/$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>RaceSync Calculator</string>
    <key>CFBundleIdentifier</key>
    <string>com.racesync.calculator</string>
    <key>CFBundleName</key>
    <string>RaceSync Calculator</string>
    <key>CFBundleDisplayName</key>
    <string>RaceSync Calculator</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.2</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Screen access is needed to read the selected timer regions.</string>
</dict>
</plist>
PLIST

cat > "$work/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
</dict>
</plist>
PLIST

mkdir -p "$work/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" icon.png --out "$work/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    pixels=$((size * 2))
    sips -z "$pixels" "$pixels" icon.png --out "$work/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work/AppIcon.iconset" -o "$work/$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - --identifier com.racesync.calculator \
    --entitlements "$work/entitlements.plist" "$work/$app"
rm -rf "$app"
mv "$work/$app" "$app"
