#!/bin/bash
# Patch the beta-macOS BuildMachineOSBuild stamp in every Info.plist of the
# archive, then re-export (re-sign) and upload to App Store Connect.
#
# Why: this Mac runs beta macOS. Apple auto-rejects (ITMS-90111) binaries that
# carry a beta BuildMachineOSBuild; the re-sign on export seals the edit.
# Build 13 (patched) passed, build 19 (unpatched) was rejected — see memory.
# Also requires path_provider_foundation 2.5.1 pin (no objective_c.framework).
#
# Usage: scripts/ios_patch_and_upload.sh   (run from repo root)
set -euo pipefail
cd "$(dirname "$0")/../doqto_app"
ARCHIVE=build/ios/archive/Runner.xcarchive
STAMP=25G83   # last release macOS build id; change if Apple rejects it

echo "archive build: $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ARCHIVE/Products/Applications/Runner.app/Info.plist")"
if ls "$ARCHIVE/Products/Applications/Runner.app/Frameworks" | grep -q objective_c; then
  echo "objective_c.framework present — pin path_provider_foundation 2.5.1 and rebuild" >&2; exit 1
fi

n=0
while IFS= read -r p; do
  if /usr/libexec/PlistBuddy -c 'Print BuildMachineOSBuild' "$p" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set BuildMachineOSBuild $STAMP" "$p"; n=$((n+1))
  fi
done < <(find "$ARCHIVE/Products" -name Info.plist)
echo "patched $n plists"
find "$ARCHIVE/Products" -name Info.plist -exec /usr/libexec/PlistBuddy -c 'Print BuildMachineOSBuild' {} \; 2>/dev/null | sort | uniq -c

cat > build/ios/ExportUpload.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>destination</key><string>upload</string>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>3N7394B3B9</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
  <key>stripSwiftSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict></plist>
EOF

# Xcode-beta holds the lokesh@doqto.ai session; release Xcode.app has no account.
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist build/ios/ExportUpload.plist \
  -exportPath build/ios/upload -allowProvisioningUpdates 2>&1 | grep -iE "error|succeeded|complete\.|failed"
