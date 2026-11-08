from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.constants import (
    MESSAGE_DELETED_PREVIEW,
    CHAT_LIST_PREVIEW_MAX_LEN,
    DISAPPEAR_OPTIONS_SEC,
    MEDIA_PAGE_SIZE,
    MESSAGES_PAGE_SIZE,
    RATE_LIMIT_PREFS_WRITES_PER_MINUTE,
    RATE_LIMIT_PINS_PER_MINUTE,
    RATE_LIMIT_READS_PER_MINUTE,
)
from app.core import permissions
from app.core.config import settings
from app.core import crypto
from app.core.dependencies import get_current_user
from app.core.enums import (
    AuditAction,
    ConversationAccess,
    ConversationType,
    MessageType,
    OrgRole,
    OrgStatus,
    ScheduledMessageStatus,
    WsEventServer,
)
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.models import (
    Conversation,
    ConversationMember,
    Group,
    Message,
    Organization,
    OrgMember,
    ScheduledMessage,
    User,
    UserPrivacySettings,
)
from app.schemas.common import OkResponse
from app.schemas.compliance import ScheduledMessageListOut
from app.services.relationship_service import RelationshipService
from app.schemas.conversation import (
    ConversationAddMembersIn,
    ConversationCreateIn,
    ConversationOut,
    ConversationPrefsIn,
    ConversationPrefsOut,
    ConversationSettingsIn,
    UnreadTotalOut,
)
from app.services.compliance_service import PolicyService
from app.services.media_service import MediaService
from app.schemas.message import (
    ConversationPinIn,
    MediaItemOut,
    MediaPage,
    MessageOut,
    MessagePinnedEvent,
    MessageScheduleIn,
    MessageSendIn,
    ScheduledMessageOut,
)
from app.services.audit_service import AuditService, request_meta
from app.services.conversation_prefs_service import ConversationPrefsService, PrefsError
from app.services.group_service import GroupService
from app.services.message_service import MessageError, MessageService
from app.services.push_service import PushService

router = APIRouter()


async def _assert_member(
    conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
) -> Conversation:
    conv = await db.scalar(
        select(Conversation).where(Conversation.id == conversation_id)
    )
    if conv is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="conversation_not_found")
    member = await db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user_id,
        )
    )
    if member is None:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, detail="not_a_conversation_member"
        )
    return conv


async def _assert_users_in_org(
    org_id: uuid.UUID, user_ids: list[uuid.UUID], db: AsyncSession
) -> None:
    """Every target user must belong to the conversation's org (blocks the
    cross-org member bug)."""
    if not user_ids:
        return
    rows = await db.execute(
        select(OrgMember.user_id).where(
            OrgMember.org_id == org_id, OrgMember.user_id.in_(user_ids)
        )
    )
    if set(user_ids) - set(rows.scalars().all()):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="member_not_in_org")


async def _is_org_admin(
    org_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
) -> bool:
    member = await db.scalar(
        select(OrgMember).where(
            OrgMember.org_id == org_id, OrgMember.user_id == user_id
        )
    )
    return member is not None and member.org_role == OrgRole.ADMIN


def _preview_for(msg: Message | None) -> str | None:
    if msg is not None and msg.deleted_at is not None:
        return MESSAGE_DELETED_PREVIEW
    if msg is None:
        return None
    # Text / system body, a poll's question, or a media caption (batch 5);
    # the client labels caption-less media from last_message_type.
    if msg.type in (MessageType.TEXT, MessageType.SYSTEM, MessageType.POLL):
        blob = msg.content_encrypted
    else:
        blob = msg.caption_encrypted
    if blob is None:
        return None
    try:
        text = crypto.decrypt(blob, msg.key_version)
    except Exception:
        return None
    text = text.strip()
    if len(text) > CHAT_LIST_PREVIEW_MAX_LEN:
        text = text[: CHAT_LIST_PREVIEW_MAX_LEN - 1].rstrip() + "…"
    return text


async def _group_ids(
    convs: list[Conversation], db: AsyncSession
) -> dict[uuid.UUID, uuid.UUID]:
    """conversation id → groups.id for the network group chats among [convs]
    (one query; legacy org group chats have no row and stay absent)."""
    ids = [c.id for c in convs if c.type == ConversationType.GROUP]
    if not ids:
        return {}
    rows = await db.execute(
        select(Group.conversation_id, Group.id).where(Group.conversation_id.in_(ids))
    )
    return dict(rows.all())


