# App Store and HIG audit report

Date: 2026-11-26. Branch: `revamp`. Nothing is committed, deployed or uploaded:
every change below is in the working tree for review.

## Status

**Finished 2026-11-26, about 08:50.** Stopped at the user's request after
the final passes below.

- **App Store Review Guidelines: 0 blockers.** Five independent audit passes.
  The final pass found 0 blockers and 2 warnings (old profile photos and
  unfinished uploads left in S3 after account deletion). Both were then fixed,
  covered by a new backend test, and confirmed by re-reading the code:
  every `avatars/{user_id}/` object is removed, replaced photos are deleted
  on upload, and unfinished multipart uploads are aborted after the commit.
  That leaves 0 blockers and 0 code warnings.
- **Human Interface Guidelines: 0 violations, 0 warnings** on the sixteenth
  pass, which also found no regressions from round 15. That pass was targeted
  (deep on the latest changes, pattern sweep elsewhere), not a line-by-line
  read of every file.
- **Two warnings stay live in production until you deploy** the backend and
  website: the Help link 404s, and the live privacy and terms pages still
  claim end-to-end encryption. Both are fixed in the working tree.
- **`ios-review` scanner:** two items left, both false positives. It flags
  `import XCTest` in the test target (never shipped) and the word
  "placeholder" in `Main.storyboard`, which is Interface Builder's own First
  Responder element (removing it breaks storyboard compilation; I tried and
  restored it).

## How the audit was run

- `ios-review` scanner on the Xcode project (Info.plist, privacy manifest,
  entitlements, deprecated and private APIs, security, UI checks).
- Apple documentation (`apple-docs`, `Apple-Dev`) for every native API change
  and for the privacy-manifest keys.
- Because the UI is Flutter, the scanner cannot see it. The Dart code, the
  backend and the website were audited by reading the code: three reviewers in
  round 1 (privacy and account rules; payments, content and medical rules;
  HIG), then repeated independent re-audits after each fix round. Review
  Guidelines: five rounds. HIG: sixteen rounds.
- After every fix round: `flutter analyze lib test`, `flutter test`, and
  `flutter build ios --release --no-codesign`. Backend: `pytest`. Website:
  `tsc --noEmit`.

Not done: nothing was run on a device or simulator, and no screenshots were
taken. `flutter build ios --simulator` is broken on this Mac's Xcode 27 (known
issue), so layout, VoiceOver and Dynamic Type changes are verified by widget
tests and by reading the code only. CLAUDE.md asks for a device run or
screenshots for layout and input changes; that still has to happen before a
build ships.

## Verification at the end

- `flutter analyze lib test`: no issues.
- `flutter test`: 810 passed.
- `flutter build ios --release --no-codesign`: built (round-15 code; the only
  later change is backend-only).
- Backend `pytest`: 519 passed.
- Website `tsc --noEmit`: clean.

## What needs you

1. **Review, then commit.** About 200 files changed. Suggested split: iOS
   native, app guideline fixes, HIG fixes, backend, website.
2. **Visible design changes to accept or revert** (all made for contrast or
   state-by-shape):
   - Brand teal in the app is `#307981`, was `#35878F` (white text on the old
     teal was 4.19:1). The icon and website still use `#35878F`.
   - Muted grey text is `#5B6C94` (was `#8A9CC4`), red is `#D02424` (was
     `#EF4444`), and six chat themes have darker sent-bubble colours.
   - "Read" receipts are a filled check disc instead of a blue double check,
     so read and delivered differ by shape and not only by tint.
   - The online dot is dark green; away is a hollow amber ring.
   - Selected messages show a check mark while selecting; the segmented
     control thumb is white with a teal outline.
   - Rows of filter chips are about 14pt taller (44pt touch area).
   - The app is locked to portrait except in the photo viewer and video player.
   - Signing out now asks for confirmation everywhere.
3. **Backend is not deployed.** It needs migration `0036_user_suspension`
   (adds two nullable columns to `users`) and a normal deploy. Until then the
   shipped app keeps working: the app-side changes do not depend on it, except
   that the Help link fix for already-released builds comes from the backend
   constant.
