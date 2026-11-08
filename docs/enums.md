# Doqto — Cross-Stack Enum Contract

> Single source of truth for every enum shared between Flutter and FastAPI.
> Wire values (right column) are the JSON representation — these MUST match exactly on both sides.
> A CI gate (`scripts/check_enum_parity.py`) compares this file to `app/core/enums.py` (Python) and `lib/core/enums/*.dart` (Dart) on every build.

## Rules

1. **Wire values are `snake_case` lowercase strings.** No camelCase on the wire.
2. **Dart enum names are `camelCase`** (Dart idiom), mapped to wire via `@JsonValue('...')`.
3. **Python enum values ARE the wire strings** (use `StrEnum`). Member names can be UPPER_SNAKE.
4. **Adding a value:** update this file → update `enums.py` → update `enums/*.dart` → parity check passes.
5. **Removing a value:** add a migration — never silently drop. Mark deprecated here first.
6. **Reordering:** fine for humans, irrelevant for wire.

---

## UserRole

| Wire value | Meaning |
|---|---|
| `doctor` | Standard doctor account |
| `super_admin` | Platform operator who verifies orgs |

## OrgStatus

| Wire value | Meaning |
|---|---|
| `pending` | Awaiting super-admin verification |
| `active` | Verified and operational |
| `suspended` | Disabled by super-admin |

## OrgRole

| Wire value | Meaning |
|---|---|
| `admin` | Org admin (creator by default) |
| `doctor` | Regular member |

## PracticeType

| Wire value | Meaning |
|---|---|
| `independent` | Independent practice |
| `specialty_group` | Multi-doctor specialty group |
| `community_hospital` | Community hospital |

## ConversationType

| Wire value | Meaning |
|---|---|
| `direct` | 1:1 between two doctors |
| `group` | 3+ members, has name |

## ConversationAccess

Networking tier of a conversation (M0 substrate; wired to clients from M3/M4).

| Wire value | Meaning |
|---|---|
| `open` | Normal conversation — both sides message freely |
| `pending_request` | Message request awaiting recipient accept |
| `declined` | Recipient declined the request |

## ExternalDmPolicy (backend-only)

Org admin policy — never sent to the Flutter client, so it is deliberately NOT
in the parity-check SHARED set and has no Dart mirror.

| Wire value | Meaning |
|---|---|
| `disabled` | Members cannot DM outside the org |
| `connections_only` | External DMs only between connected users |
| `connections_and_requests` | Connections DM freely; others via message request |

## DirectoryVisibility (backend-only)

Org admin policy — never sent to the Flutter client, so it is deliberately NOT
in the parity-check SHARED set and has no Dart mirror.

| Wire value | Meaning |
|---|---|
| `org_only` | Members discoverable inside their org only |
| `network` | Members discoverable by the professional network |
| `public` | Members discoverable platform-wide |

## InvitationStatus

Connection-invitation lifecycle (networking graph, M1). Client-facing (invitation lists).

| Wire value | Meaning |
|---|---|
| `pending` | Awaiting recipient response |
| `accepted` | Recipient accepted → connection formed |
| `ignored` | Recipient ignored (silent to sender) |
| `withdrawn` | Sender withdrew before response |
| `expired` | Aged out (lazy computation; no cron) |

## InvitePolicy

Who may send me a connection invitation (`user_privacy_settings`, M1). Client edits it.

| Wire value | Meaning |
|---|---|
| `everyone` | Anyone may invite me |
| `second_degree` | Only people in my extended network |
| `shared_group_or_org` | Only shared-org / shared-group members |
| `nobody` | No one may invite me |

## DmPolicy

Who may open a direct conversation with me (`user_privacy_settings`, M1). Client edits it.

| Wire value | Meaning |
|---|---|
| `everyone` | Anyone may DM me directly |
| `connections_and_requests` | Connections DM freely; others via message request |
| `connections_only` | Only my connections may DM me |
| `nobody` | No one may DM me |

## Discoverability

Who may find me / view my profile (`user_privacy_settings`, M1). Client edits it.