def _to_out(
    conv: Conversation,
    member_ids: list[uuid.UUID],
    last_msg: Message | None = None,
    group_id: uuid.UUID | None = None,
) -> ConversationOut:
    out = ConversationOut.model_validate(conv)
    out.member_ids = member_ids
    out.group_id = group_id
    out.pinned_message_id, out.pinned_until = MessageService.effective_pin(conv)
    if last_msg is not None:
        out.last_message_at = last_msg.created_at
        out.last_message_sender_id = last_msg.sender_id
        out.last_message_type = last_msg.type
        out.last_message_preview = _preview_for(last_msg)
    return out


@router.get(ApiRoutes.CONVERSATIONS_LIST, response_model=list[ConversationOut])
async def list_conversations(
    filter: str | None = Query(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[ConversationOut]:
    if filter == "requests":
        # Legacy clients (≤ build 17) still poll the Requests tab; the tier is
        # gone, so that tab is always empty rather than mirroring the inbox.
        return []
    convs = await MessageService.list_for_user(user_id=user.id, db=db)
    # The caller's own pin / archive / mute / … rows (batch 3). A chat deleted
    # for me stays off the list until something new lands in it.
    prefs = await ConversationPrefsService.for_user(user_id=user.id, db=db)
    convs = [
        c for c in convs if not ConversationPrefsService.is_hidden(prefs.get(c.id), c)
    ]
    conv_ids = [c.id for c in convs]
    # Batched: 5 queries total regardless of conversation count (was ~2×N).
    latest = await MessageService.latest_per_conversation(
        conversation_ids=conv_ids, db=db, user_id=user.id
    )
    conv_members = await MessageService.members_by_conversation(
        conversation_ids=conv_ids, db=db
    )
    unread = await MessageService.unread_counts(
        conversations=convs, user_id=user.id, db=db
    )
    other_ids: set[uuid.UUID] = set()
    for c in convs:
        if c.type == ConversationType.DIRECT:
            other_ids.update(uid for uid in conv_members[c.id] if uid != user.id)
    names: dict[uuid.UUID, str] = {}
    if other_ids:
        rows = await db.execute(
            select(User.id, User.full_name).where(User.id.in_(other_ids))
        )
        names = dict(rows.all())
    group_ids = await _group_ids(convs, db)
    export_ok = await MediaService.export_allowed_map(user_id=user.id, convs=convs, db=db)
    out: list[ConversationOut] = []
    for c in convs:
        o = _to_out(c, conv_members[c.id], latest.get(c.id), group_ids.get(c.id))
        o.media_export_allowed = export_ok.get(c.id, False)
        if c.type == ConversationType.DIRECT:
            o.display_name = next(
                (
                    names[uid]
                    for uid in conv_members[c.id]
                    if uid != user.id and uid in names
                ),
                None,
            )
        o.unread_count = unread.get(c.id, 0)
        o.prefs = ConversationPrefsService.to_out(prefs.get(c.id))
        out.append(o)
    return out


@router.get(ApiRoutes.CONVERSATIONS_UNREAD_TOTAL, response_model=UnreadTotalOut)
async def unread_total(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> UnreadTotalOut:
    """Cheap refresh for the app-icon badge: unread across the list minus
    muted / archived / deleted-for-me chats (batch 3)."""
    await enforce_rate_limit(user.id, "unread_total", RATE_LIMIT_READS_PER_MINUTE)
    return UnreadTotalOut(
        total=await MessageService.unread_total(user_id=user.id, db=db)
    )


@router.patch(ApiRoutes.CONVERSATIONS_PREFS, response_model=ConversationPrefsOut)
async def update_prefs(
    conversation_id: uuid.UUID,
    body: ConversationPrefsIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ConversationPrefsOut:
    """Partial update of the caller's private view of a conversation: pin
    (max 3), archive, mute until, mark unread, cosmetic choices, clear chat
    and delete chat (direct only). Other members never see any of it; the
    caller's other devices get `conversation_prefs_updated`."""
    await enforce_rate_limit(
        user.id, "conversation_prefs", RATE_LIMIT_PREFS_WRITES_PER_MINUTE
    )
    conv = await db.scalar(
        select(Conversation).where(Conversation.id == conversation_id)
    )
    member = (
        None
        if conv is None
        else await db.scalar(
            select(ConversationMember).where(
                ConversationMember.conversation_id == conversation_id,
                ConversationMember.user_id == user.id,
            )
        )
    )
    # Outsiders get the same 404 as a chat that does not exist (no oracle).
    if conv is None or member is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="conversation_not_found")
    try:
        pref, changed = await ConversationPrefsService.update(
            conv=conv, user_id=user.id, body=body, db=db
        )
    except PrefsError as e:
        code = str(e)
        http = {
            "pin_limit": status.HTTP_409_CONFLICT,
            "delete_group_use_leave": status.HTTP_400_BAD_REQUEST,
        }.get(code, status.HTTP_400_BAD_REQUEST)
        raise HTTPException(http, detail=code) from e
    out = ConversationPrefsService.to_out(pref)
    if changed:
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.CONVERSATION_PREFS_UPDATED,
            resource_type="conversation",
            resource_id=conversation_id,
            db=db,
            # Field names only — never values (a mute is nobody's business).
            metadata={"fields": sorted(body.model_fields_set)},
        )
        await db.commit()
        await ws_manager.publish_to_users(
            [user.id],
            WsEventServer.CONVERSATION_PREFS_UPDATED,
            {
                "conversation_id": str(conversation_id),
                "prefs": out.model_dump(mode="json"),
            },
        )
    return out


@router.post(ApiRoutes.CONVERSATIONS_CREATE, response_model=ConversationOut)
async def create_conversation(
    body: ConversationCreateIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ConversationOut:
    # Direct messages never need an org: who can reach whom is decided by the
    # permission module below (colleague or connection). Only groups use one.
    if body.type == ConversationType.DIRECT and len(body.member_ids) == 1:
        # M3: the central permission module (A4) decides reachability — this
        # REPLACES the old org-membership gate for direct conversations. Same-org
        # colleagues short-circuit to mode='open' inside permissions (regression
        # rule); connected cross-org pairs also resolve to 'open'.
        target_id = body.member_ids[0]
        ctx = await RelationshipService.load_context(user.id, target_id, db)
        decision = permissions.can_start_direct(ctx)
        if decision.mode == "denied":
            # Blocks are never observable (HIPAA silence rule) — surface generic.
            reason = (
                "user_unavailable" if decision.reason == "blocked" else decision.reason
            )
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail=reason)
        # Connected cross-org pairs are staged behind the network flag.
        if not ctx.shared_org_ids and not settings.NETWORK_DM_ENABLED:
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail="network_dm_disabled")
        create_access = ConversationAccess.OPEN
        create_initiator = None
        # Direct conversations are always network-scoped (org_id=NULL, forced by
        # the service); org_id passed here is ignored for direct.
        conv_org = None
    else:
        # Groups belong to an org and wait for it to be verified. A doctor in
        # an active org and a pending one gets the active one.
        orgs = (
            await db.execute(
                select(OrgMember.org_id, Organization.status)
                .join(Organization, Organization.id == OrgMember.org_id)
                .where(OrgMember.user_id == user.id)
            )
        ).all()
        if not orgs:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST, detail="user_not_in_any_org"
            )
        caller_org = next((o for o, st in orgs if st == OrgStatus.ACTIVE), None)
        if caller_org is None:
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail="org_not_verified")
        await _assert_users_in_org(caller_org, body.member_ids, db)
        conv_org = caller_org
        create_access = ConversationAccess.OPEN
        create_initiator = None

    # A new direct chat starts with the creator's default disappearing timer
    # (privacy screen, batch 2). Never applied to an existing conversation.
    default_disappear = None
    if body.type == ConversationType.DIRECT:
        prefs = await db.scalar(
            select(UserPrivacySettings.default_disappear_sec).where(
                UserPrivacySettings.user_id == user.id
            )
        )
        default_disappear = prefs if prefs in DISAPPEAR_OPTIONS_SEC else None
    else:
        # An org group chat starts with the org's default timer (batch 7
        # policy `default_disappear_sec`); the creator may change it later.
        default_disappear = await PolicyService.default_disappear_for_org(conv_org, db)
    try:
        conv = await MessageService.create_conversation(
            org_id=conv_org,
            creator_id=user.id,
            conv_type=body.type,
            name=body.name,
            member_ids=body.member_ids,
            db=db,
            access=create_access,
            initiator_id=create_initiator,
            disappear_after_sec=default_disappear,
        )
    except MessageError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e

    members = await MessageService.conversation_members(conversation_id=conv.id, db=db)
    out = _to_out(
        conv,
        [m.user_id for m in members],
        None,
        (await _group_ids([conv], db)).get(conv.id),
    )
    out.media_export_allowed = await MediaService.export_allowed(user_id=user.id, conv=conv, db=db)
    if conv.type == ConversationType.DIRECT:
        other_id = next((m.user_id for m in members if m.user_id != user.id), None)
        if other_id is not None:
            out.display_name = await db.scalar(
                select(User.full_name).where(User.id == other_id)
            )
    return out