4. **Grant the FCM service account the "Firebase Authentication Admin" role**
   in the Firebase/Google Cloud console. Account deletion now deletes the
   Firebase sign-in record from the server; without the role the call is
   refused and logged, and the rest of the deletion still completes.
5. **Website is not deployed** (`landing/`, run `deploy.sh`). The privacy
   policy, terms and BAA wording changed (see below): have whoever owns the
   legal text read the diff first.
6. **App Store Connect privacy answers**: add "Emails or Text Messages",
   "Device ID", "Product Interaction" and "Other Data Types" (all linked to
   the user, app functionality, no tracking) to match the updated manifest.
7. **Export compliance** (`ITSAppUsesNonExemptEncryption` is `false` while the
   app encrypts its local store with its own AES). This is a declaration for
   DOQTO LLC, so I left it. Decide between filing the self-classification or
   moving to iOS Data Protection.
8. **Set a CloudWatch alarm** on the log line `report_filed` so a filed report
   reaches a person.
9. **Backend: friendly error for clearing the only contact.** An account with
   no phone that clears its email hits the `ck_users_phone_or_email` check and
   gets a 500. The app blocks this before sending, but `update_me` should
   return a 4xx such as `email_required`.
10. **Build 46 is still the one in review.** None of this is in it or in build
   49. A new build is needed to ship the app-side fixes; I did not bump the
   build number or upload anything.

## Findings and fixes

### App Store Review Guidelines

| Guideline | Finding | Fix |
|---|---|---|
| 5.1.1(v) | Deleting an account never revoked Sign in with Apple tokens, and the Firebase sign-in record survived | The app asks Apple to confirm once more, revokes the tokens, then deletes; the backend also deletes the Firebase identity. Cancelling at Apple leaves the account untouched |
| 5.1.1(v) | "Permanently deletes your messages" was not true: attachment files stayed in S3, edit history stayed readable, several tables and columns were left | Backend deletion now removes the files (after commit), edit history, sessions, stars, reactions, preferences, invites and the remaining profile fields; the audit row no longer stores phone digits or NPI |
| 5.1.1(v) | A half-registered account could only sign out | "Delete account" on the registration screen |
| 5.1.2 | Facebook SDK was linked and started at launch (feature off), and its manifest declares tracking | Dependency and all code paths removed; pods no longer include it |
| 5.1.1 / 5.1.2 | Privacy manifest missed message content, device ID, usage audit data and NPI | Four collected-data types added |
| 5.1.1(ii) | Camera and microphone purpose strings did not mention document scanning or video sound | Strings widened in `Info.plist` |
| 5.1.1 | Notification prompt fired at cold launch, before sign-in | Asked only after a registered sign-in; sign-out never triggers it |
| 2.1 / 1.5 | Help centre link was a 404; "Contact us" was a dead mailto on a phone with no Mail account | Link points to `/support`; the address is shown and copied when Mail is unavailable |
| 2.1 | A failed org lookup at sign-in pinned the user to a screen with no way out | Falls through to chats; the org picker also has Sign out |
| 2.1 | An unknown deep link (the old `doqto:///billing`) showed a bare "Page Not Found" | Unknown routes go back through the splash |
| 2.3.10 | "Android blanks organisation chats…" in iOS-visible copy; the shared invite link showed "Get it on Google Play" and "iPhone app coming soon" to iPhones | Copy reworded; the invite page shows no other platform's store to Apple devices |
| 2.3.1 / 5.1.1(i) | Website privacy policy, terms, BAA and marketing claimed end-to-end, zero-knowledge encryption; the product encrypts in transit and at rest with managed keys | Wording corrected, including that it is not end-to-end and that audited admin access exists |
| 1.2 | Reporting a user sent a bare "other"; nobody could act on reports without SQL | Reporting a user asks for a reason; super-admin endpoints to suspend or unsuspend a user and remove a message, all audited; suspension enforced on sign-in, refresh, API and socket |
| 4.8 | Apple button used a tinted mark | Black mark, same size and prominence as Google |
| 2.5.1 | Three deprecated AVFoundation / AVFAudio calls in `AppDelegate.swift` | Replaced with the current APIs |
| 3.1.1, 1.4.1, 5.1.3 | Nothing found: no billing surface in the app, no clinical claims, no health data to third parties | No change |

