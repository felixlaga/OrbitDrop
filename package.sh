#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh
STAGING="build/Installer"
mkdir -p "$STAGING"
ditto build/OrbitDrop.app "$STAGING/OrbitDrop.app"
if [ ! -L "$STAGING/Applications" ]; then ln -s /Applications "$STAGING/Applications"; fi
cp Resources/Install.txt "$STAGING/Install.txt"
hdiutil create -volname OrbitDrop -srcfolder "$STAGING" -ov -format UDZO dist/OrbitDrop.dmg
python3 tools/package-source.py
shasum -a 256 dist/OrbitDrop.dmg dist/OrbitDrop-macOS-AppleSilicon.zip dist/OrbitDrop-Source.zip > dist/SHA256SUMS.txt
echo "Packages ready in dist/"
