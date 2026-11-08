# Compliance (batch 7) — API notes

Backend contract for org policies, retention / legal hold, the audit read
API, break-glass access, org moderation, scheduled-message list/cancel and
the `.well-known` link files. Routes live in `app/core/routes.py` (mirrored
in `lib/core/constants/api_routes.dart`); error codes are the `detail`
string. Key management and the audit chain design are in
[security.md](security.md). Migration `0035_compliance`.

| Constant | Value |
|---|---|
| `ACCESS_REQUEST_WINDOW_SEC` | 24 h |
| `ACCESS_REQUEST_REASON_MAX_LEN` | 500 |
| `RETENTION_DAYS_MIN/MAX` | 1 / 3650 |
| `AUDIT_PAGE_SIZE` | 100 |
| Rate limits | policies 20/min, access requests 10/min, audit reads 60/min, reads 120/min |

## A. Org policies

`organizations.policies` JSONB, defaults in `ORG_POLICY_DEFAULTS`:

| Key | Default | Enforced by |
|---|---|---|
| `allow_forward_outside_org` | true | server (forward) |
| `allow_copy` | true | client (hide Copy) |
| `allow_media_export` | false | server (export-audit) + client |
| `block_screenshots` | false | client (Android FLAG_SECURE) |
| `show_preview_in_banners_default` | false | server: a member's unset banner-preview toggle resolves to on only if **every** org they belong to sets this true |
| `default_disappear_sec` | null | server: every new org group chat starts with this timer (`DISAPPEAR_OPTIONS_SEC` or null) |
| `retention_days` | null | server: purge loop expires older messages (1–3650, null = keep) |
| `legal_hold` | false | server: pauses every shred for the org's conversations |

* `GET /orgs/{id}/policies` — any member → `OrgPoliciesOut` (all keys,
  defaults filled). Outsiders 403 `not_an_org_member`.
* `PATCH /orgs/{id}/policies` — org admin, partial body, unknown keys 422;
  `default_disappear_sec` must be one of 86400 / 604800 / 2592000 / 7776000
  or null; `retention_days` 1–3650 or null. Audited `org_policy_changed`
  with the **diff** only; unchanged values produce no row. Fans
  `org_updated` to members. `OrgOut.policies` and
  `PATCH /orgs/{id}/settings/networking` keep working and now include the
  new keys.

## B. Retention and legal hold

Purge loop (`_purge_expired_loop`, Redis-locked, every 60 s) runs
`RetentionService.apply` first: for each org with `retention_days` and no
hold, `UPDATE messages SET is_deleted = true, expires_at = now()` for rows
older than the window in that org's conversations (audit
`retention_applied {retention_days, messages}`, user NULL). They vanish from
reads immediately and are shredded 30 days later by `purge_content`.

`legal_hold = true` excludes the org's conversations from: `purge_content`,
delete-for-everyone's shred (`DELETE /messages/{id}` still answers a
tombstone; audit meta gains `legal_hold: true`; members' reads mask
content/media of a tombstone), account deletion (`is_deleted` only) and
retention. Content remains readable solely through break-glass.

## C. Audit read API

* `GET /admin/audit?user_id=&action=&from=&to=&cursor=&limit=` (super-admin)
  → `{data: [AuditRowOut], next_cursor}` newest first by `seq`; `cursor` =
  last `seq` seen. `AuditRowOut`: `id, seq, user_id, action, resource_type,
  resource_id, ip_address, user_agent, metadata, prev_hash, hash,
  created_at`. Never message bodies (the trail stores ids and small metadata
  only). Each call is audited `audit_read {scope: global, count, filters}`.
* `GET /orgs/{id}/audit` (org admin, same query params) — rows whose actor
  is an org member **and** whose resource is org-scoped: the org
  (`organization`), its memberships (`org_member`), its conversations and
  their messages, its access requests. `ip_address` / `user_agent` are null.
  Audited `audit_read {scope: org}`.
* `scripts/verify_audit_chain.py` — exit 0 when the chain verifies.

## D. Break-glass

| Route | Who | Result |
|---|---|---|
| `POST /orgs/{id}/access-requests {conversation_id, reason}` | org admin | `201 AccessRequestOut` (`pending`). Conversation must be the org's or contain an org member, else 404 `conversation_not_found`; blank reason 422 `reason_required`; a pending duplicate 409 `access_request_pending_exists`. Other org admins get feed `access_request_pending`, WS `access_request_updated`, push "An access request needs your review". Audit `access_request_created`. |
| `GET /orgs/{id}/access-requests?cursor=&limit=` | org admin | `{data, next_cursor}` newest first; `status` reflects expiry immediately. |
| `POST …/{rid}/approve` / `…/reject` | a **different** org admin | `200 AccessRequestOut`; requester 403 `self_approval_forbidden`; not pending 409 `access_request_not_pending`. Approve sets `expires_at = now + 24 h`. Requester gets feed `access_request_decided {approved}`, WS, push. Audit `access_request_approved` / `_rejected`. |
| `GET …/{rid}/messages?cursor=&limit=` | the requester only (403 `not_requester`) | `{data: [MessageOut], next_cursor}` newest first by `seq`, decrypted, **including tombstones kept under legal hold**; purged rows excluded. 403 `access_request_not_approved` / `access_request_expired`. Each page audits `break_glass_read {access_request_id, org_id, before_seq, count}`. The first page ever posts the system message `An administrator accessed this conversation under policy` (fanned out as `new_message`, no push). |

The settings loop stamps lapsed approvals `expired` and tells the requester
(`access_request_updated {status: expired}`). `AccessRequestStatus` is
backend-only (`pending | approved | rejected | expired`).

## E. Org moderation

* `GET /orgs/{id}/reports?status=open|reviewing|actioned|dismissed|all&cursor=&limit=`
  (org admin) → `[ReportOut]` for reports whose reporter is an org member,
  or whose subject is a member (`user`) or a member's message (`message`).
  Ids, reason, details, context ids — never bodies.
* `PATCH /orgs/{id}/reports/{rid} {status}` → `ReportOut`; a report outside
  the scope is 404 `report_not_found`. Audited `report_status_changed
  {from, to, org_id}`. The super-admin queue (`/admin/reports`) is unchanged.

## H. Scheduled messages, universal links

* `GET /conversations/{id}/scheduled` (member) → my own not-yet-sent rows
  `[{id, conversation_id, scheduled_at, timezone, status, error, created_at}]`
  soonest first — no content (the app keeps its draft).
* `DELETE /scheduled/{id}` → `{ok}`; someone else's, unknown or already sent
  → 404 `scheduled_message_not_found`. The row is deleted.
* `GET /.well-known/apple-app-site-association` → `applinks` for
  `3N7394B3B9.com.doqto.ios`, components `/g/*`, `/c/*`, `/u/*` (+
  `webcredentials`). `GET /.well-known/assetlinks.json` → one
  `android_app` target for `com.doqto.app` with the fingerprints from
  `ANDROID_CERT_SHA256_FINGERPRINTS` (empty placeholder until ops adds the
  Play App Signing SHA-256). Both unauthenticated, cached 1 h.

## G. Envelope encryption — operator view

See security.md. In short: `AWS_KMS_KEY_ID` unset → static wrapper (today);
set → KMS wrapper for new keys. `scripts/rotate_keys.py status|rotate|rewrap|to-legacy`.
Rows carry `key_version` (0 = legacy static key). `WsEventServer` gains
`access_request_updated`; `AuditAction` gains `access_request_created /
approved / rejected`, `break_glass_read`, `audit_read`, `retention_applied`,
`key_rotated` (docs/enums.md).