@router.get(ApiRoutes.CONVERSATIONS_MESSAGES, response_model=list[MessageOut])
async def list_messages(
    conversation_id: uuid.UUID,
    request: Request,
    before: datetime | None = Query(default=None),
    before_date: date | None = Query(default=None),
    after_seq: int | None = Query(default=None, ge=0),
    changed_since: datetime | None = Query(default=None),
    limit: int = Query(default=MESSAGES_PAGE_SIZE, ge=1, le=MESSAGES_PAGE_SIZE),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[MessageOut]:
    # "Jump to date" (batch 4): the page ending at the end of that UTC day.
    if before_date is not None:
        if before is not None:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST, detail="before_and_before_date_exclusive"
            )
        before = datetime.combine(
            before_date, datetime.min.time(), tzinfo=timezone.utc
        ) + timedelta(days=1)
    if before is not None and after_seq is not None:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, detail="before_and_after_seq_exclusive"
        )
    if changed_since is not None and (before is not None or after_seq is not None):
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, detail="changed_since_exclusive"
        )
    await enforce_rate_limit(user.id, "list_messages", RATE_LIMIT_READS_PER_MINUTE)
    conv = await _assert_member(conversation_id, user.id, db)
    # HIPAA §164.312(b): reading decrypted PHI must leave an audit row —
    # one per request (page), not per message.
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=AuditAction.CONVERSATION_ACCESSED,
        resource_type="conversation",
        resource_id=conversation_id,
        db=db,
        metadata={
            "before": before.isoformat() if before else None,
            "after_seq": after_seq,
            "changed_since": changed_since.isoformat() if changed_since else None,
            "limit": limit,
        },
    )
    msgs = await MessageService.list_messages(
        conversation_id=conversation_id,
        before=before,
        limit=limit,
        db=db,
        after_seq=after_seq,
        user_id=user.id,
        changed_since=changed_since,
    )
    # A3 hybrid: GROUP ticks come from member seq cursors, DIRECT from receipts.
    if conv.type == ConversationType.GROUP:
        read_ids, delivered_ids = await MessageService.group_receipt_ids(
            msgs=msgs, conv=conv, db=db
        )
    else:
        # Read receipts off for either party → blue ticks never appear for
        # the other party (delivered ticks still do).
        if await MessageService.read_receipts_enabled(conv=conv, db=db):
            read_ids = await MessageService.read_message_ids(
                message_ids=[m.id for m in msgs], db=db
            )
        else:
            read_ids = set()
        delivered_ids = await MessageService.delivered_message_ids(
            message_ids=[m.id for m in msgs], db=db
        )
    return await MessageService.outs_for(
        msgs, db=db, viewer_id=user.id, read_ids=read_ids, delivered_ids=delivered_ids
    )


