# Firebase as the identity broker

**Status:** approved design, not yet implemented
**Date:** 2026-09-14

## Why

Doqto authenticates by phone + 6-digit OTP, and has never been able to deliver
that OTP to a US number:

| Provider | Blocker |
|---|---|
| AWS SNS | No origination identity. US destinations need toll-free or 10DLC; the account has neither, and `MonthlySpendLimit` is capped at $1. |
| Twilio Verify | `21608` — Verify refuses unverified numbers without an approved TrustHub Primary Customer Profile. Submitted, pending review. |

Both blockers are carrier-registration gates on *us*. Firebase phone auth sends
through Google's own carrier relationships, so neither gate exists. The same
change brings Google, Facebook and Apple sign-in on one code path, because every
provider resolves to a single Firebase ID token.

It also removes `MASTER_OTP_ENABLED` / `777777`, a backdoor that currently
accepts any phone number in production.

**Timing.** Production was wiped on 2026-09-13 and has one row: the super admin.
An auth migration costs almost nothing today and grows more expensive with every
user who signs up.

## What Firebase is and is not

Firebase answers *who is this*. The backend continues to decide *what they may
do*. Doqto's own JWTs, Redis sessions, refresh rotation, roles and audit log are
unchanged. A Firebase ID token is accepted exactly once, at sign-in, and is
never presented to any other endpoint.

### HIPAA

`Firebase Authentication` is **not** on Google's HIPAA-covered products list.
`Identity Platform` — the same service, paid tier, same SDKs and tokens — **is**.
The project must be upgraded to Identity Platform and a Google Cloud BAA signed
for `doqto-90684`.

Per Google's Identity Platform HIPAA guidance, it holds the minimum needed to
sign in (phone number, email) and no PHI: nothing in display name, photo URL or
custom claims. Everything else stays in Postgres. That is already the shape of
this design.

PHI never reaches Facebook or Apple either — Doqto's users are physicians, and a
clinician's name and NPI are public NPPES directory data, not patient
information.

## Backend

### The one endpoint

```
POST /api/v1/auth/firebase   { id_token }  ->  TokenPair
```

`request-otp` and `verify-otp` are deleted.

Verification uses `google.oauth2.id_token.verify_firebase_token()` from
**`google-auth==2.57.1`, already in `requirements.txt`** for FCM v1. No new
dependency, no `firebase-admin`, no service-account JSON, and no hand-rolled
JWKS on a security-critical path. It checks signature, `iss`, `aud` and `exp`
against Google's rotating certs.

Required config: `FIREBASE_PROJECT_ID`. A request on this path with the setting
empty raises rather than degrading — mirroring `twilio_verify._service_url()`.

### User resolution

From the verified claims take `uid`, and whichever of `phone_number` / `email`
Firebase asserts. Then, in order:

1. `firebase_uid == uid` -> that user.
2. else `phone` or `email` matches (whichever the token carries) -> adopt the
   row, set `firebase_uid`. Covers accounts predating this change.
3. else create the minimal row `verify_otp` creates today: blank `full_name`,
   `PENDING##` NPI, `role=doctor`.

`is_registered` keeps its current meaning: `full_name` set and NPI not
`PENDING`. Step 2 is what makes the change invisible to anyone who signed up
before it.

A row with `deleted_at` set is refused — see Account deletion.

### Rate limiting

The hourly per-phone limit existed to guard SMS spend; Google guards its own
spend now. But `/auth/firebase` becomes the only unauthenticated endpoint, and a
valid token still costs a database write, so it keeps a per-IP limit via the
existing `rate_limit_key` helper.

### Deletions

