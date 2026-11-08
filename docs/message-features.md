# Message features (batch 4) — API notes

Backend contract for reply/quote, forward, star, pin, mentions, link previews,
longer edit/delete windows, admin delete, jump-to-date and message reports.
Routes live in `app/core/routes.py` (mirrored in
`lib/core/constants/api_routes.dart`); error codes are the `detail` string.
Every mutation emits a WS event (`docs/enums.md` → WsEventServer) and stamps
`messages.changed_at` where it changes a message, so `changed_since` catch-up
sees it. Pushes never carry message text.

Migration: `0032_message_features` (adds `messages.reply_to_id / forwarded /
forward_depth / mentions`, table `message_stars`, `conversations.pinned_message_id /
pinned_until / pinned_by`, `organizations.policies` JSONB,
`reports.context_message_ids / resolved_by / resolved_at`).

## Windows and constants

| Constant | Value | Notes |
|---|---|---|
| `MESSAGE_EDIT_WINDOW_SEC` | 15 min | sender only, text only |
| `MESSAGE_DELETE_WINDOW_SEC` | 48 h | sender; **group admins are not window-bound** |
| `FORWARD_MAX_DESTINATIONS` | 5 | per call |
| `FORWARD_MAX_DEPTH` | 5 | copies at depth ≥ 5 cannot be forwarded again |
| `PIN_DURATIONS_SEC` | 24 h / 7 d / 30 d | default 30 d |
| `STARRED_PAGE_SIZE` | 50 | |
| `LINK_PREVIEW_*` | 5 s, 1 MB page, 50 KB image, 3 redirects, 24 h cache | |
| Rate limits | forward 20/min, star 60/min, pin 20/min, link preview 30/min | `enforce_rate_limit` |

## A. Reply / quote

`POST /conversations/{id}/messages` accepts `reply_to_id`. The target must be a
live message **in the same conversation** (not expired, not a tombstone), else
`422 reply_target_invalid`.

`MessageOut.reply_to_id` is stored; `MessageOut.reply_to` is rebuilt from the
target's current row on every read and in every fan-out:
`{id, sender_id, type, preview}` — text → first 140 chars; image → `Photo`;
voice → `Voice note`; file → file name; tombstone → `Message deleted`; expired
or purged → `reply_to: null` (the `reply_to_id` stays).

## B. Forward