Also fixed along the way: cancelling Apple's sheet on the login screen showed
an error; account deletion clean-up could outlast the app's timeout and make a
completed deletion look failed; deleted users could still open a websocket.

### Human Interface Guidelines

Sixteen audit rounds; every item reported in rounds 1–15 was fixed. By area:

- **Touch targets**: about 45 controls brought to 44pt or more (links, chips,
  segmented control, reaction pills, emoji cells, swatches, overlay buttons,
  scrubber, tab icons).
- **VoiceOver**: the shared button widget now announces one button with its
  name and state; labels on every icon-only and image-only control; selected,
  checked and header traits; text fields named by their labels; loading and
  error states announced; the lock screen hides the app underneath.
- **Contrast**: colour tokens and chat themes brought to 4.5:1 for text and
  3:1 for icons, including text on sent bubbles, tinted insets, scrims over
  photos, snackbars, avatars and photo wallpapers.
- **Dynamic Type**: no text under 11pt (including the in-app "Small" setting);
  fixed-height rows, buttons, banners, sheets and dialogs now grow or scroll.
- **Safe areas**: home-indicator inset on about 35 lists and sheets; tab lists
  clear the raised centre button.
- **Orientation**: portrait lock, landscape only for full-screen media.
- **Destructive actions**: confirmation with a red action and Cancel/Keep for
  sign out, remove photo, unpin, withdraw, decline, reject, reset, revoke,
  cancel scheduled, discard edits and discard poll draft.
- **Feedback**: raw exception and Firebase text replaced with sentences; UUID
  fragments replaced with words; failed loads no longer look like empty lists;
  retry on error states; errors raised under sheets moved into the sheet;
  voice broadcast keeps the recording and offers retry on failure.
- **Permissions**: camera, photos, save-to-photos, document scan and
  notifications each have an "Open Settings" path when access is off.
- **Text input**: autofill hints for one-time codes, phone, name and email;
  invite code can be typed without the middle dot; PIN fields have their own
  validation message.
- **Discoverability**: schedule message, select in gallery, unstar and remove
  connection are no longer long-press or swipe only.

### Accepted and left as they are

- The centre microphone button in the tab bar (an action in a tab bar).
- Material-style dialogs and pickers.
- Inline links inside message text are one line tall (standard exemption).
- The Apple mark is drawn with the Material `apple` glyph, in black.
- NPI numbers are format-checked only, not verified against the registry.
- Backend `/billing` endpoints and the unlinked `/billing/done` web page still
  exist; the app has no billing surface.
- Scanner false positives (see Status).

## Files changed and why

### iOS native (`doqto_app/ios/`)

| File | Why |
|---|---|
| `Runner/AppDelegate.swift` | Deprecated AVFoundation calls replaced; privacy cover labelled for VoiceOver; camera-denied check for the scanner; save-to-photos reports a refused permission distinctly |
| `Runner/Info.plist` | Camera and microphone purpose strings |
| `Runner/PrivacyInfo.xcprivacy` | Four collected-data types added |
| `Runner/Assets.xcassets/AppIcon.appiconset/` | 38pt icon sizes added (2x, 3x) |
| `Runner/Base.lproj/LaunchScreen.storyboard` | Accessibility label on the launch image |
| `Podfile.lock` | Facebook pods removed |

### App: guideline fixes (`doqto_app/`)

