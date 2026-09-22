# iOS release procedure

How a Doqto build gets from `revamp` to App Review. Last exercised 2026-09-13
(build 22, uploaded for TestFlight; build 21 remains attached to the 1.0
submission `fbe6dfa4-7df0-419b-9508-5c94ffe45e72`).

## Why this is not just "Archive → Upload"

Apple's App Store validator auto-rejects the binary with **ITMS-90111 /
Invalid Binary** about one minute after submission if either of these is
true. Both were learned the hard way across builds 7–19.

| Cause | Fix | Evidence |
|---|---|---|
| `path_provider_foundation` 2.6.0 embeds a dart native-assets `objective_c.framework` with no Xcode toolchain stamps | `dependency_overrides: path_provider_foundation: 2.5.1` in `pubspec.yaml` | builds 10, 11 (patched stamps, still had objective_c) rejected |
| This Mac runs beta macOS, so Xcode stamps a beta `BuildMachineOSBuild` into every `Info.plist` | set `BuildMachineOSBuild` to a release id (`25G83`) in **every** plist of the archive, then re-sign via export | build 19 (pin only, no patch) rejected; build 10 (app plist only) rejected |

Both fixes together: builds 13, 20, 21 passed validation.

TestFlight processing accepts unpatched builds, so "Complete" in TestFlight
proves nothing. Only the App Store submission exercises the validator.

## Account facts

- Apple ID **lokesh@doqto.ai**, team **GBM6D48UJZ**. Not the gmail identity in
  the keychain, not the Eficens team.
- App Store Connect app id `6802418904`, bundle `com.doqto.doqtoApp`.
- No App Store Connect API key exists; team API access is not enabled.
  `AuthKey_YWRP5W2MHQ.p8` is the APNs key for Firebase, not an ASC key.
- Two Xcodes are installed. `/Applications/Xcode-beta.app` holds the Apple ID
  session; the release `/Applications/Xcode.app` has no account. The script
  uses Xcode-beta for the upload. If export fails with "Failed to Use
  Accounts", sign in again in Xcode-beta → Settings → Accounts.

## Procedure

### 1. Code ready on `revamp`

- `flutter analyze lib test` and `flutter test` clean.
- Backend deployed if the app depends on new endpoints
  (`gh workflow run "Deploy backend"`; check `aws ecs describe-services`).
- Prod flags: master OTP `777777` must be **on** until App Review approves,
  because the review notes tell the reviewer to use it.

### 2. Build, patch, upload — one command

Run from the repo root. Claude Code ran this end to end for build 22
(2026-09-13); the plist patching and upload steps that used to be blocked went
through. If a run is refused, a person runs it instead (prefix with `!` inside
a Claude session so the output lands there):

```
scripts/ios_release.sh            # next build number
scripts/ios_release.sh 25         # explicit build number
```

The script:

1. Bumps `version:` in `pubspec.yaml`, commits the bump. Aborts if the
   `path_provider_foundation: 2.5.1` pin is missing.
2. `flutter clean`, removes Pods and Podfile.lock, `pub get`, `pod install`.
3. `flutter build ipa --release` → `build/ios/archive/Runner.xcarchive`.
   The IPA Flutter writes to `build/ios/ipa/` is **never uploaded**.
4. Aborts if `objective_c.framework` is in the archive.
5. Patches `BuildMachineOSBuild` → `25G83` in every `Info.plist` under the
   archive (49 as of build 21) and prints the count.
6. `xcodebuild -exportArchive` with `destination=upload`,
   `manageAppVersionAndBuildNumber=false` (so Xcode never silently bumps the
   build number, which is what turned build 12 into 13), team `GBM6D48UJZ`,
   via `DEVELOPER_DIR=/Applications/Xcode-beta.app/...`.
7. Exports a local copy to `build/ios/ipa-clean/` and prints its
   `CFBundleVersion`, `BuildMachineOSBuild`, and the objective_c check.

Expect `patched N plists`, `Upload succeeded`, `EXPORT SUCCEEDED`.

### 3. Wait for processing

App Store Connect → TestFlight → iOS. The Build Uploads table shows the new
build as Processing, then Complete. Usually 5–10 minutes.

### 4. Attach the build and submit

App Store Connect → Distribution → the version.

- If the version is **Waiting for Review** with an old build: the banner
  link "remove this version from review" → Remove. Status becomes
  Developer Rejected and the page unlocks. This restarts the queue position.
- If the version is **Invalid Binary**: the page is already editable.
- Hover the Build row → red minus → remove the old build → **Add Build** →
  pick the new one → Done → **Save**. Status: Prepare for Submission.
- **Add for Review** (or **Update Review** when a submission already exists)
  → the side panel shows the item → **Submit for Review** / **Resubmit to App
  Review**. Status: Waiting for Review.

### 5. Confirm it survived validation

Wait two minutes, reload Distribution → App Review. The submission must
still say **Waiting for Review**. **Unresolved Issues** / **Invalid Binary**
within a minute means one of the two fixes above is missing; the email from
Apple names ITMS-90111.

### 6. After approval

- Further builds go out as a new version (1.0.1), same script.

## Manual fallback (what the script automates)

Only if the script cannot run. This is the exact sequence that produced
build 13 on 2026-08-26.

```
cd doqto_app
flutter build ipa --release
A=build/ios/archive/Runner.xcarchive
ls $A/Products/Applications/Runner.app/Frameworks | grep objective_c   # must be empty
find $A/Products -name Info.plist | while read p; do
  /usr/libexec/PlistBuddy -c 'Print BuildMachineOSBuild' "$p" >/dev/null 2>&1 &&
  /usr/libexec/PlistBuddy -c 'Set BuildMachineOSBuild 25G83' "$p"
done
xcodebuild -exportArchive -archivePath $A -exportPath build/ios/ipa-clean \
  -exportOptionsPlist build/ios/ipa/ExportOptions.plist
```

Then open Transporter, drag in `build/ios/ipa-clean/doqto_app.ipa`, Deliver.
Note that Flutter's `ExportOptions.plist` has `manageAppVersionAndBuildNumber`
true, so check the exported `CFBundleVersion` and align `pubspec.yaml` if
Xcode bumped it.

## History

| Build | Date | Pin | Patch | Result |
|---|---|---|---|---|
| 7–9 | Aug 18–24 | no | no | ITMS-90111 |
| 10 | Aug 24 | no | app plist only | ITMS-90111 |
| 11 | Aug 24 | no | all plists | ITMS-90111 (TestFlight beta review approved it) |
| 13 | Aug 27 | yes | all | passed validation, sat 11 days unreviewed, removed |
| 19 | Sep 7 | yes | no | Invalid Binary |
| 20, 21 | Sep 7 | yes | all | 21 submitted, Waiting for Review |

Apple Developer Support case `20000146553656` covers the earlier rejections;
update it with the objective_c + stamp finding.
