#!/bin/bash
# Builds the Working-Bolt browser extension: copies the current web/wb.js in and zips it for the
# Chrome Web Store / Edge Add-ons. Re-run after every wb.js change (store copies don't update themselves).
set -e
cd "$(dirname "$0")/.."
cp web/wb.js extension/wb.js
V=$(python3 -c "import json;print(json.load(open('extension/manifest.json'))['version'])")
mkdir -p dist-extension
rm -f "dist-extension/WorkingBolt-extension-$V.zip"
(cd extension && zip -qr "../dist-extension/WorkingBolt-extension-$V.zip" . -x '.*')
echo "dist-extension/WorkingBolt-extension-$V.zip"