| File | Why |
|---|---|
| `pubspec.yaml`, `pubspec.lock` | `flutter_facebook_auth` removed |
| `lib/data/services/auth_broker.dart`, `firebase_auth_broker.dart` | Apple token revocation, identity deletion, cancel handling, Facebook removed |
| `lib/state/auth_state.dart` | `deleteAccount` order; org-lookup fallback; sign-out never prompts |
| `lib/data/services/push_token_provider.dart`, `notification_service.dart` | No launch prompt; non-prompting token read; permission status |
| `lib/data/services/media_native.dart` | Camera-denied check; typed save-to-photos result |
| `lib/data/models/app_meta.dart` | Help link default |
| `lib/core/router/app_router.dart` | Unknown routes return to the splash |
| `lib/core/utils/error_messages.dart`, `validators.dart`, `datetime_format.dart`, `rich_text.dart` | Plain-language errors; PIN and invite-code validation; locale-aware short dates; no ids in previews |
| `lib/core/utils/app_orientation.dart` (new), `lib/main.dart` | Portrait lock; text scaler |
| `lib/state/settings_state.dart` | Text scaler with an 11pt floor |
| `lib/l10n/*` | "Email address copied" string |
| `lib/core/constants/strings.dart` | New copy; platform-neutral wording |

### App: HIG fixes (`doqto_app/lib/`)

| Files | Why |
|---|---|
| `core/tokens/colors.dart`, `core/tokens/typography.dart`, `core/chat_theme.dart`, `core/theme.dart` | Contrast-passing tokens and themes, 11pt minimum, snackbar text colour, labels on photo wallpapers |
| `ui/widgets/` (about 35 files, 4 new: `confirm_sign_out.dart`, `load_failed.dart`, `media_load_failed.dart`, `scrim_spinner.dart`) | Shared button semantics, text field labels and autofill, chips, segmented control, bubbles, avatars, reactions, emoji picker, banners, sheets |
| `ui/screens/` (about 70 files across auth, chat, compliance, groups, home, media, my_org, network, org, people, profile, settings, storage, voice_broadcast) | Per-screen touch targets, labels, contrast, safe areas, confirmations, error and empty states, text scaling |

### App tests (`doqto_app/test/`)

About 30 files changed or added, covering the deletion order, button and text
field semantics, 44pt targets, contrast against every chat theme, the text
scaler, invite-code entry, save-to-photos outcomes and the updated screens.

### Backend (`doqto_backend/`)

| File | Why |
|---|---|
| `app/services/account_deletion_service.py`, `app/api/v1/users.py` | Complete deletion; files, exports, all profile photos and unfinished uploads removed after the response; replaced profile photos deleted on upload |
| `app/services/s3_client.py`, `app/services/file_service.py` | Delete-by-prefix helper |
| `app/api/v1/org_compliance.py`, `app/schemas/network.py` | Message reports carry their conversation id so admins can request access without typing an id |
| `app/services/firebase_identity.py` (new) | Server-side Firebase identity deletion |
| `app/api/v1/admin.py`, `app/schemas/moderation.py` (new), `app/core/routes.py`, `enums.py`, `constants.py` | Suspend, unsuspend and remove-message endpoints; Help URL |
| `app/core/dependencies.py`, `app/services/auth_service.py`, `app/api/v1/auth.py`, `app/api/websocket.py` | Suspended and deleted accounts refused everywhere |
| `app/services/message_service.py`, `app/api/v1/messages.py` | Shared tombstone path; no edit history for deleted messages |
| `app/services/connection_service.py` | `report_filed` log line |
| `app/models/user.py`, `alembic/versions/0036_user_suspension.py` (new) | Suspension columns |
| `tests/test_account_deletion.py`, `tests/test_admin_moderation.py` (new) | Coverage for the above |

### Website (`landing/src/`)

| File | Why |
|---|---|
| `app/privacy/page.tsx`, `app/terms/page.tsx`, `app/baa/page.tsx`, `app/layout.tsx`, `lib/constants.ts`, `components/layout/Footer.tsx`, `components/sections/HeroSection.tsx`, `components/mockups/ChatMockupScreen.tsx` | Encryption claims corrected |
| `app/delete-account/page.tsx` | States what is retained |
| `app/get/page.tsx` | No other platform's store shown to Apple devices |
| `app/support/page.tsx` | Platform-neutral wording |

### Docs

| File | Why |
|---|---|
| `docs/auth.md` | Facebook sign-in section updated |