| File | Action |
|---|---|
| `app/services/twilio_verify.py` | delete |
| `app/services/sns_client.py` | delete |
| `app/services/fakes.py` | drop `FakeSNSClient` |
| `tests/test_sms_providers.py` | delete |
| `app/services/auth_service.py` | drop `request_otp`, `verify_otp`, `_generate_otp`, `_sns`, `_twilio`, `_use_twilio` |
| `app/core/redis_keys.py` | drop `otp_key`, `otp_attempts_key`, `otp_resend_key` |
| `app/core/constants.py` | drop `DEV_MASTER_OTP`, `OTP_*`, `RATE_LIMIT_OTP_PER_HOUR` |
| `app/core/config.py` | drop `MASTER_OTP_ENABLED`, `SMS_PROVIDER`, `TWILIO_*`; add `FIREBASE_PROJECT_ID` |
| `app/core/routes.py` | drop `AUTH_REQUEST_OTP`, `AUTH_VERIFY_OTP`; add `AUTH_FIREBASE` |
| `infra/backend/main.tf` | drop the Twilio secret, the three env vars, `variable "twilio"`, `MASTER_OTP_ENABLED` |
| `docs/sms-otp.md` | replace with the Firebase flow |

`AuditAction.OTP_REQUESTED` / `OTP_VERIFIED` are **kept**. Audit rows referencing
them already exist in prod and the enum values must stay resolvable; the new path
logs `OTP_VERIFIED` on a successful phone sign-in, and a new `SOCIAL_VERIFIED`
enum value (added in this change) for the others.

Net: roughly 300 lines out, 80 in.

## Schema

One Alembic migration:

- `users.phone` -> **nullable** (social-only accounts have none)
- `users.firebase_uid` -> `VARCHAR(128)`, unique, nullable, indexed
- `CHECK (phone IS NOT NULL OR email IS NOT NULL)` — an account stays reachable

`npi_number` keeps its `PENDING##` placeholder. That flow works and is out of
scope.

### Nullable-phone audit

Only two sites in the backend read `User.phone`, both in `auth_service` and both
deleted by this change. The two that survive are in
`account_deletion_service.py` and are handled below. `admin_auth_service` is
email + password and is untouched.

## Account deletion

Two defects this change would otherwise introduce, both in
`account_deletion_service.py`:

1. **Line 61** builds an audit value as `"****" + user.phone[-4:]`. On a
   social-only account `phone` is `NULL` and this raises, failing the deletion.
   Guard it: emit the fixed marker `"****none"` when `phone` is `NULL`.
2. **`firebase_uid` is not scrubbed.** The service scrubs `phone` to a stub and
   sets `email = None`, but a surviving `firebase_uid` means a deleted user
   signing back in with the same Google account would match at resolution step 1
   and **adopt their own tombstone**. It must be set to `NULL`, and
   `/auth/firebase` must refuse any row with `deleted_at` set — defence at both
   ends, because the tombstone is a HIPAA retention record and must never become
   a live account again.

The existing stub write keeps `phone` non-null, so the new CHECK constraint is
satisfied by tombstones.

## Flutter

### Packages

`firebase_auth`, `google_sign_in`, `flutter_facebook_auth`. Apple uses
`firebase_auth`'s `OAuthProvider` — no fourth package. `firebase_core` is
already present for FCM.

### The convergence

Every provider ends the same way, which is the entire point of brokering:

```dart
final idToken = await credential.user!.getIdToken();
await authRepository.signInWithFirebase(idToken);
```

Phone sign-in keeps both existing screens. `login_screen` calls
`verifyPhoneNumber`; `otp_screen` submits the SMS code to `signInWithCredential`
instead of posting it to the backend. The user-visible flow does not change —
only who sends the message.

`AuthRepository.requestOtp` / `verifyOtp` are replaced by
`signInWithFirebase(idToken)`, which stores the returned token pair exactly as
`verifyOtp` does today. `AuthNotifier.verifyOtp` becomes
`signIn(AuthBroker credential)`; the `AuthStage` machine, `bootstrap()`,
`_resolveStageForRegisteredUser()` and the router redirects are untouched.

### AuthBroker