| Wire value | Meaning |
|---|---|
| `everyone` | Discoverable by the whole network |
| `connections` | Only my connections |
| `nobody` | Not discoverable |

## LastSeenVisibility

Who may see when I was last online (`user_privacy_settings`, batch 2). Client
edits it. "Connections" means first-degree connections AND same-org
colleagues. Reciprocal: a user who picks `nobody` sees nobody else's either.

| Wire value | Meaning |
|---|---|
| `everyone` | Anyone who can reach my profile |
| `connections` | Connections and colleagues (default) |
| `nobody` | Hidden — and I see nobody's |

## OnlineVisibility

Whether my live "online" state is shown (`user_privacy_settings`, batch 2).

| Wire value | Meaning |
|---|---|
| `same_as_last_seen` | Follows LastSeenVisibility (default) |
| `nobody` | Never shown online; last seen still follows its own setting |

## ProfileFieldVisibility

Who may see my profile photo / about text (`user_privacy_settings`, batch 2 —
`profile_photo_visibility`, `about_visibility`). Hidden fields come back `null`
on `GET /users/{id}/profile`; the initials avatar always renders.

| Wire value | Meaning |
|---|---|
| `everyone` | Anyone who can reach my profile (default) |
| `connections` | Connections and colleagues only |

## ReportReason

Why a user or message is being reported (`POST /network/reports`, batch 4).
SHARED — the client renders the reason picker from it.

| Wire value | Meaning |
|---|---|
| `spam` | Unsolicited promotion / bulk messages |
| `harassment` | Abusive or threatening conduct |
| `phi_misuse` | Patient information shared or requested improperly |
| `impersonation` | Pretending to be another clinician / organisation |
| `other` | Anything else (details field) |

## ReportSubjectType (backend-only)

What a report points at. Backend-only — the client sends the string.

| Wire value | Meaning |
|---|---|
| `user` | A person (reported from their profile; default) |
| `message` | A message (batch 4) — reporter must be a conversation member; `context_message_ids` (≤5 ids, never bodies) travel with it |

## ReportStatus (backend-only)

Moderation report lifecycle — set by super-admins through
`GET/PATCH /admin/reports` (batch 4); never sent to the Flutter client, so
deliberately NOT in the parity-check SHARED set and no Dart mirror.

| Wire value | Meaning |
|---|---|
| `open` | Newly filed, unreviewed |
| `reviewing` | Under moderator review |
| `actioned` | Resolved with action taken |
| `dismissed` | Resolved, no action |

## GroupRole

Group capability ladder (§9.3, M5). SHARED — client renders role pills.

| Wire value | Meaning |
|---|---|
| `owner` | Sole owner; transfers ownership, manages admins, cannot leave without transfer |
| `admin` | Manages members/roles (except admins), removes/bans, edits group |
| `moderator` | Elevated member; moderates the group conversation |
| `member` | Regular member |

## GroupPostPolicy (backend-only)

Who may post in the group conversation (M5). Backend-only — NOT in the parity SHARED set.

| Wire value | Meaning |
|---|---|
| `all_members` | Any active member may post |
| `admins_only` | Only owner/admin may post |

## GroupMemberDmPolicy (backend-only)

Whether a member may DM a co-member from group context (M5). Backend-only.

| Wire value | Meaning |
|---|---|
| `open` | Co-members may open a direct chat with each other (`shared_group` in the permission module) |
| `request` | Co-members must connect first — the direct-chat gate answers `group_dm_request` (the request tier is retired) |
| `disabled` | No member-to-member DM — the gate answers `group_dm_disabled` |

Enforced on `POST /conversations` (direct) and on every send into a direct chat whenever the two doctors share no org and are not connected; the most permissive policy across their shared groups wins. Groups cap at `GROUP_MAX_MEMBERS` (256) active members — invite, accept and link-accept answer `409 group_full`.

## GroupMemberState (backend-only)

Group membership lifecycle (M5). Backend-only (client may render active/left).

