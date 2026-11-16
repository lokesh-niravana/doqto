# Settings — backend contract (batch 6)

Server side of the Settings programme: notification preferences that shape
APNs / FCM payloads, screenshot audit + org policy, linked-device sessions,
two-step PIN, change number, account export, status under the name, and the
unauthenticated app-metadata routes. Migration `0034_settings`.

Error codes are the `detail` string; the app maps them in
`lib/core/utils/error_messages.dart`. Every write below is rate-limited per
user (`enforce_rate_limit`) and audited; nothing here ever carries message
content (see `AuditAction` rows in [enums.md](enums.md)).

## Notification settings

`user_notification_settings` — one optional row per user; absent = defaults.

| Field | Default | Notes |
|---|---|---|
| `messages_tone` / `groups_tone` | `default` | One of `NOTIFICATION_TONES` (bundled CAF / raw names, plus `default` and `none`); 422 `tone_invalid` otherwise |
| `messages_vibrate` / `groups_vibrate` | `default` | `VibratePattern`; Android only |
| `messages_show_preview` / `groups_show_preview` | **off if the user is in an org** (unless every one of their orgs sets the batch 7 policy `show_preview_in_banners_default`), on otherwise | Stored nullable; NULL resolves per the rule on every read. An explicit choice sticks |
| `messages_high_priority` / `groups_high_priority` | `true` | Android `priority: high` vs `normal` |
| `reaction_notifications` | `true` | Off → reaction pushes are dropped server-side |
| `conversation_tones`, `haptics` | `true` | Client-side only; stored for sync |

- `GET /api/v1/users/me/notifications` → `NotificationSettingsOut` (effective values).
- `PATCH /api/v1/users/me/notifications` (partial; `{"reset": true}` deletes the row) → same shape.
  Changed field names are audited (`notification_settings_updated`) and the
  caller's own devices get WS `notification_settings_updated` with the full set.
  Idempotent: unchanged values produce no audit row and no event.

### How pushes use them (`push_service.py`)

Per recipient, per push:

| Push | Sound | Channel | Priority | Dropped when |
|---|---|---|---|---|
| new message, DM | `conversation_prefs.custom_tone` if set, else `messages_tone` | `messages` | `messages_high_priority` | chat muted / sender muted (unchanged) |
| new message, group | custom tone if set, else `groups_tone` | `groups` | `groups_high_priority` | same |
| mention | same tone rules as the chat | `messages` / `groups` | same | never — mute is bypassed on purpose |
| reaction | same tone rules as the chat | `messages` / `groups` | same | muted, **or `reaction_notifications: false`** |
| invitation received / accepted, invite joined, group invite, new sign-in | `default` | `invitations` | high | — |

`aps.sound` is `"default"`, `"<tone>.caf"` or absent (`none` = silent push).
FCM gets `android.notification.channel_id` and `android.notification.sound`
(the raw name without `.caf`). `fcm_message()` is pure and covered by
`tests/test_settings_batch6.py`. The Android app must create the three
channels on first launch; the tones must exist as
`ios/Runner/Resources/<tone>.caf` and `android/app/src/main/res/raw/<tone>`.

## Screenshot audit + org policy

- `POST /api/v1/audit/screenshot {conversation_id}` (auth, 30/min) → `{ok}`.
  Audit `screenshot_taken` with the conversation as resource. Non-members get
  404 `conversation_not_found`. iOS calls it from
  `userDidTakeScreenshotNotification`; Android never does.
- Org policy `block_screenshots` (default `false`) lives in
  `organizations.policies`, is set through
  `PATCH /orgs/{id}/settings/networking {block_screenshots}` (admin, audited
  `org_policy_changed`, fans out `org_updated`) and is returned in
  `policies` on every org payload. Android sets `FLAG_SECURE` in org chats
  when it is on.

## Linked devices (sessions)

Table `sessions`: `id, user_id, device_name, platform, app_version, ip,
refresh_jti, access_jti, pin_verified_at, created_at, last_seen_at,
revoked_at`. Redis `session:{jti}` / `session_refresh:{jti}` stay the live
gate; the row is the durable list and audit anchor.

- `POST /auth/firebase` now accepts optional `device_name` (≤ 80),
  `platform` (`ios`|`android`), `app_version` (≤ 32). The response gains
  `session_id`, `pin_required`, `pin_clears_at`.
- Every sign-in creates a row (access and refresh jti start equal).
  `POST /auth/refresh` rotates both jtis on the same row and bumps
  `last_seen_at` (so "last active" is refresh-granular, ~hourly).
  `POST /auth/logout` stamps `revoked_at`.
- A **registered** user signing in while other sessions are alive gets, on
  their other devices: an in-app notification (`type: new_sign_in`,
  payload `{device_name, platform}`), WS `session_created`, and a push
  **"New sign-in on <device_name>"** (`"New sign-in on another device"` when
  unnamed; data `{type: new_sign_in, session_id}`). A device model is not PHI.
