# Security posture (refreshed, batch 7)

What the backend does to protect PHI, where the keys live, what gets kept
and for how long, and how an administrator may ever read a conversation.
The wire contract for the compliance routes is in [compliance.md](compliance.md);
settings/sessions in [settings.md](settings.md).

## Encryption at rest — key management

Message bodies, captions, voice-note transcripts, poll questions/options,
edit history and scheduled drafts are AES-256-GCM encrypted in Postgres.
Since batch 7 this is **envelope encryption** (`app/core/crypto.py`):

| Layer | What | Where |
|---|---|---|
| Data keys | one AES-256 key per organisation (`org:<uuid>`) and one shared `network` key for conversations with no org | `data_keys` rows, stored **wrapped** |
| Master key | AWS KMS CMK when `AWS_KMS_KEY_ID` is set (`kms:Encrypt`/`kms:Decrypt`, encryption context `{"scope": ...}`); otherwise the static `MESSAGE_ENCRYPTION_KEY` wraps the data keys | KMS, or the environment |
| Row pointer | `key_version` on `messages`, `message_edits`, `scheduled_messages`, `poll_options` names the `data_keys.version` that protects the row | the row |

* `key_version = 0` is the **legacy** format (ciphertext under the static key
  directly, migration 0008). Legacy rows keep decrypting; the first write to
  a row (edit, transcript arrival) moves every encrypted field of that row to
  the scope's active key. `scripts/rotate_keys.py rewrap` finishes the
  migration in the background.
* Unwrapped data keys are cached in-process; a version first seen in a
  replica is fetched and unwrapped once (sync call sites load it on a helper
  thread). `data_keys` holds no plaintext.
* **Rotation**: `scripts/rotate_keys.py rotate` retires the active key per
  scope and mints a new one (audited `key_rotated`); replicas pick it up
  within 60 s; old versions stay readable. `rewrap` then re-encrypts rows in
  batches; `status` reports versions and how many rows are still on version 0;
  `to-legacy` is the escape hatch before an Alembic downgrade.
* **Going to KMS in prod** (ops, not yet done): create a symmetric CMK, grant
  the ECS task role `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey`, set
  `AWS_KMS_KEY_ID`, deploy, run `rotate` (new keys are KMS-wrapped; each
  `data_keys` row remembers its wrapper, so static-wrapped keys keep working)
  and `rewrap`. Nothing in code needs KMS to run — local, CI and tests use the
  static wrapper (a fake KMS client is exercised in `tests/test_compliance.py`).
* One org's key compromise cannot expose another org's rows. The WebSocket
  pub/sub envelope (transient, Redis) still uses the static key.
* S3 objects: bucket SSE plus `ServerSideEncryption=AES256` on every put.

## Audit trail — durable and tamper-evident

* Every `AuditService.log()` writes its row in **its own short transaction**
  and commits before returning (batch 7). A request that later fails or rolls
  back still leaves its attempt behind. This was chosen over an after-commit
  outbox because it needs no worker, cannot lose rows on process death, and
  the cost (one extra pooled connection per audited call) is negligible at
  our scale. `audit_logs.user_id` is therefore no longer a foreign key — the
  row may precede the user's own commit and must outlive the user.
* Rows are chained: dense `seq` assigned under a Postgres advisory lock,
  `prev_hash` = previous row's hash (64 zeros for the first), `hash` =
  sha256(prev_hash + canonical JSON of the row minus the hash fields, keys
  sorted, UUIDs/timestamps as strings). `scripts/verify_audit_chain.py`
  walks the chain and exits non-zero at the first break — run it from cron.
  Rows that predate 0035 are numbered but unhashed and accepted only as a
  prefix.
* Read API: `GET /admin/audit` (super-admin, whole trail) and
  `GET /orgs/{id}/audit` (org admin: members' actions on org-scoped
  resources, no IP / user agent). Rows never contain message bodies; reading
  the trail is itself audited (`audit_read`).
* Retention: audit rows are never deleted (HIPAA §164.316(b)(2), six years).

## Retention, legal hold, deletion

| Mechanism | Effect |
|---|---|
| Disappearing messages (per chat) | `expires_at` → hidden by the purge loop → content shredded 30 days later (`PURGE_CONTENT_GRACE_SEC`), S3 objects deleted |
| Org `retention_days` (batch 7) | the purge loop expires every message in the org's conversations older than N days (`retention_applied` audit); same hide → grace → shred pipeline |
| Delete for everyone | tombstone + immediate shred of body / media / edits / poll options |
| Account deletion (**done**, App Store 5.1.1(v)) | `DELETE /users/me`: audit first, then the user's messages are tombstoned and shredded, memberships / graph / tokens / scheduled drafts / receipts removed, identity fields rewritten, `deleted_at` set; the tombstone row stays for the audit trail and sign-in is refused (`401 account_deleted`) |
| Org `legal_hold` (batch 7) | pauses **every** shred for that org's conversations: the 30-day purge, delete-for-everyone (members see a bare tombstone, the row keeps its content and S3 keys) and the account-deletion shred (the user's rows are hidden, not destroyed). Retention is paused too. Lifting the hold lets the next purge pass catch up. Documented behaviour: a held conversation can be read only through break-glass. |

## Break-glass (emergency access)