@router.get(ApiRoutes.CONVERSATIONS_MEDIA, response_model=MediaPage)
async def list_media(
    conversation_id: uuid.UUID,
    request: Request,
    type: str = Query(default="image", pattern="^(image|video|file|link)$"),
    cursor: str | None = Query(default=None),
    limit: int = Query(default=MEDIA_PAGE_SIZE, ge=1, le=MEDIA_PAGE_SIZE),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MediaPage:
    """Media / Docs / Links tabs (batch 5): this chat's photos, videos, files
    or text messages with URLs, newest first, honouring the caller's hides and
    clear-chat cursor. Cursor = seq of the last row. For `link` the page may be
    short with a cursor when the decrypt-and-scan cap is hit."""
    await enforce_rate_limit(user.id, "list_media", RATE_LIMIT_READS_PER_MINUTE)
    await _assert_member(conversation_id, user.id, db)
    before_seq: int | None = None
    if cursor:
        try:
            before_seq = int(cursor)
        except ValueError as e:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="invalid_cursor") from e
    try:
        rows, next_cursor = await MediaService.list_media(
            conversation_id=conversation_id,
            user_id=user.id,
            media_type=type,
            before_seq=before_seq,
            limit=limit,
            db=db,
        )
    except MessageError as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(e)) from e
    # Decrypted captions / link text leave the server: audit like a thread read.
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=AuditAction.CONVERSATION_ACCESSED,
        resource_type="conversation",
        resource_id=conversation_id,
        db=db,
        metadata={"media": type, "cursor": cursor, "count": len(rows)},
    )
    await db.commit()
    outs = await MessageService.outs_for([m for m, _ in rows], db=db, viewer_id=user.id)
    return MediaPage(
        data=[MediaItemOut(message=o, urls=urls) for o, (_, urls) in zip(outs, rows)],
        next_cursor=next_cursor,
    )


