#!/bin/bash
set -e
cd /Users/nvdberg/Library/CloudStorage/Dropbox/Nicolaas/Claude/Projects/LigthningBolt/hacking-bolt-ios
echo "=== archive ==="
rm -rf build/HackingBolt.xcarchive build/export
xcodebuild -project HackingBolt.xcodeproj -scheme HackingBolt -configuration Release \
  -archivePath build/HackingBolt.xcarchive archive -destination "generic/platform=iOS" \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=RF4R5X25Y2 \
  PROVISIONING_PROFILE_SPECIFIER="WorkingBolt AppStore Push" CODE_SIGN_IDENTITY="Apple Distribution" \
  2>&1 | tail -4
echo "=== export ==="
xcodebuild -exportArchive -archivePath build/HackingBolt.xcarchive -exportPath build/export \
  -exportOptionsPlist ../tools/ExportOptions-manual.plist 2>&1 | tail -4
echo "=== upload ==="
IPA=$(ls build/export/*.ipa | head -1)
echo "ipa: $IPA"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey VHUC7XW3Y6 --apiIssuer b24cf15b-dcb0-41de-9d02-774b4886a091 2>&1 | tail -6
echo "=== DONE ==="
