#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
app="RaceSync Calculator.app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk macosx --show-sdk-path)"

for arch in arm64 x86_64; do
    xcrun swiftc -sdk "$sdk" -target "${arch}-apple-macos15.2" \
        -parse-as-library -O Sources/*.swift \
        -framework SwiftUI -framework AppKit -framework Vision -framework ScreenCaptureKit \
        -o "$work/$arch"
done

lipo -create "$work/arm64" "$work/x86_64" -output "$work/RaceSync Calculator"
mkdir -p "$work/$app/Contents/MacOS" "$work/$app/Contents/Resources"
cp Credits.rtf "$work/$app/Contents/Resources/Credits.rtf"
mkdir -p "$work/$app/Contents/Resources/Fonts"
cp Fonts/*.ttf Fonts/*.txt "$work/$app/Contents/Resources/Fonts/"
cp "$work/RaceSync Calculator" "$work/$app/Contents/MacOS/RaceSync Calculator"
cp Info.plist "$work/$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$work/$app/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $version" "$work/$app/Contents/Info.plist"

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