@router.post(ApiRoutes.CONVERSATIONS_MESSAGES, response_model=MessageOut)
async def send_message(
    conversation_id: uuid.UUID,
    body: MessageSendIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    await enforce_rate_limit(user.id, "send_message")
    conv = await _assert_member(conversation_id, user.id, db)
    # Group post-policy gate (M5): when this conversation has a linked group with
    # post_policy=admins_only, only owner/admin members may post. Legacy org
    # group chats (no groups row) are unaffected.
    if conv.type == ConversationType.GROUP:
        if not await GroupService.check_post_allowed(
            conversation_id=conversation_id, user_id=user.id, db=db
        ):
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail="post_restricted")
    # Direct conversations are permission-gated on every send so a block or a
    # removed connection freezes the thread both ways.
    if conv.type == ConversationType.DIRECT:
        other_id = await db.scalar(
            select(ConversationMember.user_id).where(
                ConversationMember.conversation_id == conversation_id,
                ConversationMember.user_id != user.id,
            )
        )
        if other_id is not None:
            ctx = await RelationshipService.load_context(user.id, other_id, db)
            decision = permissions.can_message(ctx)
            if decision.mode == "denied":
                detail = (
                    decision.reason
                    if decision.reason
                    in ("not_connected", "group_dm_request", "group_dm_disabled")
                    else "not_reachable"
                )
                raise HTTPException(status.HTTP_403_FORBIDDEN, detail=detail)
    ip, user_agent = request_meta(request)
    try:
        if body.type == MessageType.POLL:
            msg = await MediaService.create_poll(
                conv=conv,
                sender_id=user.id,
                poll=body.poll,
                db=db,
                client_id=body.client_id,
                reply_to_id=body.reply_to_id,
                ip_address=ip,
                user_agent=user_agent,
            )
        else:
            msg = await MessageService.send_text(
                conversation_id=conversation_id,
                sender_id=user.id,
                content=body.content,
                db=db,
                client_id=body.client_id,
                ip_address=ip,
                user_agent=user_agent,
                reply_to_id=body.reply_to_id,
            )
    except MessageError as e:
        raise HTTPException(
            _SEND_STATUS.get(str(e), status.HTTP_400_BAD_REQUEST), detail=str(e)
        ) from e

    # The quote travels with the message so receivers render it without a
    # second fetch; `starred` is per-viewer and stays false in the fan-out.
    out = (await MessageService.outs_for([msg], db=db))[0]
    recipients = await MessageService.member_ids(conversation_id=conversation_id, db=db)
    mentioned = [uid for uid in (msg.mentions or []) if uid != user.id]

    await db.commit()  # flush before broadcasting so receivers can query
    await ws_manager.publish_to_users(
        recipients,
        WsEventServer.NEW_MESSAGE,
        out.model_dump(mode="json"),
    )
    PushService.notify_new_message(
        conversation_id=conversation_id,
        recipient_ids=recipients,
        sender_id=user.id,
        skip_ids=set(mentioned),
    )
    if mentioned:
        # "Dr X mentioned you in <group>" — replaces the generic banner for
        # the people named; the client's per-chat mute does not apply to it.
        PushService.notify_mentions(
            conversation_id=conversation_id, mentioned_ids=mentioned, sender_id=user.id
        )
    return out


# MessageError → HTTP status on the send path (anything else is 400).
_SEND_STATUS = {
    "reply_target_invalid": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "mention_not_member": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "too_many_mentions": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "conversation_not_found": status.HTTP_404_NOT_FOUND,
}