| Wire value | Meaning |
|---|---|
| `active` | Current member |
| `banned` | Removed and barred from rejoining |
| `left` | Voluntarily left |
| `removed` | Removed by an admin |

## GroupInviteState (backend-only)

Invite lifecycle — direct + link (M5). Backend-only.

| Wire value | Meaning |
|---|---|
| `pending` | Live invite |
| `accepted` | Accepted → membership formed |
| `declined` | Invitee declined |
| `revoked` | Admin revoked |
| `expired` | Past its expiry |

## MessageType

| Wire value | Meaning |
|---|---|
| `text` | Plain text (encrypted at rest) |
| `voice_note` | Audio + auto-transcript |
| `image` | Image attachment |
| `file` | Generic file attachment |
| `system` | System event (joined/left/removed) |
| `video` | Video clip (batch 5): `s3_key` + JPEG poster in `thumb_key`, length in `voice_duration_sec`, optional `caption` |
| `poll` | Poll (batch 5): question in `content`, tallies + voter ids in `poll{question, multiple, options[{id, position, text, vote_count, voter_ids}], voter_count}` |

## TranscriptStatus

| Wire value | Meaning |
|---|---|
| `none` | Not a voice note |
| `pending` | Transcribe job running |
| `completed` | Transcript available |
| `failed` | Transcribe job errored |

## PresenceStatus

| Wire value | Meaning |
|---|---|
| `online` | Active in last 5 min |
| `away` | Inactive 5–30 min |
| `offline` | Inactive 30+ min — ALSO what a viewer gets for a doctor whose settings hide presence from them (`GET /users/presence`, batch 2), with `last_seen_at: null` |

## DisappearAfter

Stored as raw integer seconds in DB (`conversations.disappear_after_sec`), but Flutter selects via enum:

| Wire value (int seconds) | Enum member | Meaning |
|---|---|---|
| `null` | `off` | Disappearing disabled |
| `86400` | `day` | 24 hours |
| `604800` | `week` | 7 days |
| `2592000` | `month` | 30 days |
| `7776000` | `quarter` | 90 days |

## WsEventServer (server → client)

| Wire value | Payload fields |
|---|---|
| `new_message` | `message_id, conversation_id, sender_id, type, content, created_at` |
| `transcript_ready` | `message_id, transcript` |
| `message_delivered` | `conversation_id, user_id` (conversation-level ack) |
| `message_read` | `message_id, user_id, read_at` |
| `presence_update` | `user_id, status, last_seen_at` — recipient-scoped since batch 2: sent to the user's connections + org colleagues, minus anyone their settings hide it from and anyone hiding their own (reciprocal); `last_seen_at` is set on `away` |
| `member_added` | `conversation_id, user_id, user_name` |
| `member_removed` | `conversation_id, user_id` |
| `system_message` | `conversation_id, text` |
| `typing_start` | `conversation_id, user_id` |
| `typing_stop` | `conversation_id, user_id` |
| `heartbeat_ack` | `{}` — direct reply to a client heartbeat (liveness signal) |
| `invitation_received` | `invitation_id, sender_id, sender_name` (M1, no PHI) |
| `invitation_accepted` | `invitation_id, user_id, user_name` (M1, no PHI) |
| `connection_removed` | `user_id` — the party who removed you (M1) |
| `notification_created` | `notification_id, type, unread_count` (M1, PHI-free) |
| `conversation_request_received` | `conversation_id, sender_id` (M4, no PHI) — a message request became visible |
| `conversation_request_accepted` | `conversation_id, user_id` (M4) — recipient accepted; sent to the initiator |
| `conversation_request_declined` | `conversation_id` (M4) — silent, sent ONLY to the decliner's own devices |
| `group_invite_received` | `group_id, invite_id, inviter_id, inviter_name, group_name` (M5, no PHI) |
| `group_member_joined` | `group_id, user_id, user_name` (M5) — a member joined |
| `message_edited` | full `MessageOut` (incl. `reactions`, `changed_at`) — replace the row by id |
| `message_deleted` | full `MessageOut` tombstone — replace the row by id |
| `message_reacted` | `conversation_id, message_id, reactions[], changed_at, actor_id, emoji` (null = removed) — patch reactions only, drop if `changed_at` is not newer |