- `GET /users/me/sessions` → `[SessionOut]` newest activity first, `current`
  on the one behind the request's token.
- `DELETE /users/me/sessions/{id}` → `{ok}`; 404 `session_not_found` for
  anyone else's. Deletes the Redis keys, stamps `revoked_at`, audits
  `session_revoked`, fans WS `session_revoked {session_id}` to the user's
  devices. Revoking the current session is allowed (same as logout).
- `POST /users/me/sessions/revoke-others` → `{revoked: n}`; keeps the caller.
- A revoked device's next HTTP call answers **401 `session_revoked`** (the
  code the app already wipes on); refresh answers the same. An open socket
  is not force-closed; it hears `session_revoked` and the client drops it.

## Two-step PIN

6 digits, bcrypt-hashed in `users.pin_hash`. Required once per **new
device** — a `(device_name, platform)` pair this user has never signed in
from (an unnamed device always counts as new) — after OTP.

- `PUT /users/me/pin {pin, current_pin?}` → `{pin_enabled: true}`. Changing
  needs `current_pin` (401 `pin_invalid`). Setting it opens the gate on every
  live session (the person typing it is the owner).
- `DELETE /users/me/pin {pin}` → `{pin_enabled: false}`; 409 `pin_not_set`.
- `GET /users/me/pin` → `{pin_enabled, pin_clears_at}`. `GET /users/me` also
  carries `pin_enabled` / `pin_clears_at`.
- Sign-in / refresh on a device that owes the PIN: tokens are issued with
  `pin_required: true`; every other route (and the WebSocket) answers
  **403 `pin_required`** until
  `POST /auth/pin/verify {pin}` succeeds for that session (401
  `pin_invalid`; 429 `pin_too_many_attempts` after 5 wrong tries in 15
  minutes, per user). Only `/auth/pin/verify`, `/auth/pin/reset-request`,
  `/auth/refresh` and `/auth/logout` are reachable while pending.
- Forgot PIN: `POST /auth/pin/reset-request` → `{pin_enabled: true,
  pin_clears_at}` stamps `users.pin_reset_at`; the settings loop clears the
  PIN (and opens all pending gates) once 7 days have passed, auditing
  `pin_reset_completed`. Idempotent; entering the right PIN cancels it.
  No email / SMS is involved by design.

## Change number

`PATCH /users/me/phone {id_token}` (5/hour). Firebase verifies the new number
on the device (`updatePhoneNumber`); the refreshed ID token's `phone_number`
claim is the proof. Same rules as the sign-up link (`POST` on the same
path): the token must belong to this account (403 `firebase_uid_mismatch`),
must carry a phone (400 `phone_not_verified`), and the number must be free
(409 `phone_already_registered`). Audited `phone_changed` with no number in
the row. Returns the full `UserOut`.

## Account info export

`POST /users/me/export` (3/hour) → `{url, expires_at}` — a 10-minute
presigned URL to `exports/{user_id}/{uuid}.json` holding `profile`,
`settings {privacy, notifications, two_step_pin_enabled}`, `organizations`,
`connections` (ids + names + specialty), `groups` (id, name, role).
**Never messages.** Audited `account_exported`. Objects are not purged
automatically (SSE at rest; bucket lifecycle rule recommended).

## Status under the name

`users.status_text` (≤ 40) + `status_expires_at`.

- `PATCH /users/me/status {preset?, text?, expires_in_sec?}` → `StatusOut
  {status_preset, status_text, status_expires_at}`. `preset` is a
  `StatusPreset`; `text` is custom (trimmed, ≤ 40); sending both is 422;
  `expires_in_sec` ∈ {3600, 28800, 86400} or null for never; `{}` clears.
- Exposed on `GET /users/me`, `GET /users/{id}/profile` and
  `GET /users/presence` (not gated by last-seen visibility — it is
  directory data like a headline). An expired status reads as cleared even
  before the loop clears it. Changes fan `profile_updated` to the audience.
- Audited `status_updated` with `{preset, custom: bool, expires_in_sec}` —
  never the custom text.

## App metadata (no auth)

- `GET /api/v1/app/min-version` → `{ios: "1.0.0+45", android: "1.0.0+35",
  message}` from `MIN_VERSION_IOS` / `MIN_VERSION_ANDROID` /
  `MIN_VERSION_MESSAGE` env (defaults in `config.py`). The app compares the
  build number after `+` and shows the force-update screen when below.
- `GET /api/v1/app/legal` → `{help, contact, terms, privacy, hipaa}` from
  `LEGAL_URLS` in `constants.py`.

## Background job

`_settings_jobs_loop` in `main.py` (every `DISAPPEAR_PURGE_INTERVAL_SEC`,
Redis-locked): clears expired statuses (then `profile_updated` per user),
completes lapsed PIN resets and stamps lapsed break-glass windows expired
(batch 7, see compliance.md).
