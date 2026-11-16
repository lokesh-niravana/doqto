# Media (batch 5) — API notes

Backend contract for captions, video, voice-note waveforms, large uploads
through presigned S3 URLs, the per-chat media gallery, the save/share export
gate and polls. Routes live in `app/core/routes.py` (mirrored in
`lib/core/constants/api_routes.dart`); error codes are the `detail` string.
Every mutation emits a WS event (`docs/enums.md` → WsEventServer) and stamps
`messages.changed_at` where it changes a message. Pushes never carry message
text: media and polls use the plain "New message" / "<name> sent you a message"
banner; a vote sends no push.

Migration: `0033_media` (adds `messages.caption_encrypted / thumb_key /
waveform / media_width / media_height / poll_multiple`, tables `poll_options`,
`poll_votes`, `upload_intents`).

## Constants

| Constant | Value | Notes |
|---|---|---|
| `FILE_MAX_BYTES` / `VIDEO_MAX_BYTES` | 100 MB | presigned flow |
| `UPLOAD_INLINE_MAX_BYTES` | 25 MB | legacy `POST /messages/upload/{conv}` (body read into memory) |
| `UPLOAD_PART_SIZE_BYTES` | 8 MB | multipart above this size; one PUT at or below it |
| `UPLOAD_INTENT_TTL_SEC` | 1 h | presigned URLs expire with the intent; the purge job aborts leftovers |
| `THUMB_MAX_BYTES` | 300 KB | JPEG poster for a video |
| `CAPTION_MAX_LEN` | 1024 | |
| `VIDEO_MAX_DURATION_SEC` | 10 min | |
| `VOICE_NOTE_WAVEFORM_MAX_BYTES` | 64 | raw amplitude bytes, base64 on the wire |
| `MEDIA_PAGE_SIZE` | 60 | gallery page |
| `POLL_OPTIONS_MIN/MAX`, `POLL_QUESTION_MAX_LEN`, `POLL_OPTION_MAX_LEN` | 2–12, 300, 100 | |
| Rate limits | upload-intent / complete 30/min, vote 60/min, export-audit 60/min, gallery 120/min | `enforce_rate_limit` |

## MessageOut additions

`caption` (image / video / file / voice — encrypted at rest, copied on forward,
shredded on delete / purge), `thumb_key` (video poster), `waveform` (base64,
voice notes), `media_width` / `media_height`, `poll` (see below).
`voice_duration_sec` doubles as the video length. The chat-list
`last_message_preview` is the caption for captioned media and the question for
a poll; a reply quote on a captioned message shows the caption, on a video
"Video", on a poll the question.

## A. Inline upload (unchanged route, more fields)

`POST /messages/upload/{conversation_id}` — multipart/form-data, member only
(404 `conversation_not_found` / 403 `not_a_conversation_member`).

| Part | Notes |
|---|---|
| `file` | `image/*` → `image`, `video/*` → `video`, else `file`. ≤ 25 MB (413 `file_too_large`) |
| `client_id` | idempotency key (retry returns the original row) |
| `caption` | ≤ 1024 (422 `caption_too_long`) |
| `thumb` | JPEG poster, video only, ≤ 300 KB (422 `thumb_too_large`); ignored on non-video |
| `duration_sec` | video length (422 `video_too_long` over 10 min) |
| `width`, `height` | pixel size |

Images (and the poster) are **EXIF/XMP/IPTC-stripped server-side** before
they reach S3 (`app/services/image_service.py`): JPEG and PNG losslessly by
dropping the metadata segments/chunks, other formats re-encoded through Pillow.
The client strips too; this is defence in depth.

`POST /messages/voice-notes/{conversation_id}` additionally takes `waveform`
(base64 of ≤ 64 bytes, 422 `waveform_invalid`) and `caption`.

`GET /messages/{id}/file-url?thumb=1` returns the presigned URL of the poster
(404 `file_not_found` when the message has none).

## B. Presigned multipart upload (files / video ≤ 100 MB)

The API container has no ffmpeg, so the **client supplies the JPEG poster**
for a video (`with_thumb` → `thumb_put_url`); the server scrubs and stores it as
`thumb_key`. Flow:

1. `POST /messages/upload-intent/{conversation_id}` (member, 30/min)
   body `{file_name, content_type, size_bytes, client_id?, with_thumb?}` →
   ```json
   {"intent_id": "...", "type": "video", "key": "files/<org>/<msg>/clip.mp4",
    "part_size": 8388608, "expires_in": 3600,
    "put_url": null, "upload_id": "…", "part_urls": [{"part_number": 1, "url": "…"}, …],
    "thumb_put_url": "…", "message": null}
   ```
   `size_bytes ≤ 8 MB` → a single `put_url` (PUT the whole body with the
   declared `Content-Type`); above it → `upload_id` + one URL per `part_size`
   slice (last part shorter), PUT each and keep the `ETag` response header.
   Errors: 413 `file_too_large` (declared size over the cap), 422
   `thumb_not_allowed` (`with_thumb` on a non-video). A `client_id` that was
   already sent returns `message` (the existing `MessageOut`) and nothing to
   upload.
