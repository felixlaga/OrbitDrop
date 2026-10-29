#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build dist
APP="build/OrbitDrop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 Sources/OrbitDrop/*.swift -o "$APP/Contents/MacOS/OrbitDrop" -framework AppKit -framework Quartz -framework PDFKit -framework Vision -framework CoreImage -framework UniformTypeIdentifiers -framework ServiceManagement -framework Carbon
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
if [ -d Resources/Codecs ]; then cp -R Resources/Codecs "$APP/Contents/Resources/"; fi
if [ -d Resources/Licenses ]; then cp -R Resources/Licenses "$APP/Contents/Resources/"; fi
codesign --force --deep --sign - "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/OrbitDrop-macOS-AppleSilicon.zip
echo "Built $APP and dist/OrbitDrop-macOS-AppleSilicon.zip"
