#!/bin/bash
# One-shot iOS release from this (beta-macOS) Mac:
#   bump build number -> clean -> archive -> verify -> patch beta stamps ->
#   re-sign export + upload to App Store Connect -> verify uploaded IPA.
#
# Why each step exists (ITMS-90111 history, builds 7-19):
#   * path_provider_foundation must stay pinned to 2.5.1 — 2.6.0 embeds a
#     native-assets objective_c.framework with no toolchain stamps. Rejected.
#   * Every Info.plist in the archive must have BuildMachineOSBuild set to a
#     release macOS id; this Mac stamps the beta id. Rejected otherwise (b19).
#   * The export re-signs, sealing the plist edits. Upload the export's IPA,
#     never the one `flutter build ipa` writes to build/ios/ipa.
#   * Signing and upload use whichever Xcode is selected (xcode-select -p) and
#     the ASC API key below (no Xcode account needed since the DOQTO LLC move). Until 2026-09-22
#     this was Xcode-beta; the Mac now runs release macOS 27 + Xcode 27, so the
#     stamp patch below is belt-and-braces rather than required.
#
# Usage:  scripts/ios_release.sh [build-number]
#   No arg = current pubspec build number + 1. Commits the bump.
# After it prints EXPORT SUCCEEDED: wait for TestFlight "Complete", then attach
# the build to the version in App Store Connect and submit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/doqto_app"
ARCHIVE="$APP/build/ios/archive/Runner.xcarchive"
STAMP=25G83                # last release macOS build id
XCODE_DEV=$(xcode-select -p)
# Release signs manually: "Apple Distribution: DOQTO LLC" (key and cert in the
# login keychain, copies in ~/.doqto/ios-dist) + profile "Doqto iOS App Store",
# both made through the API because the team has no devices for automatic
# development signing. The App Store Connect API key (DOQTO LLC, Admin) uploads,
# so Xcode needs no Apple account. The .p8 lives outside the repo.
ASC_KEY_ID=${ASC_KEY_ID:-F9YBMB25H4}
ASC_ISSUER=${ASC_ISSUER:-29aa5d08-657f-4a5f-b51f-c2f746bc71d6}
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$HOME/.doqto/AuthKey_${ASC_KEY_ID}.p8"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER")
cd "$APP"

# 1. build number
cur=$(sed -nE 's/^version: ([0-9.]+)\+([0-9]+)$/\2/p' pubspec.yaml)
name=$(sed -nE 's/^version: ([0-9.]+)\+([0-9]+)$/\1/p' pubspec.yaml)
next=${1:-$((cur + 1))}
sed -i '' "s/^version: ${name}+${cur}\$/version: ${name}+${next}/" pubspec.yaml
echo "== version ${name}+${next} (was +${cur})"
grep -q 'path_provider_foundation: 2.5.1' pubspec.yaml || { echo "path_provider_foundation 2.5.1 pin missing from pubspec.yaml" >&2; exit 1; }
git -C "$ROOT" add doqto_app/pubspec.yaml
git -C "$ROOT" commit -qm "app: build ${next}" && echo "== committed bump"

# 2. clean + archive
echo "== clean"
flutter clean >/dev/null
rm -rf ios/Pods ios/Podfile.lock build/ios
flutter pub get >/dev/null
(cd ios && pod install >/dev/null)
echo "== archive (5-10 min)"
flutter build ios --release --config-only >/dev/null
DEVELOPER_DIR=$XCODE_DEV xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" archive "${AUTH[@]}" 2>&1 | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
[ -d "$ARCHIVE" ] || { echo "archive missing" >&2; exit 1; }

# 3. verify archive
RUNNER="$ARCHIVE/Products/Applications/Runner.app"
echo "== archive CFBundleVersion $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$RUNNER/Info.plist")"
if ls "$RUNNER/Frameworks" | grep -q objective_c; then echo "objective_c.framework embedded — abort" >&2; exit 1; fi

# 4. patch every Info.plist
n=0
while IFS= read -r p; do
  if /usr/libexec/PlistBuddy -c 'Print BuildMachineOSBuild' "$p" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set BuildMachineOSBuild $STAMP" "$p"; n=$((n+1))
  fi
done < <(find "$ARCHIVE/Products" -name Info.plist)
echo "== patched $n plists:"
find "$ARCHIVE/Products" -name Info.plist -exec /usr/libexec/PlistBuddy -c 'Print BuildMachineOSBuild' {} \; 2>/dev/null | sort | uniq -c

# 5-8. re-sign export + upload (no version management, so no surprise bumps)
cat > build/ios/ExportUpload.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>destination</key><string>upload</string>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>com.doqto.ios</key><string>Doqto iOS App Store</string></dict>
  <key>teamID</key><string>3N7394B3B9</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
  <key>stripSwiftSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><false/>
</dict></plist>
EOF
echo "== export + upload"
DEVELOPER_DIR=$XCODE_DEV xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist build/ios/ExportUpload.plist \
  -exportPath build/ios/upload "${AUTH[@]}" 2>&1 \
  | grep -iE "error|succeeded|failed|Upload succeeded"

# Also keep a local copy of exactly what was uploaded, and verify it.
sed 's|<string>upload</string>|<string>export</string>|' build/ios/ExportUpload.plist > build/ios/ExportLocal.plist
rm -rf build/ios/ipa-clean
if DEVELOPER_DIR=$XCODE_DEV xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist build/ios/ExportLocal.plist \
  -exportPath build/ios/ipa-clean "${AUTH[@]}" > build/ios/export-local.log 2>&1; then
  echo "== verify build/ios/ipa-clean/doqto_app.ipa"
  unzip -p build/ios/ipa-clean/doqto_app.ipa Payload/Runner.app/Info.plist > build/ios/ipa-clean/Info.plist
  plutil -p build/ios/ipa-clean/Info.plist | grep -E "CFBundleVersion|CFBundleShortVersionString|BuildMachineOSBuild"
  if unzip -l build/ios/ipa-clean/doqto_app.ipa | grep -q objective_c; then echo "objective_c present!"; else echo "no objective_c"; fi
else
  echo "== local verification export failed (see build/ios/export-local.log); upload above is unaffected"
fi
echo "== done: wait for TestFlight 'Complete', then attach build ${next} in App Store Connect and submit."