2. `POST /messages/upload-complete/{conversation_id}` body
   `{intent_id, parts: [{part_number, etag}], caption?, duration_sec?, width?, height?, has_thumb?}`
   → `MessageOut`. The server completes the multipart upload (all parts, 422
   `upload_parts_invalid`), verifies the object (409 `upload_missing`; 413
   `file_too_large` deletes an oversize object), strips image metadata,
   validates the poster (oversize poster is dropped, not fatal), creates the
   message, audits `file_uploaded`, fans out `new_message` and pushes.
   Idempotent: completing the same intent again returns the same message
   without a second fan-out. Errors: 404 `upload_intent_not_found` (unknown,
   other user's or other conversation's intent), 409 `upload_intent_expired`,
   422 `video_too_long`.

Intents past their TTL are deleted by the purge loop, which aborts the S3
multipart upload (or deletes a half-uploaded single object and poster).

## C. Media gallery

`GET /conversations/{id}/media?type=image|video|file|link&cursor=&limit=`
(member, 120/min) → `{data: [{message: MessageOut, urls: [str]}], next_cursor}`,
newest first, cursor = `seq` of the last row (400 `invalid_cursor`, 422
`invalid_media_type`). Honours the caller's "delete for me" hides and the
clear-chat cursor; tombstones and expired rows never appear. `type=link`
scans text messages (decrypted server-side, newest first, at most 2000 per
request) and returns those containing `http(s)://` URLs in `urls`; the page may
be short with a `next_cursor` when the scan cap is hit. Each call writes one
`conversation_accessed` audit row (meta: `media`, `cursor`, `count`).

## D. Save to Photos / share — export gate

Org policy `allow_media_export` (`organizations.policies`, default **false**),
set by an org admin through `PATCH /orgs/{id}/settings/networking`
`{allow_media_export: true}` (audited `org_policy_changed`, `org_updated` WS).

Effective rule per conversation (returned as `ConversationOut.media_export_allowed`
so the client can hide the buttons):

* org chat → that org's policy;
* network (cross-org) chat → the strictest policy among the caller's own orgs;
  a caller with no org may export.

`POST /messages/{id}/export-audit` (60/min) — the client calls it **before**
saving or opening the share sheet. 200 `{ok}` + audit `file_exported`
(meta: `type`, `conversation_id`); 403 `media_export_blocked` → do not export;
404 `message_not_found` for outsiders, 404 `file_not_found` for a message with
no media.

## E. Polls

Create: `POST /conversations/{id}/messages` with
`{"type": "poll", "poll": {"question", "options": [2..12], "multiple": false}, "client_id"?, "reply_to_id"?}`
(same send gates as text: post policy, block/connection checks). Options are
trimmed, non-empty, case-insensitively unique (422 otherwise). The question is
the encrypted body (`content`); options are encrypted rows in `poll_options`.
Polls cannot be forwarded (409 `message_not_forwardable`); deleting one shreds
its options and votes.

`MessageOut.poll`:
```json
{"question": "Lunch?", "multiple": false, "voter_count": 2,
 "options": [{"id": "…", "position": 0, "text": "Pizza", "vote_count": 1, "voter_ids": ["…"]}, …]}
```
Votes are visible to every member (no anonymous polls).

* `PUT /messages/{id}/vote` `{option_ids: [...]}` — replaces the caller's
  selection; single-choice polls take exactly one id (422
  `poll_single_choice`), ids must belong to the poll (422 `poll_option_invalid`).
  Same selection again = 200, no event.
* `DELETE /messages/{id}/vote` — withdraws all of the caller's votes (no-op
  when none).
* Both: 404 `message_not_found` (outsider / gone), 422 `not_a_poll`, 409
  `message_deleted`; audit `poll_voted`; `changed_at` stamped so
  `changed_since` catch-up sees the new tallies.
* WS `poll_updated` `{conversation_id, message_id, poll, changed_at, actor_id}`
  to every member whenever the tallies change — including when a member who
  leaves / is removed from a group takes their votes with them.

## Retention

Delete-for-everyone, the 30-day purge and account deletion all null
`caption_encrypted`, `waveform`, `thumb_key` (the poster object is deleted with
the media object) and drop `poll_options` / `poll_votes`. Forwarded copies get
their own poster object (`thumbs/<org>/<copy id>.jpg`).

## Not done server-side (deferred)

* No server-generated video poster (no ffmpeg in the image) — client-supplied.
* No transcoding / duration probing: `duration_sec`, `width`, `height` are
  trusted client metadata (bounded by validation).
* Link previews for gallery links reuse `GET /link-preview` from batch 4.