@router.post(
    ApiRoutes.CONVERSATIONS_MESSAGES_SCHEDULE, response_model=ScheduledMessageOut
)
async def schedule_message(
    conversation_id: uuid.UUID,
    body: MessageScheduleIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ScheduledMessageOut:
    await enforce_rate_limit(user.id, "send_message")
    conv = await _assert_member(conversation_id, user.id, db)
    # Scheduling into a pending/declined request thread would sidestep the
    # request-tier send guard — only open conversations accept schedules.
    if conv.access != ConversationAccess.OPEN:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="conversation_not_open")
    if conv.type == ConversationType.GROUP:
        if not await GroupService.check_post_allowed(
            conversation_id=conversation_id, user_id=user.id, db=db
        ):
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail="post_restricted")
    try:
        local = datetime.fromisoformat(body.scheduled_local)
        tz = ZoneInfo(body.timezone)
    except (ValueError, KeyError) as e:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, detail="invalid_schedule_time"
        ) from e
    if local.tzinfo is None:
        local = local.replace(tzinfo=tz)
    scheduled_at = local.astimezone(timezone.utc)
    now = datetime.now(tz=timezone.utc)
    if scheduled_at <= now + timedelta(seconds=30) or scheduled_at > now + timedelta(
        days=365
    ):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="invalid_schedule_time")

    version = await crypto.active_version(db, conv.org_id)
    row = ScheduledMessage(
        conversation_id=conversation_id,
        sender_id=user.id,
        content_encrypted=crypto.encrypt(body.content, version),
        key_version=version,
        timezone=body.timezone,
        scheduled_at=scheduled_at,
    )
    db.add(row)
    await db.flush()
    await AuditService.log(
        db,
        user_id=user.id,
        action=AuditAction.MESSAGE_SENT,
        resource_type="scheduled_message",
        resource_id=row.id,
    )
    out = ScheduledMessageOut(
        id=row.id,
        conversation_id=conversation_id,
        scheduled_at=scheduled_at,
        timezone=body.timezone,
        status=str(row.status),
    )
    await db.commit()
    return out


