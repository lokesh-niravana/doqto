# Authentication

Firebase is the identity broker. Phone, Google, Facebook and Apple all resolve
to one Firebase ID token, which the app exchanges for a Doqto session:

```
POST /api/v1/auth/firebase   { id_token }  ->  { access_token, refresh_token, is_registered }
```

Firebase answers *who is this*. Everything else — JWTs, Redis sessions, refresh
rotation, roles, the audit log — is ours and unchanged. A Firebase ID token is
accepted once, at sign-in, and never presented to another endpoint.

## Why not SMS ourselves

Phone OTP through our own providers could never reach a US number:

| Provider | Blocker |
|---|---|
| AWS SNS | No origination identity. US needs toll-free or 10DLC; `MonthlySpendLimit` was capped at $1. |
| Twilio Verify | `21608` — refuses unverified numbers without an approved TrustHub Primary Customer Profile. |

Both are carrier-registration gates on *us*. Firebase sends through Google's own
carrier relationships, so neither applies. India always worked (international
sender ID needs no registration) — which is why `+91` testers got codes and
`+1` testers never did.

## Verification

`app/services/firebase_auth.py`, using `google.oauth2.id_token.verify_firebase_token`
from **google-auth, already a dependency for FCM v1**. No `firebase-admin`, no
service-account JSON, no hand-rolled JWKS. It checks signature, issuer, audience
and expiry against Google's rotating certs.

`FIREBASE_PROJECT_ID` is the only setting. There is no secret: ID tokens are
verified against public certs.

## Resolving a token to a user

1. `firebase_uid` matches → that user.
2. else `phone` or `email` matches → adopt the row and set `firebase_uid`.
   This is what makes brokering invisible to accounts created before it.
3. else create a minimal row (blank name, `PENDING##` NPI) for registration to
   fill in.

A row with `deleted_at` set is refused. Account deletion clears `firebase_uid`
for the same reason — otherwise the provider account still maps to the
tombstone and signing in again would revive a deleted user.

## Schema

`users.phone` is nullable: a user who signs in with Google and skips the
optional phone field has none. `CHECK (phone IS NOT NULL OR email IS NOT NULL)`
keeps every account reachable. Migration `0022_firebase_identity`.

## HIPAA

`Firebase Authentication` is **not** on Google's HIPAA-covered products list;
`Identity Platform` — the same service, paid tier — **is**. The project runs on
Identity Platform with a signed Google Cloud BAA.

Per Google's guidance it holds only what is needed to sign in (phone, email) and
no PHI — nothing in display name, photo URL or custom claims. Doqto's users are
physicians, so identity data here is professional directory data, the same as
the public NPPES registry.

## No test numbers, no master OTP

Every number gets a real SMS. There are no fixed-code test numbers registered,
and `MASTER_OTP_ENABLED` / `777777` — a sign-in backdoor accepted for **any**
phone number and compiled into the shipped build — is gone from the code and
from `infra/backend/main.tf`.

If a fixed code is ever wanted for CI, it belongs on a fictitious number in the
Firebase console (never a real one, which would stop receiving real messages),
and never in the app binary.

## Flutter

`AuthBroker` (`lib/data/services/auth_broker.dart`) is the seam. `FirebaseAuthBroker`
is the real one; `FakeAuthBroker` lets every widget test run without a Firebase
binding, which `flutter test` cannot provide.

`AuthNotifier.signInWith(SocialProvider)` and `.confirmPhoneCode(challenge, code)`
both funnel into one private `_exchange`, so the `AuthStage` machine has a single
entry regardless of provider.

A social sheet the user dismisses returns null, changes nothing, and does not
throw — cancellation is a normal outcome.

## Apple

App Store guideline 4.8: offering Google or Facebook requires offering Sign in
with Apple as an equivalent option. It rides `firebase_auth`'s `OAuthProvider`,
so it needs no extra package.

## Rate limiting

`/auth/firebase` is the only unauthenticated endpoint. Google guards its own SMS
spend, but a valid token still costs a database write, so the endpoint keeps a
per-IP hourly cap (`RATE_LIMIT_SIGNIN_PER_HOUR`).

## Tests