An org admin can never open a conversation directly. `POST
/orgs/{id}/access-requests {conversation_id, reason}` files a request for a
conversation that is the org's own or has an org member in it; a
**different** org admin approves (self-approval is refused) and the
requester gets a 24 h window on `GET
/orgs/{id}/access-requests/{rid}/messages`. Every page is audited
`break_glass_read`; the first page posts the system line *"An administrator
accessed this conversation under policy"* into the conversation so its
members know; both admins are notified (feed, WS `access_request_updated`,
PHI-free push). Reads under legal hold include tombstoned content — the one
place it is visible. Expired windows are refused and stamped by the job.

## Sessions and devices

* Access tokens 1 h, refresh 7 d, both backed by Redis keys (`session:{jti}`
  / `session_refresh:{jti}`) so revocation is immediate; `sessions` rows are
  the durable device list (`GET /users/me/sessions`, revoke one / all
  others). A revoked device's next call gets `401 session_revoked`, which the
  app treats as a remote wipe (Hive + media cache). New sign-ins notify the
  user's other devices. Two-step PIN gates new devices (see settings.md).
* WebSocket auth is a first frame, never a query string, so tokens are not
  in proxy logs.
* Rate limits on every write (`enforce_rate_limit`), admin login lockout.

## Production transport requirements

In-transit encryption is a config concern — nothing in code enforces it, so
production deployments MUST set:

1. **Postgres**: append `?ssl=require` to `DATABASE_URL`
   (`postgresql+asyncpg://…/doqto?ssl=require`). Prefer `verify-full` with the
   provider CA bundle when available.
2. **Redis**: use a `rediss://` URL (TLS) with a strong password. The local
   compose `redis://:password@` form is dev-only.
3. **HTTP/WebSocket**: terminate TLS in front of uvicorn (ALB/nginx/Caddy);
   the app must never be reachable over plain `http://`/`ws://` outside local.
4. **Universal links**: proxy `https://doqto.ai/.well-known/apple-app-site-association`
   and `/.well-known/assetlinks.json` to the API (served from
   `app/api/v1/well_known.py`; team `3N7394B3B9`, bundle `com.doqto.ios`,
   paths `/g/*`, `/c/*`, `/u/*`). The Android fingerprints list is empty
   until ops fills `ANDROID_CERT_SHA256_FINGERPRINTS`.

## PHI on the device

Chat text lives in an encrypted Hive box; queued uploads live in the app's
documents folder. Both are wiped when a session ends (sign-out, revoked
session, account deletion).

Chat photos are kept on the phone after the first view, as every clinical
messenger does, under these safeguards (`lib/data/services/chat_media_cache.dart`):

- **Keyed by message id.** Downloaded once through a 5-minute presigned URL,
  then read from disk. A URL is only requested on a miss.
- **App-private, not backed up.** The OS cache directory, which iCloud and
  Android Auto Backup skip. Never written to the photo gallery.
- **Locked-device protection.** On iOS the folder and every file carry
  `NSFileProtectionComplete` (native channel `doqto/file_protection` in
  `AppDelegate.swift`), so they are unreadable while the phone is locked.
  Android keeps app-private files in credential-encrypted storage.
- **Bounded.** Evicted after 30 days unused or past 500 photos. The OS may
  also purge it under storage pressure; a purged photo downloads again.
- **Wiped** with the rest of the session's PHI, and evicted when its message
  is deleted or hidden. The wipe also empties the shared default image cache
  where builds up to 41 stored chat photos by URL.

Chat documents get the same safeguards in their own store
(`lib/data/services/chat_document_store.dart`), kept under their real file name
because viewers choose the format from the extension. The name comes from the
sender, so it is reduced to one safe path segment. Unused documents go after 30
days; there is no count limit.

Documents are rendered on the device and never sent to a viewing service:

- **iOS:** Apple's QuickLook inside the app, for every format it knows. Its
  share button can still export a file. QuickLook offers no supported way to
  remove it.
- **Android PDF:** the platform's `PdfRenderer` inside the app.
- **Android Word, Excel and the rest:** Android has no built-in renderer, so
  the file opens in an installed app, only after a prompt saying it is leaving
  Doqto. `FileProvider` grants that app read access to the one file. From then
  on Doqto cannot protect that app's copy, and neither the wipe nor eviction
  reaches it.

Org policies the app enforces client-side (`allow_copy`, `allow_media_export`,
`block_screenshots`, banner previews) are stored and, where observable,
enforced server-side as well — see compliance.md.

## Still open

- **KMS in production**: code is ready; the CMK, task-role grant and
  `AWS_KMS_KEY_ID` are an ops step (above). Until then the static key wraps
  the per-org data keys.
- **Media checksums**: no application-level checksum on S3 media. AES-GCM
  authenticates text/transcripts; S3 ETag/SSE covers media integrity at rest.
- **App-level encryption** of cached files on top of OS encryption; remote
  wipe for a lost phone beyond revoking the session (the app wipes on
  `session_revoked` / `account_deleted`).
- **Android assetlinks fingerprints** and the iOS associated-domains
  entitlement are app/ops steps; the backend routes are live.
- The pub/sub envelope and `verify_boot_secrets` still require the static
  `MESSAGE_ENCRYPTION_KEY`; it remains a required secret even with KMS.
