from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.constants import (
    MESSAGE_DELETED_PREVIEW,
    CHAT_LIST_PREVIEW_MAX_LEN,
    DISAPPEAR_OPTIONS_SEC,
    MESSAGES_PAGE_SIZE,
    RATE_LIMIT_READS_PER_MINUTE,
)
from app.core import permissions
from app.core.config import settings
from app.core.security import decrypt_message, encrypt_message
from app.core.dependencies import get_current_user, require_entitled
from app.core.enums import (
    AuditAction,
    ConversationAccess,
    ConversationType,
    MessageType,
    OrgRole,
    WsEventServer,
)
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.models import (
    Conversation,
    ConversationMember,
    Message,
    OrgMember,
    ScheduledMessage,
    User,
)
from app.schemas.common import OkResponse
from app.services.relationship_service import RelationshipService
from app.schemas.conversation import (
    ConversationAddMembersIn,
    ConversationCreateIn,
    ConversationOut,
    ConversationSettingsIn,
)
from app.schemas.message import (
    MessageOut,
    MessageScheduleIn,
    MessageSendIn,
    ScheduledMessageOut,
)
from app.services.audit_service import AuditService, request_meta
from app.services.group_service import GroupService
from app.services.message_service import MessageError, MessageService
from app.services.push_service import PushService

router = APIRouter()


async def _assert_member(conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession) -> Conversation:
    conv = await db.scalar(select(Conversation).where(Conversation.id == conversation_id))
    if conv is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="conversation_not_found")
    member = await db.scalar(
        select(ConversationMember).where(
            ConversationMember.conversation_id == conversation_id,
            ConversationMember.user_id == user_id,
        )
    )
    if member is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="not_a_conversation_member")
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


async def _is_org_admin(org_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession) -> bool:
    member = await db.scalar(
        select(OrgMember).where(
            OrgMember.org_id == org_id, OrgMember.user_id == user_id
        )
    )
    return member is not None and member.org_role == OrgRole.ADMIN


def _preview_for(msg: Message | None) -> str | None:
    if msg is not None and msg.deleted_at is not None:
        return MESSAGE_DELETED_PREVIEW
    if msg is None or msg.content_encrypted is None or msg.type not in (
        MessageType.TEXT,
        MessageType.SYSTEM,
    ):
        return None
    try:
        text = decrypt_message(msg.content_encrypted)
    except Exception:
        return None
    text = text.strip()
    if len(text) > CHAT_LIST_PREVIEW_MAX_LEN:
        text = text[: CHAT_LIST_PREVIEW_MAX_LEN - 1].rstrip() + "…"
    return text


def _to_out(
    conv: Conversation,
    member_ids: list[uuid.UUID],
    last_msg: Message | None = None,
) -> ConversationOut:
    out = ConversationOut.model_validate(conv)
    out.member_ids = member_ids
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
    conv_ids = [c.id for c in convs]
    # Batched: 4 queries total regardless of conversation count (was ~2×N).
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
    out: list[ConversationOut] = []
    for c in convs:
        o = _to_out(c, conv_members[c.id], latest.get(c.id))
        if c.type == ConversationType.DIRECT:
            o.display_name = next(
                (names[uid] for uid in conv_members[c.id] if uid != user.id and uid in names),
                None,
            )
        o.unread_count = unread.get(c.id, 0)
        out.append(o)
    return out