@router.get(ApiRoutes.CONVERSATIONS_SCHEDULED, response_model=list[ScheduledMessageListOut])
async def list_scheduled(
    conversation_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[ScheduledMessageListOut]:
    """My own not-yet-sent scheduled messages in this chat (pending and
    failed), soonest first. Never anyone else's; no content — the client
    keeps the draft text it scheduled."""
    await enforce_rate_limit(user.id, "list_scheduled", RATE_LIMIT_READS_PER_MINUTE)
    await _assert_member(conversation_id, user.id, db)
    rows = await db.scalars(
        select(ScheduledMessage)
        .where(
            ScheduledMessage.conversation_id == conversation_id,
            ScheduledMessage.sender_id == user.id,
            ScheduledMessage.status != ScheduledMessageStatus.SENT,
        )
        .order_by(ScheduledMessage.scheduled_at.asc())
    )
    return [
        ScheduledMessageListOut(
            id=r.id,
            conversation_id=r.conversation_id,
            scheduled_at=r.scheduled_at,
            timezone=r.timezone,
            status=str(r.status),
            error=r.error,
            created_at=r.created_at,
        )
        for r in rows.all()
    ]


@router.post(ApiRoutes.CONVERSATIONS_READ, response_model=OkResponse)
async def mark_conversation_read(
    conversation_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    conv = await _assert_member(conversation_id, user.id, db)
    await MessageService.mark_conversation_read(
        conversation_id=conversation_id, user_id=user.id, db=db
    )
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=AuditAction.MESSAGE_READ,
        resource_type="conversation",
        resource_id=conversation_id,
        db=db,
    )
    recipients = await MessageService.member_ids(conversation_id=conversation_id, db=db)
    emit = await MessageService.read_receipts_enabled(conv=conv, db=db)
    # Reading a chat drops the hand-set unread dot (batch 3) on every device.
    dot_cleared = await ConversationPrefsService.clear_marked_unread(
        conversation_id=conversation_id, user_id=user.id, db=db
    )
    await db.commit()
    if dot_cleared:
        pref = await ConversationPrefsService.get(
            conversation_id=conversation_id, user_id=user.id, db=db
        )
        await ws_manager.publish_to_users(
            [user.id],
            WsEventServer.CONVERSATION_PREFS_UPDATED,
            {
                "conversation_id": str(conversation_id),
                "prefs": ConversationPrefsService.to_out(pref).model_dump(mode="json"),
            },
        )
    # One conversation-level event: senders flip all their ticks to read.
    # Stored regardless; not emitted when either party turned receipts off.
    if emit:
        await ws_manager.publish_to_users(
            recipients,
            WsEventServer.MESSAGE_READ,
            {"conversation_id": str(conversation_id), "user_id": str(user.id)},
        )
    return OkResponse()


@router.post(ApiRoutes.CONVERSATIONS_DELIVERED, response_model=OkResponse)
async def mark_conversation_delivered(
    conversation_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    """Recipient acks receipt of a conversation's messages → gray double-check
    on the sender's side. Called by clients whenever messages arrive."""
    await _assert_member(conversation_id, user.id, db)
    changed = await MessageService.mark_conversation_delivered(
        conversation_id=conversation_id, user_id=user.id, db=db
    )
    if changed:
        recipients = await MessageService.member_ids(
            conversation_id=conversation_id, db=db
        )
        await db.commit()
        await ws_manager.publish_to_users(
            recipients,
            WsEventServer.MESSAGE_DELIVERED,
            {"conversation_id": str(conversation_id), "user_id": str(user.id)},
        )
    return OkResponse()


@router.patch(ApiRoutes.CONVERSATIONS_MEMBERS, response_model=OkResponse)
async def add_members(
    conversation_id: uuid.UUID,
    body: ConversationAddMembersIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    conv = await _assert_member(conversation_id, user.id, db)
    await _assert_users_in_org(conv.org_id, body.user_ids, db)
    added: list[uuid.UUID] = []
    for uid in body.user_ids:
        exists = await db.scalar(
            select(ConversationMember).where(
                ConversationMember.conversation_id == conversation_id,
                ConversationMember.user_id == uid,
            )
        )
        if exists is None:
            db.add(ConversationMember(conversation_id=conversation_id, user_id=uid))
            added.append(uid)
    if added:
        await db.flush()  # member_ids below must see the new rows
        for uid in added:
            await AuditService.log_request(
                request,
                user_id=user.id,
                action=AuditAction.GROUP_MEMBER_ADDED,
                resource_type="conversation",
                resource_id=conversation_id,
                db=db,
                metadata={"member_id": str(uid)},
            )
        recipients = await MessageService.member_ids(
            conversation_id=conversation_id, db=db
        )
        for uid in added:
            await ws_manager.publish_to_users(
                recipients,
                WsEventServer.MEMBER_ADDED,
                {"conversation_id": str(conversation_id), "user_id": str(uid)},
            )
    return OkResponse()


@router.delete(ApiRoutes.CONVERSATIONS_MEMBER_DETAIL, response_model=OkResponse)
async def remove_or_leave(
    conversation_id: uuid.UUID,
    user_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    conv = await _assert_member(conversation_id, user.id, db)
    # Self-leave is always allowed; removing someone ELSE is an org-admin action.
    if user_id != user.id and not await _is_org_admin(conv.org_id, user.id, db):
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="not_authorized")
    target = await db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user_id,
        )
    )
    if target is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="member_not_found")
    await db.delete(target)
    await db.flush()
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=(
            AuditAction.GROUP_MEMBER_LEFT
            if user_id == user.id
            else AuditAction.GROUP_MEMBER_REMOVED
        ),
        resource_type="conversation",
        resource_id=conversation_id,
        db=db,
        metadata={"member_id": str(user_id)},
    )
    # Remaining members + the removed user (they need to see themselves leave).
    recipients = await MessageService.member_ids(conversation_id=conversation_id, db=db)
    await ws_manager.publish_to_users(
        [*recipients, user_id],
        WsEventServer.MEMBER_REMOVED,
        {"conversation_id": str(conversation_id), "user_id": str(user_id)},
    )
    return OkResponse()


