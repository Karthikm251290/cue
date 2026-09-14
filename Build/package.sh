#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/Cue.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Assets/Cue.icns "$APP/Contents/Resources/Cue.icns"
cp .build/release/SessionControl "$APP/Contents/MacOS/SessionControl"
cp .build/release/SessionReporter "$APP/Contents/Helpers/SessionReporter"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.karthik.sessioncontrol</string>
<key>CFBundleName</key><string>Cue</string>
<key>CFBundleDisplayName</key><string>Cue</string>
<key>CFBundleExecutable</key><string>SessionControl</string>
<key>CFBundleIconFile</key><string>Cue</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Cue selects the exact Terminal tab associated with the session you choose.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/SessionReporter"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