Firebase sits behind a thin `AuthBroker` interface with a `FakeAuthBroker` for
tests — the same pattern as `FakeSNSClient`. This is not optional: the 174
existing widget tests must not require a Firebase binding, which cannot be
initialised in `flutter test`.

```dart
abstract class AuthBroker {
  Future<void> startPhoneSignIn(String phone, {required void Function(String verificationId) onCodeSent});
  Future<String> confirmPhoneCode(String verificationId, String code); // -> idToken
  Future<String> signInWithGoogle();
  Future<String> signInWithFacebook();
  Future<String> signInWithApple();
  Future<void> signOut();
}
```

### Social users and the optional phone field

The existing requirement stands: a user who signs in with a social provider gets
an optional phone field on Your Details, OTP-verified if filled. That
verification now runs through `linkWithCredential` on the Firebase user, and the
backend learns the phone on the next `/users/me` patch. A social user who skips
it has `phone IS NULL`, which the schema now permits.

### Keyboard rule

`login_screen` and `otp_screen` keep `PhoneField` and `AppTextField`, so
`onTapOutside` and dismiss-on-valid behaviour carry over unchanged. See
CLAUDE.md; guarded by `test/widgets/keyboard_dismiss_test.dart` and
`test/widgets/phone_field_keyboard_test.dart`.

## Testing

**Backend** — stubbed verifier, no network:

- new user -> row created, `is_registered=false`
- returning user -> `is_registered=true`, `LOGIN` audit row
- adoption by phone, and by email, for a row with no `firebase_uid`
- expired token, wrong `aud`, wrong `iss`, malformed token -> 401
- `deleted_at` set -> refused
- `FIREBASE_PROJECT_ID` empty -> raises, does not degrade
- per-IP rate limit trips
- neither the ID token nor the full phone number appears in logs

**Flutter** — `FakeAuthBroker` across the existing suites, plus:

- each of the four providers reaches `signInWithFirebase` with its token
- a provider cancellation (user dismisses the Google sheet) is not an error
- an unregistered user lands on Your Details; a registered one on Chats

Both suites green, `flutter analyze lib test` clean, and a simulator run — the
CLAUDE.md bar for anything touching input.

## Console work (not code)

Blocking, and only the account owner can do it:

1. Sign the Google Cloud BAA for `doqto-90684`; upgrade the project to Identity
   Platform.
2. Enable Phone, Google, Facebook and Apple providers.
3. Upload the APNs auth key; register the iOS bundle ID and the Android SHA-1
   and SHA-256 fingerprints.
4. Create the Meta app and start Business Verification — the long pole, days to
   weeks. Google, Apple and phone do not depend on it.
5. Register test phone numbers with fixed codes, replacing `777777`.

Apple sign-in is required by App Store guideline 4.8 once Google or Facebook
ships. It is not optional and not a follow-up.

## Sequencing

Facebook's Business Verification gates only Facebook. Ship in this order so the
SMS blocker clears first:

1. Schema migration + `/auth/firebase` + deletions (backend green)
2. `AuthBroker` + phone sign-in through Firebase (unblocks US SMS)
3. Google + Apple buttons
4. Facebook, when Meta approves

## Risks

| Risk | Handling |
|---|---|
| iOS phone auth falls back to a reCAPTCHA webview when silent push fails | Accepted. Works, occasionally ugly. Requires the APNs key to be uploaded. |
| Identity layer concentrated on Google | Already true for push. `firebase_uid` is one nullable column; providers stay swappable because the user row is ours. |
| Firebase abuse quotas throttle phone auth | Google's limits are far above Doqto's volume. Monitor after launch. |
| A returning user's provider email differs from their Doqto email | Resolution step 2 matches phone *or* email; a mismatch creates a second account. Acceptable at current scale — revisit if support sees it. |
| Twilio deleted before Firebase is proven | `twilio_verify.py` is recoverable from git. TrustHub approval, if it arrives, changes nothing. |