@router.patch(ApiRoutes.CONVERSATIONS_SETTINGS, response_model=OkResponse)
async def update_settings(
    conversation_id: uuid.UUID,
    body: ConversationSettingsIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    conv = await _assert_member(conversation_id, user.id, db)
    # A network group's timer is a group setting: owner/admin only. Legacy org
    # group chats (no groups row) and direct chats keep any-member semantics.
    if conv.type == ConversationType.GROUP:
        if not await GroupService.can_manage_conversation(
            conversation_id=conversation_id, user_id=user.id, db=db
        ):
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail="not_authorized")
    val = body.disappear_after_sec
    if val is not None and val not in DISAPPEAR_OPTIONS_SEC:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, detail="invalid_disappear_after_sec"
        )
    if conv.disappear_after_sec == val:
        return OkResponse()  # idempotent — no duplicate banner
    conv.disappear_after_sec = val

    if val is None:
        text = f"{user.full_name} turned off disappearing messages."
    else:
        text = (
            f"{user.full_name} turned on disappearing messages. New messages will "
            f"disappear from this chat {DISAPPEAR_OPTIONS_SEC[val]} after they're sent."
        )
    msg = await MessageService.send_system(
        conv=conv, sender_id=user.id, content=text, db=db
    )
    out = MessageService.to_out(msg)
    recipients = await MessageService.member_ids(conversation_id=conversation_id, db=db)
    await db.commit()  # flush before broadcasting so receivers can query
    # Broadcast as NEW_MESSAGE: clients already insert it into the open thread and
    # refresh the conversation list (which refetches disappear_after_sec).
    await ws_manager.publish_to_users(
        recipients, WsEventServer.NEW_MESSAGE, out.model_dump(mode="json")
    )
    return OkResponse()


# --- Pinned message (batch 4) ------------------------------------------------ #

_PIN_STATUS = {
    "message_not_found": status.HTTP_404_NOT_FOUND,
    "not_authorized": status.HTTP_403_FORBIDDEN,
    "invalid_pin_duration": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "message_deleted": status.HTTP_409_CONFLICT,
    "message_not_pinnable": status.HTTP_409_CONFLICT,
}


async def _publish_pin(
    conv: Conversation,
    event: WsEventServer,
    message_id: uuid.UUID | None,
    actor_id: uuid.UUID | None,
    db: AsyncSession,
) -> None:
    recipients = await MessageService.member_ids(conversation_id=conv.id, db=db)
    payload = MessagePinnedEvent(
        conversation_id=conv.id,
        message_id=message_id,
        pinned_until=conv.pinned_until
        if event == WsEventServer.MESSAGE_PINNED
        else None,
        actor_id=actor_id,
    )
    await db.commit()
    await db.refresh(conv)  # commit expired the row; the response reads it
    await ws_manager.publish_to_users(
        recipients, event, payload.model_dump(mode="json")
    )


@router.put(ApiRoutes.CONVERSATIONS_PIN, response_model=ConversationOut)
async def pin_message(
    conversation_id: uuid.UUID,
    body: ConversationPinIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ConversationOut:
    """Pin one message to the top of the thread for 24h / 7d / 30d. Direct:
    either member; group: admin+. Replaces any current pin."""
    await enforce_rate_limit(user.id, "pin_message", RATE_LIMIT_PINS_PER_MINUTE)
    conv = await _assert_member(conversation_id, user.id, db)
    try:
        msg = await MessageService.pin_message(
            conv=conv,
            message_id=body.message_id,
            user_id=user.id,
            duration_sec=body.duration_sec,
            db=db,
        )
    except MessageError as e:
        raise HTTPException(
            _PIN_STATUS.get(str(e), status.HTTP_409_CONFLICT), detail=str(e)
        ) from e
    await _publish_pin(conv, WsEventServer.MESSAGE_PINNED, msg.id, user.id, db)
    members = await MessageService.member_ids(conversation_id=conversation_id, db=db)
    out = _to_out(conv, members, None, (await _group_ids([conv], db)).get(conv.id))
    out.media_export_allowed = await MediaService.export_allowed(user_id=user.id, conv=conv, db=db)
    return out


@router.delete(ApiRoutes.CONVERSATIONS_PIN, response_model=ConversationOut)
async def unpin_message(
    conversation_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ConversationOut:
    """Remove the pin (same roles as pinning). Nothing pinned = no-op."""
    await enforce_rate_limit(user.id, "pin_message", RATE_LIMIT_PINS_PER_MINUTE)
    conv = await _assert_member(conversation_id, user.id, db)
    try:
        previous = await MessageService.unpin_message(conv=conv, user_id=user.id, db=db)
    except MessageError as e:
        raise HTTPException(
            _PIN_STATUS.get(str(e), status.HTTP_409_CONFLICT), detail=str(e)
        ) from e
    if previous is not None:
        await _publish_pin(conv, WsEventServer.MESSAGE_UNPINNED, previous, user.id, db)
    members = await MessageService.member_ids(conversation_id=conversation_id, db=db)
    out = _to_out(conv, members, None, (await _group_ids([conv], db)).get(conv.id))
    out.media_export_allowed = await MediaService.export_allowed(user_id=user.id, conv=conv, db=db)
    return out