`new_message` / `message_edited` / `message_deleted` payloads are a full `MessageOut`, which since batch 4 also carries `reply_to_id`, `reply_to {id, sender_id, type, preview}` (rendered live from the quoted row; `preview` is "Message deleted" for a tombstone and the whole object is `null` once the quoted message expired), `forwarded`, `forward_depth`, `mentions[]` (user ids) and `starred` (always `false` in fan-outs — per-viewer, only true on the viewer's own reads).
| `connected` | `user_id` — first server frame after a successful `auth` |
| `invitation_withdrawn` | `invitation_id, sender_id` — the sender withdrew it |
| `org_updated` | `org_id, status` — org status or details changed; refetch |
| `group_updated` | `group_id` — group details changed; refetch |
| `profile_updated` | `user_id` — a profile you can see changed; refetch |
| `conversation_prefs_updated` | `conversation_id, prefs{pinned_at, archived, muted_until, custom_tone, custom_vibrate, theme, wallpaper, marked_unread, cleared_before_seq, hidden_until_seq}` (batch 3) — sent ONLY to the caller's own devices; patch the conversation's `prefs` in place |
| `message_pinned` | `conversation_id, message_id, pinned_until, actor_id` (batch 4) — every member; show the banner |
| `message_unpinned` | `conversation_id, message_id, pinned_until: null, actor_id` (null when the auto-unpin job cleared it) — every member |
| `message_starred` | `conversation_id, message_id, starred` (batch 4) — the actor's OWN devices only; stars are private |
| `poll_updated` | `conversation_id, message_id, poll{question, multiple, options[], voter_count}, changed_at, actor_id` (batch 5) — every member after a vote changed (or a departed member's votes were purged); replace the message's `poll`, drop if `changed_at` is not newer |

Since batch 5 a `MessageOut` also carries `caption` (image/video/file/voice, encrypted at rest), `thumb_key` (video poster; `GET /messages/{id}/file-url?thumb=1`), `waveform` (base64 of ≤ 64 amplitude bytes, voice notes), `media_width` / `media_height` and `poll`.

## WsEventClient (client → server)

| Wire value | Payload |
|---|---|
| `heartbeat` | `{}` — sent every 60s |
| `typing_start` | `conversation_id` |
| `typing_stop` | `conversation_id` |

## DevicePlatform

| Wire value | Meaning |
|---|---|
| `ios` | Apple device (APNs via FCM) |
| `android` | Android device (FCM) |

## JwtTokenType

| Wire value | Meaning |
|---|---|
| `access` | Short-lived (1h) |
| `refresh` | Long-lived (7d) |

## AuditAction

| Wire value | Meaning |
|---|---|
| `login` | User authenticated successfully |
| `logout` | Session invalidated |
| `register` | New user completed profile |
| `otp_requested` | OTP SMS requested |
| `otp_verified` | OTP successfully verified |
| `org_created` | Organization created |
| `org_joined` | User joined an organization |
| `org_verified` | Super-admin verified an org |
| `org_policy_changed` | Org admin changed networking policy (kill switch / DM policy / directory visibility) |
| `member_removed` | Admin removed a doctor |
| `conversation_created` | Direct/group created |
| `group_member_added` | Doctor added to group |
| `group_member_left` | Doctor left group |
| `group_member_removed` | Doctor removed by creator |
| `message_sent` | Message persisted |
| `message_read` | Message marked read |
| `file_uploaded` | File/voice attachment uploaded |
| `file_accessed` | Presigned URL issued |
| `invitation_sent` | Connection invitation created |
| `invitation_accepted` | Connection invitation accepted → connection formed |
| `invitation_ignored` | Recipient ignored an invitation |
| `invitation_withdrawn` | Sender withdrew an invitation |
| `connection_removed` | Either party removed a connection |
| `user_blocked` | User blocked another user |
| `user_unblocked` | User unblocked another user |
| `report_filed` | Abuse/spam report filed |
| `networking_policy_denied` | External networking path denied by kill switch / policy |
| `message_request_sent` | Message-request conversation created (M4) |
| `message_request_accepted` | Recipient accepted a message request → conversation opened (M4) |
| `message_request_declined` | Recipient declined a message request (M4, silent) |
| `group_created` | A group (+ its network conversation) was created (M5) |
| `group_joined` | A user joined a group directly (open policy) (M5) |
| `group_join_approved` | An admin approved a join request (M5) |
| `group_join_rejected` | An admin rejected a join request (M5, silent) |
| `group_role_changed` | A member's group role changed (M5) |
| `group_ownership_transferred` | Group ownership transferred to a new owner (M5) |
| `group_invite_sent` | A direct or link group invite was created (M5) |
| `group_invite_accepted` | A group invite was accepted → membership formed (M5) |
| `message_receipts_read` | Sender viewed a message's read-by / delivered-to list (`GET /messages/{id}/receipts`) |
| `privacy_updated` | A privacy setting changed (`PATCH /users/me/privacy`); meta lists the field names only |
| `conversation_prefs_updated` | A conversation preference changed (`PATCH /conversations/{id}/prefs`: pin / archive / mute / mark unread / clear / delete); meta lists the field names only (batch 3) |
| `message_forwarded` | A message was forwarded (`POST /messages/{id}/forward`); meta: `source_id`, `destinations[]`, `copies[]` (batch 4) |
| `message_pinned` | A message was pinned to its conversation; meta: `message_id`, `duration_sec` (batch 4) |
| `message_unpinned` | The pin was removed by a member (the auto-unpin job does not audit) (batch 4) |
| `starred_messages_read` | `GET /messages/starred` returned decrypted bodies; one row per page (batch 4) |
| `report_status_changed` | A super-admin moved a report between statuses; meta: `from`, `to` (batch 4) |
| `link_preview_fetched` | The server fetched a link preview on the user's behalf; meta: `host` only (batch 4) |
| `file_exported` | The user is about to save / share a media message (`POST /messages/{id}/export-audit`, allowed by `allow_media_export`); meta: `type`, `conversation_id` (batch 5) |
| `poll_voted` | The user changed their selection on a poll (`PUT` / `DELETE /messages/{id}/vote`); meta: `options` count, 0 = withdrawn (batch 5) |

## TranscribeSpecialty (AWS Transcribe Medical)

These map to AWS API values — do NOT lowercase for wire, AWS requires UPPERCASE.

| Wire value | Meaning |
|---|---|
| `PRIMARYCARE` | Default |
| `CARDIOLOGY` | Cardiology specialty |
| `RADIOLOGY` | Radiology specialty |
| `NEUROLOGY` | Neurology specialty |
| `UROLOGY` | Urology specialty |

## AvatarColor (Flutter-only — no wire)

Index-keyed color cycle from `design.md §2`. Not serialized over the wire; derived deterministically from user index.

| Index | Name | Hex |
|---|---|---|
| 0 | blue | `#1A56DB` |
| 1 | teal | `#0ABFAD` |
| 2 | purple | `#7C3AED` |
| 3 | darkBlue | `#0F3499` |
| 4 | amber | `#F59E0B` |

## PersonCard degree (M2 — deliberately NOT an enum)

`PersonCardOut.degree` and `PublicProfileOut.degree` are serialized as a plain
wire STRING — one of `1st` | `2nd` | `3rd` | `out` — not a shared enum. This is
a purely client-facing display badge derived from `RelationshipService`
(`degree_of`: first-degree → `1st`, second-degree → `2nd`, otherwise → `3rd`,
self/blocked → `out`). Keeping it a bare string avoids a three-file enum-parity
dance for a value that never participates in server-side branching. No entry in
the parity SHARED set; no Dart enum mirror required (client parses the string
directly). Likewise `connection_state` (`none` | `pending_outgoing` |
`pending_incoming` | `connected`) and `can_message` (`open` | `request` |
`denied`) are plain profile strings, not gated enums.
