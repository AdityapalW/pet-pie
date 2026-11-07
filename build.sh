#!/bin/zsh
# Builds PiePet and wraps it into build/PiePet.app
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/PiePet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PiePet "$APP/Contents/MacOS/PiePet"
cp shortcuts/*.shortcut "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PiePet</string>
  <key>CFBundleDisplayName</key><string>Pi</string>
  <key>CFBundleIdentifier</key><string>local.hackathon.piepet</string>
  <key>CFBundleExecutable</key><string>PiePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Pi listens when you tap the talk button.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Pi turns what you say into text, on this Mac.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