`tests/test_firebase_auth.py` — new user, returning user, adoption by phone and
by email, social-only (no phone), rejected token, deleted account, missing
project id, per-IP limit, and the log policy.

`test/firebase_sign_in_test.dart` — provider convergence, unregistered routing,
cancelled sheet, phone code exchange.

## Platform setup

The Firebase console must be configured before any of this works on a device.
The config files in the repo predate social sign-in, so they have to be
re-downloaded once the providers are enabled.

### Firebase console — done 2026-09-14

| Step | State |
|---|---|
| Authentication enabled | done — it had never been turned on; the project used FCM only |
| **Google** provider | enabled. Public-facing name `Doqto`, support email `lokesh@doqto.ai` |
| **Apple** provider | enabled (no Services ID needed for native iOS) |
| **Phone** provider | enabled |
| Android **SHA-1 + SHA-256** | registered on `com.doqto.app` from the upload keystore |
| **APNs auth key** | already present from FCM — key `YWRP5W2MHQ`, team `GBM6D48UJZ`, dev + prod |
| Test phone numbers | **none, deliberately** |

No fixed-code test numbers are registered: every number, without exception,
gets a real SMS from Google. A number listed as a Firebase test number stops
receiving real messages, which is the opposite of what we want.

**SMS quota.** Google rate-limits new projects to curb abuse. The project is on
the **Blaze** (pay-as-you-go) plan with a billing account linked, which raised
the cap:

| Plan | Sent SMS/day |
|---|---|
| Spark, no billing account | 10 |
| Blaze + billing account | 1,000 |
| **Identity Platform (current, since 2026-09-22)** | higher still |

A $25 budget **alert** is set (email at 50/90/100%). It is an alert, not a cap —
set a spend cap under Budgets if a hard ceiling is wanted.

Note what the cap is *not*: there is no origination identity to register, no
10DLC, no toll-free verification and no compliance profile. That is the whole
reason for this change.

### Still outstanding

1. ~~Google Cloud BAA~~ — accepted 2026-09-22 by lokesh@doqto.ai (IAM & Admin →
   Privacy & Security). ~~Identity Platform~~ — done 2026-09-22 (irreversible;
   free to 49,999 MAU).
2. **`GoogleService-Info.plist` / `google-services.json`** — both changed when
   Google sign-in and the SHA fingerprints were added, and must be
   re-downloaded. Google sign-in on iOS cannot work until the plist carries
   `CLIENT_ID` / `REVERSED_CLIENT_ID` and that scheme is in `Info.plist`.
3. ~~Billing account~~ — done: Blaze linked, 1,000 SMS/day.
4. **Sign in with Apple on the App ID.** The entitlement is in
   `ios/Runner/Runner.entitlements`; the project uses automatic signing and
   `ios_release.sh` archives with `-allowProvisioningUpdates`, so the next
   release build should enable the capability itself. Confirm on that build.
5. **Meta app + Business Verification** for Facebook.

### After enabling providers, re-download the config

`ios/Runner/GoogleService-Info.plist` has no `REVERSED_CLIENT_ID`, because
Google sign-in was not enabled when it was generated. Re-download both files
and replace them:

* `ios/Runner/GoogleService-Info.plist`
* `android/app/google-services.json`

Then add the Google callback scheme to `ios/Runner/Info.plist` —
`CFBundleURLTypes` already exists for the `doqto` scheme, so this is a second
entry whose `CFBundleURLSchemes` is the `REVERSED_CLIENT_ID` value verbatim.

### Apple

`com.apple.developer.applesignin = [Default]` is in
`ios/Runner/Runner.entitlements`. The capability still has to be enabled on the
App ID at developer.apple.com. Required by guideline 4.8 because Google and
Facebook are offered.

### Facebook

Needs a Meta app with **Business Verification** approved — days to weeks, and
the only provider that is gated on someone else's review. Once it exists, its
App ID and secret go into the Firebase Facebook provider, and the App ID plus
client token go into `ios/Runner/Info.plist` and
`android/app/src/main/AndroidManifest.xml` per `flutter_facebook_auth`'s setup.

Until then the Facebook button is on screen and will fail when tapped. Google,
Apple and phone do not depend on it.
