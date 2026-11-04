
## Encryption key management (pre-production TODO)

`MESSAGE_ENCRYPTION_KEY` is currently a single static AES-256-GCM key in the
environment. Before signing any BAA / going to production:

1. Move the key to a KMS (AWS KMS) — envelope encryption: KMS master key wraps
   per-deployment data keys; app only ever sees the data key.
2. Add key rotation: version-prefix ciphertexts (`v1:` …) so old messages
   decrypt with the retiring key while new writes use the current one.
3. Consider per-org data keys so one org's compromise can't expose another's.

Message bodies AND voice-note transcripts are AES-256-GCM encrypted at rest
(migration 0008). S3 objects rely on bucket-level SSE, and every `put_object`
also sets `ServerSideEncryption=AES256` explicitly.

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
   WS auth is auth-frame only — tokens never appear in URLs or proxy logs.

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

Not done: app-level encryption of the cached files on top of OS encryption,
and a remote wipe for a lost phone beyond revoking the session.

## Deferred items (documented, accepted for now)

- **Audit rows share the request transaction**: a rolled-back request drops
  its audit rows. Coupling audit writes to a separate transaction/outbox is
  deferred until there's an ops story for it.
- **Media checksums**: no application-level checksum on S3 media. AES-GCM
  authenticates text/transcripts; S3 ETag/SSE covers media integrity at rest.
- **Break-glass emergency access**: N/A at current scale (no clinical
  dependence on the system; solo-operator recovery via infra access).
- **Account deletion / PHI purge endpoint**: TODO before public launch —
  message content purge exists (30-day grace crypto-shred of deleted/expired
  messages + S3 disposal), but a full "delete my account and PHI" flow does not.