@router.post(ApiRoutes.CONVERSATIONS_CREATE, response_model=ConversationOut)
async def create_conversation(
    body: ConversationCreateIn,
    user: User = Depends(require_entitled),
    db: AsyncSession = Depends(get_db),
) -> ConversationOut:
    # Use caller's org. For MVP, use the first org the caller belongs to.
    caller_org = await db.scalar(
        select(OrgMember.org_id).where(OrgMember.user_id == user.id).limit(1)
    )
    if caller_org is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="user_not_in_any_org")

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
            reason = "user_unavailable" if decision.reason == "blocked" else decision.reason
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail=reason)
        # Connected cross-org pairs are staged behind the network flag.
        if not ctx.shared_org_ids and not settings.NETWORK_DM_ENABLED:
            raise HTTPException(
                status.HTTP_403_FORBIDDEN, detail="network_dm_disabled"
            )
        create_access = ConversationAccess.OPEN
        create_initiator = None
        # Direct conversations are always network-scoped (org_id=NULL, forced by
        # the service); org_id passed here is ignored for direct.
        conv_org = None
    else:
        # Group conversations keep the org gate + org ownership unchanged.
        await _assert_users_in_org(caller_org, body.member_ids, db)
        conv_org = caller_org
        create_access = ConversationAccess.OPEN
        create_initiator = None

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
        )
    except MessageError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e

    members = await MessageService.conversation_members(conversation_id=conv.id, db=db)
    out = _to_out(conv, [m.user_id for m in members])
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
    after_seq: int | None = Query(default=None, ge=0),
    limit: int = Query(default=MESSAGES_PAGE_SIZE, ge=1, le=MESSAGES_PAGE_SIZE),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[MessageOut]:
    if before is not None and after_seq is not None:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, detail="before_and_after_seq_exclusive"
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
    )
    # A3 hybrid: GROUP ticks come from member seq cursors, DIRECT from receipts.
    if conv.type == ConversationType.GROUP:
        read_ids, delivered_ids = await MessageService.group_receipt_ids(
            msgs=msgs, conv=conv, db=db
        )
    else:
        read_ids = await MessageService.read_message_ids(
            message_ids=[m.id for m in msgs], db=db
        )
        delivered_ids = await MessageService.delivered_message_ids(
            message_ids=[m.id for m in msgs], db=db
        )
    return [
        MessageService.to_out(m, read=m.id in read_ids, delivered=m.id in delivered_ids)
        for m in msgs
    ]


@router.post(ApiRoutes.CONVERSATIONS_MESSAGES, response_model=MessageOut)
async def send_message(
    conversation_id: uuid.UUID,
    body: MessageSendIn,
    request: Request,
    user: User = Depends(require_entitled),
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
                detail = "not_connected" if decision.reason == "not_connected" else "not_reachable"
                raise HTTPException(status.HTTP_403_FORBIDDEN, detail=detail)
    ip, user_agent = request_meta(request)
    try:
        msg = await MessageService.send_text(
            conversation_id=conversation_id,
            sender_id=user.id,
            content=body.content,
            db=db,
            client_id=body.client_id,
            ip_address=ip,
            user_agent=user_agent,
        )
    except MessageError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e

    out = MessageService.to_out(msg)
    recipients = await MessageService.member_ids(conversation_id=conversation_id, db=db)

    await db.commit()  # flush before broadcasting so receivers can query
    await ws_manager.publish_to_users(
        recipients,
        WsEventServer.NEW_MESSAGE,
        out.model_dump(mode="json"),
    )
    PushService.notify_new_message(
        conversation_id=conversation_id, recipient_ids=recipients, sender_id=user.id
    )
    return out


@router.post(ApiRoutes.CONVERSATIONS_MESSAGES_SCHEDULE, response_model=ScheduledMessageOut)
async def schedule_message(
    conversation_id: uuid.UUID,
    body: MessageScheduleIn,
    user: User = Depends(require_entitled),
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
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="invalid_schedule_time") from e
    if local.tzinfo is None:
        local = local.replace(tzinfo=tz)
    scheduled_at = local.astimezone(timezone.utc)
    now = datetime.now(tz=timezone.utc)
    if scheduled_at <= now + timedelta(seconds=30) or scheduled_at > now + timedelta(days=365):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="invalid_schedule_time")

    row = ScheduledMessage(
        conversation_id=conversation_id,
        sender_id=user.id,
        content_encrypted=encrypt_message(body.content),
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
    await db.commit()
    # One conversation-level event: senders flip all their ticks to read.
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
    conv = await _assert_member(conversation_id, user.id, db)
    changed = await MessageService.mark_conversation_delivered(
        conversation_id=conversation_id, user_id=user.id, db=db
    )
    if changed:
        recipients = await MessageService.member_ids(conversation_id=conversation_id, db=db)
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
        recipients = await MessageService.member_ids(conversation_id=conversation_id, db=db)
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
    msg = await MessageService.send_system(conv=conv, sender_id=user.id, content=text, db=db)
    out = MessageService.to_out(msg)
    recipients = await MessageService.member_ids(conversation_id=conversation_id, db=db)
    await db.commit()  # flush before broadcasting so receivers can query
    # Broadcast as NEW_MESSAGE: clients already insert it into the open thread and
    # refresh the conversation list (which refetches disappear_after_sec).
    await ws_manager.publish_to_users(
        recipients, WsEventServer.NEW_MESSAGE, out.model_dump(mode="json")
    )
    return OkResponse()