`POST /messages/{id}/forward` body `{conversation_ids: [≤5]}` → `200 [MessageOut]`
(one copy per distinct destination). Each copy is a normal new message sent by
the forwarder: own row, own seq, re-encrypted body, **copied S3 object** (new
key under the destination's namespace; never a shared key), `forwarded=true`,
`forward_depth = source + 1`, no quote, no mentions. Destinations receive
`new_message` + the standard push. All-or-nothing: every destination is
authorised before anything is written.

| Code | Status | When |
|---|---|---|
| `message_not_found` | 404 | unknown id, OR caller not a member of the source conversation |
| `conversation_not_found` | 404 | a destination the caller is not in |
| `message_deleted` | 409 | source is a tombstone |
| `message_not_forwardable` | 409 | system message |
| `forward_limit` | 422 | source `forward_depth ≥ 5` |
| `forward_blocked_by_org` | 403 | source is an org conversation whose org set `allow_forward_outside_org=false` and a destination is outside that org |
| `post_restricted` | 403 | destination group is admins-only |
| `conversation_not_open` | 403 | destination is a pending/declined request thread |
| `not_reachable` / `not_connected` / `group_dm_*` | 403 | the direct-chat send gate (blocks are never observable) |

Audit: `message_forwarded` (source + destinations + copy ids) plus one
`message_sent` per copy with `forwarded_from`.

### Org policies

`organizations.policies` JSONB, defaults in `ORG_POLICY_DEFAULTS`
(`allow_forward_outside_org: true`, `allow_copy: true`). Org admins set them via
`PATCH /orgs/{org_id}/settings/networking` with `allow_forward_outside_org` /
`allow_copy`; audited as `org_policy_changed`. Effective values (defaults filled)
come back as `policies` on `OrgOut` (`GET /orgs/mine`) and on the settings
response. `allow_copy` is enforced by the client (hide Copy); the server stores it.
Batch 7 added a dedicated `GET/PATCH /orgs/{id}/policies` and four more keys
(banner previews, default timer, retention, legal hold) — see
[compliance.md](compliance.md).

## C. Star

* `PUT /messages/{id}/star` / `DELETE /messages/{id}/star` → `200 MessageOut`
  (with `starred` set for the caller). Idempotent. Private: only the caller's
  own devices get `message_starred {conversation_id, message_id, starred}`.
  404 `message_not_found` for outsiders / unknown ids, 409 `message_deleted`
  for tombstones, 409 `message_not_starrable` for system messages.
* `GET /messages/starred?cursor=&limit=` → `{data: [{message, conversation_id,
  conversation_type, conversation_name, starred_at}], next_cursor}` newest star
  first across every conversation; `cursor` = last `starred_at`. Audited
  (`starred_messages_read`, one row per page).
* Stars never extend retention: deleting for everyone drops the message's
  stars; the purge loop's `purge_orphan_stars` removes stars on expired/purged
  messages; the list already filters them out.
* `MessageOut.starred` is the only per-viewer field: true on the viewer's own
  reads (thread page, starred list), always false in fan-outs.

## D. Pin

* `PUT /conversations/{id}/pin` body `{message_id, duration_sec}` (`duration_sec`
  ∈ 86400 / 604800 / 2592000, default 30 d) → `200 ConversationOut` with
  `pinned_message_id`, `pinned_until`. Replaces any current pin.
* `DELETE /conversations/{id}/pin` → `200 ConversationOut` (no-op if nothing pinned).
* Roles: direct — either member; network group — owner/admin
  (`403 not_authorized`); legacy org group chat (no `groups` row) — any member.
* Errors: `404 message_not_found` (unknown, outsider, or message from another
  conversation), `422 invalid_pin_duration`, `409 message_deleted`,
  `409 message_not_pinnable` (system).
* WS: `message_pinned {conversation_id, message_id, pinned_until, actor_id}`,
  `message_unpinned {conversation_id, message_id, pinned_until: null, actor_id}`
  (`actor_id: null` when the job cleared it) to every member.
* Reads treat an expired pin as no pin; the purge loop (`expire_pins`) clears
  it for real and fans out `message_unpinned`. Deleting the pinned message
  clears the pin.
* `ConversationOut` (list / create / pin responses) carries `pinned_message_id`
  and `pinned_until`, plus `group_id` (the `groups` row of a network group
  chat; null for direct and legacy org group chats) so a thread opened from
  the chat list can load members for @mentions and admin actions.

## G. Delete for everyone

`DELETE /messages/{id}` — sender within 48 h, **or any group admin at any age**
(network group owner/admin; legacy org group: org admin). An admin delete also
posts the system line `Admin removed a message` (fanned out as `new_message`)
and audits `message_deleted` with `{by_admin: true, sender_id}`. Direct chats
have no moderator (`403 not_message_sender`).

## H. Mentions

Text bodies carry `@[<user uuid>]` tokens. The server parses them
(`MENTION_TOKEN_PATTERN`), requires every id to be a conversation member
(`422 mention_not_member`, `422 too_many_mentions` above 50) and stores
`messages.mentions`; `MessageOut.mentions` lists the ids. Push: mentioned
members get **`<sender name> mentioned you in <group name>`** (or
`<sender name> mentioned you` in a direct chat; `You were mentioned` if the
name is unavailable) with `data {type: mention, conversation_id}` and the
conversation's collapse key, **instead of** the generic new-message push, so
the client's per-chat mute cannot swallow it. Never the message text.

## I. Link previews

`GET /link-preview?url=` → `200 {url, title, description, site_name,
image_data_url}`. Server-side fetch (`app/services/link_preview_service.py`):

* http(s) only, no credentials, ports 80/443 only; literal IPs and every
  resolved address must be public unicast (loopback, private, link-local,
  multicast, reserved, IPv4-mapped and `localhost/.local/.internal` names are
  refused) — re-checked on each of ≤3 redirects; 5 s timeout; 1 MB streamed cap.
* og:* → `<title>` / meta description; og:image fetched the same way, inlined
  as a base64 `data:` URL ≤ 50 KB (omitted if bigger/unavailable).
* Cached 24 h in Redis (`link_preview:<sha256(url)>`).
* `403 link_previews_disabled` when the caller's `privacy.link_previews` is off;
  `422 invalid_url | url_not_allowed | too_large`; `404 fetch_failed | not_html`.
* Audited `link_preview_fetched` with the host only.

## K. Jump to date

`GET /conversations/{id}/messages?before_date=YYYY-MM-DD` — the usual
descending page ending at the end of that UTC day (`400
before_and_before_date_exclusive` with `before`).

## M. Reports

`POST /network/reports` body `{subject_type: user|message, subject_id, reason,
details?, context_message_ids?: [≤5]}` → `201`. `reason` ∈ ReportReason
(`spam | harassment | phi_misuse | impersonation | other`). Message reports
require the reporter to be a member of the message's conversation
(`404 message_not_found` otherwise — no oracle); context ids are filtered to
that conversation and stored as **ids only**. User reports: `404
user_unavailable` for self / unknown.

Super-admin moderation (`require_super_admin`):

* `GET /admin/reports?status=open|reviewing|actioned|dismissed|all&cursor=&limit=`
  → `[ReportOut]` newest first (default `open`). `ReportOut` has ids, reason,
  details, status, `context_message_ids`, `resolved_by/at` — never bodies.
* `PATCH /admin/reports/{report_id}` body `{status}` → `200 ReportOut`; any
  transition allowed; `actioned`/`dismissed` stamp `resolved_by/at`, moving back
  clears them. Audited `report_status_changed {from, to}`. `404 report_not_found`.
