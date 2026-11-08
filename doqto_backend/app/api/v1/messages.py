from __future__ import annotations

import base64
import binascii
import logging
import uuid

from datetime import datetime

from fastapi import APIRouter, Depends, Form, HTTPException, Query, Request, UploadFile, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.constants import (
    ADMIN_REMOVED_MESSAGE_TEXT,
    CAPTION_MAX_LEN,
    PRESIGNED_URL_TTL_SECONDS,
    RATE_LIMIT_EXPORT_AUDITS_PER_MINUTE,
    RATE_LIMIT_FORWARDS_PER_MINUTE,
    RATE_LIMIT_REACTIONS_PER_MINUTE,
    RATE_LIMIT_READS_PER_MINUTE,
    RATE_LIMIT_STARS_PER_MINUTE,
    RATE_LIMIT_UPLOAD_INTENTS_PER_MINUTE,
    RATE_LIMIT_VOTES_PER_MINUTE,
    STARRED_PAGE_SIZE,
    THUMB_CONTENT_TYPE,
    THUMB_MAX_BYTES,
    UPLOAD_INLINE_MAX_BYTES,
    VIDEO_MAX_DURATION_SEC,
    VOICE_NOTE_MAX_DURATION_SECONDS,
    VOICE_NOTE_MAX_FILE_BYTES,
    VOICE_NOTE_MIN_DURATION_SECONDS,
    VOICE_NOTE_WAVEFORM_MAX_BYTES,
)
from app.core.dependencies import get_current_user
from app.core.enums import (
    AuditAction,
    ConversationType,
    MessageType,
    TranscriptStatus,
    WsEventServer,
)
from app.core.routes import ApiRoutes
from app.core.rate_limit import enforce_rate_limit
from app.core.security import decrypt_message, encrypt_message
from app.db.postgres import get_db
from app.models import Conversation, ConversationMember, Message, MessageReceipt, User
from app.schemas.common import OkResponse
from app.schemas.message import (
    FileUrlOut,
    MessageEditIn,
    MessageEditOut,
    MessageForwardIn,
    MessageHideIn,
    MessageOut,
    MessageReactedEvent,
    MessageReactIn,
    MessageReceiptOut,
    MessageStarredEvent,
    PollUpdatedEvent,
    PollVoteIn,
    StarredMessageOut,
    StarredPage,
    UploadCompleteIn,
    UploadIntentIn,
    UploadIntentOut,
)
from app.services.audit_service import AuditService
from app.services.file_service import FileService
from app.services.image_service import strip_image_metadata
from app.services.media_service import MediaService
from app.services.message_service import MessageError, MessageService
from app.services.push_service import PushService
from app.services.transcription_service import TranscriptionService

router = APIRouter()


async def _assert_conv_member(
    conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
) -> Conversation:
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


def _caption_or_422(caption: str | None) -> str | None:
    if caption is not None and len(caption) > CAPTION_MAX_LEN:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail="caption_too_long")
    return caption


async def _fanout_new_message(msg: Message, user: User, db: AsyncSession) -> MessageOut:
    """Commit, then `new_message` to every member + presence-gated push."""
    recipients = await MessageService.member_ids(conversation_id=msg.conversation_id, db=db)
    out = (await MessageService.outs_for([msg], db=db))[0]
    await db.commit()
    await ws_manager.publish_to_users(
        recipients, WsEventServer.NEW_MESSAGE, out.model_dump(mode="json")
    )
    PushService.notify_new_message(
        conversation_id=msg.conversation_id, recipient_ids=recipients, sender_id=user.id
    )
    return out


@router.post(ApiRoutes.MESSAGES_UPLOAD, response_model=MessageOut)
async def upload_file(
    conversation_id: uuid.UUID,
    file: UploadFile,
    client_id: str | None = Form(default=None, max_length=64),
    caption: str | None = Form(default=None),
    thumb: UploadFile | None = None,
    duration_sec: int | None = Form(default=None, ge=0),
    width: int | None = Form(default=None, ge=1, le=20000),
    height: int | None = Form(default=None, ge=1, le=20000),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Inline upload (≤ UPLOAD_INLINE_MAX_BYTES): image / video / file. Images
    are EXIF-stripped server-side; a video may carry a JPEG `thumb` part
    (poster) and `duration_sec`. Bigger payloads use upload-intent."""
    await enforce_rate_limit(user.id, "upload_file")
    conv = await _assert_conv_member(conversation_id, user.id, db)
    _caption_or_422(caption)

    # Idempotency: a retried upload (same outbox client_id) returns the
    # original row — no re-upload, no re-broadcast.
    if client_id is not None:
        existing = await MessageService.find_by_client_id(
            conversation_id=conversation_id, client_id=client_id, db=db
        )
        if existing is not None:
            return (await MessageService.outs_for([existing], db=db))[0]

    data = await file.read()
    if len(data) > UPLOAD_INLINE_MAX_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="file_too_large")
    content_type = file.content_type or "application/octet-stream"
    msg_type = MediaService.type_for(content_type)
    if msg_type == MessageType.IMAGE:
        data = strip_image_metadata(data, content_type)
    if msg_type == MessageType.VIDEO and duration_sec is not None and duration_sec > VIDEO_MAX_DURATION_SEC:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail="video_too_long")
    thumb_data: bytes | None = None
    if thumb is not None and msg_type == MessageType.VIDEO:
        thumb_data = await thumb.read()
        if len(thumb_data) > THUMB_MAX_BYTES:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail="thumb_too_large")
        thumb_data = strip_image_metadata(thumb_data, THUMB_CONTENT_TYPE) if thumb_data else None

    msg = Message(
        conversation_id=conversation_id,
        sender_id=user.id,
        type=msg_type,
        seq=await MessageService.next_seq(conversation_id=conversation_id, db=db),
        client_id=client_id,
        file_name=file.filename,
        file_size_bytes=len(data),
        voice_duration_sec=duration_sec if msg_type == MessageType.VIDEO else None,
        caption_encrypted=MediaService.encrypt_caption(caption),
        media_width=width,
        media_height=height,
        expires_at=MessageService.expiry_for(conv),
    )
    db.add(msg)
    await db.flush()
    # Network (cross-org) conversations have no org_id → conversation-scoped key.
    key = FileService.media_key(
        org_id=conv.org_id,
        conversation_id=conversation_id,
        message_id=msg.id,
        filename=file.filename or "file",
    )
    await FileService.upload_bytes(key=key, data=data, content_type=content_type)
    msg.s3_key = key
    if thumb_data:
        tkey = FileService.thumb_key(
            org_id=conv.org_id, conversation_id=conversation_id, message_id=msg.id
        )
        await FileService.upload_bytes(key=tkey, data=thumb_data, content_type=THUMB_CONTENT_TYPE)
        msg.thumb_key = tkey
    await AuditService.log(
        db,
        user_id=user.id,
        action=AuditAction.FILE_UPLOADED,
        resource_type="message",
        resource_id=msg.id,
    )
    return await _fanout_new_message(msg, user, db)


# --- Presigned multipart upload (batch 5) ------------------------------------ #

_UPLOAD_STATUS = {
    "file_too_large": status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
    "thumb_not_allowed": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "upload_parts_invalid": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "video_too_long": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "upload_intent_not_found": status.HTTP_404_NOT_FOUND,
    "upload_intent_expired": status.HTTP_409_CONFLICT,
    "upload_intent_completed": status.HTTP_409_CONFLICT,
    "upload_missing": status.HTTP_409_CONFLICT,
}


@router.post(ApiRoutes.MESSAGES_UPLOAD_INTENT, response_model=UploadIntentOut)
async def upload_intent(
    conversation_id: uuid.UUID,
    body: UploadIntentIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> UploadIntentOut:
    """Step 1 of a large upload (file / video ≤ 100 MB): presigned URLs the
    client PUTs to directly. One `put_url` under the multipart threshold,
    otherwise `upload_id` + `part_urls` (`part_size` bytes each, last part
    shorter). `with_thumb` (video only) adds `thumb_put_url` for a JPEG poster.
    A `client_id` already sent returns `message` and nothing to upload."""
    await enforce_rate_limit(user.id, "upload_intent", RATE_LIMIT_UPLOAD_INTENTS_PER_MINUTE)
    conv = await _assert_conv_member(conversation_id, user.id, db)
    try:
        out = await MediaService.create_intent(conv=conv, user_id=user.id, body=body, db=db)
    except MessageError as e:
        raise HTTPException(_UPLOAD_STATUS.get(str(e), status.HTTP_400_BAD_REQUEST), detail=str(e)) from e
    await db.commit()
    return out


@router.post(ApiRoutes.MESSAGES_UPLOAD_COMPLETE, response_model=MessageOut)
async def upload_complete(
    conversation_id: uuid.UUID,
    body: UploadCompleteIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Step 2: the bytes are in S3 — finish the multipart upload (all parts
    with their ETags), verify the object, strip image metadata, and create
    the message. Idempotent: completing twice returns the same message."""
    await enforce_rate_limit(user.id, "upload_complete", RATE_LIMIT_UPLOAD_INTENTS_PER_MINUTE)
    conv = await _assert_conv_member(conversation_id, user.id, db)
    try:
        msg, created = await MediaService.complete_intent(
            conv=conv, user_id=user.id, body=body, db=db
        )
    except MessageError as e:
        raise HTTPException(_UPLOAD_STATUS.get(str(e), status.HTTP_400_BAD_REQUEST), detail=str(e)) from e
    if not created:
        # Replay of a completed intent: the row already exists, nothing to fan out.
        return (await MessageService.outs_for([msg], db=db))[0]
    return await _fanout_new_message(msg, user, db)


def _decode_waveform(waveform: str | None) -> bytes | None:
    """base64 of ≤ VOICE_NOTE_WAVEFORM_MAX_BYTES amplitude bytes, or 422."""
    if not waveform:
        return None
    try:
        raw = base64.b64decode(waveform, validate=True)
    except (binascii.Error, ValueError) as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail="waveform_invalid") from e
    if not raw or len(raw) > VOICE_NOTE_WAVEFORM_MAX_BYTES:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, detail="waveform_invalid")
    return raw


@router.post(ApiRoutes.MESSAGES_VOICE_NOTE, response_model=MessageOut)
async def upload_voice_note(
    conversation_id: uuid.UUID,
    file: UploadFile,
    duration_sec: int = Form(default=0),
    transcript: str = Form(default=""),
    client_id: str | None = Form(default=None, max_length=64),
    waveform: str | None = Form(default=None, max_length=128),
    caption: str | None = Form(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    await enforce_rate_limit(user.id, "upload_voice_note")
    conv = await _assert_conv_member(conversation_id, user.id, db)
    _caption_or_422(caption)
    waveform_bytes = _decode_waveform(waveform)
    # The bounds declared in constants are the contract: a clip the recorder
    # cut too short, or one longer than the server-side cap, is refused.
    if not (VOICE_NOTE_MIN_DURATION_SECONDS <= duration_sec <= VOICE_NOTE_MAX_DURATION_SECONDS):
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, detail="voice_note_duration"
        )

    # Idempotency: a retried upload (same outbox client_id) returns the
    # original row — no re-upload, no re-broadcast.
    if client_id is not None:
        existing = await MessageService.find_by_client_id(
            conversation_id=conversation_id, client_id=client_id, db=db
        )
        if existing is not None:
            return MessageService.to_out(existing)

    data = await file.read()
    if len(data) > VOICE_NOTE_MAX_FILE_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="voice_note_too_large")

    client_transcript = transcript.strip() if transcript else ""

    msg = Message(
        conversation_id=conversation_id,
        sender_id=user.id,
        type=MessageType.VOICE_NOTE,
        seq=await MessageService.next_seq(conversation_id=conversation_id, db=db),
        client_id=client_id,
        file_name=file.filename,
        file_size_bytes=len(data),
        voice_duration_sec=duration_sec,
        transcript_encrypted=encrypt_message(client_transcript) if client_transcript else None,
        transcript_status=TranscriptStatus.COMPLETED if client_transcript else TranscriptStatus.PENDING,
        expires_at=MessageService.expiry_for(conv),
        waveform=waveform_bytes,
        caption_encrypted=MediaService.encrypt_caption(caption),
    )
    db.add(msg)
    await db.flush()
    if conv.org_id is None:
        key = FileService.key_for_network_voice_note(
            conversation_id=conversation_id, message_id=msg.id
        )
    else:
        key = FileService.key_for_voice_note(org_id=conv.org_id, message_id=msg.id)
    content_type = file.content_type or "audio/wav"
    await FileService.upload_bytes(key=key, data=data, content_type=content_type)
    msg.s3_key = key
    await AuditService.log(
        db,
        user_id=user.id,
        action=AuditAction.FILE_UPLOADED,
        resource_type="message",
        resource_id=msg.id,
    )
    recipients = await MessageService.member_ids(conversation_id=conversation_id, db=db)
    await db.commit()

    out = MessageService.to_out(msg)
    await ws_manager.publish_to_users(
        recipients, WsEventServer.NEW_MESSAGE, out.model_dump(mode="json")
    )
    # Presence-gated push for members without a live WS (fire-and-forget).
    PushService.notify_new_message(
        conversation_id=conversation_id, recipient_ids=recipients, sender_id=user.id
    )

    if not client_transcript:
        # Transcription is best-effort: real Transcribe Medical is not wired
        # yet (deferred HIPAA item), and a transcription failure must never
        # fail the voice note itself — it was already stored and fanned out.
        try:
            await TranscriptionService.start(message_id=str(msg.id), s3_key=key)
            server_transcript = await TranscriptionService.fetch(
                message_id=str(msg.id)
            )
        except Exception:
            logging.getLogger("doqto.transcribe").warning(
                "transcription unavailable; voice note %s sent without transcript",
                msg.id,
            )
            server_transcript = None
        if server_transcript:
            msg.transcript_encrypted = encrypt_message(server_transcript)
            msg.transcript_status = TranscriptStatus.COMPLETED
            await db.commit()
            await ws_manager.publish_to_users(
                recipients,
                WsEventServer.TRANSCRIPT_READY,
                {"message_id": str(msg.id), "transcript": server_transcript},
            )
    return MessageService.to_out(msg)


@router.post(ApiRoutes.MESSAGES_READ, response_model=OkResponse)
async def mark_read(
    message_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    msg = await db.scalar(select(Message).where(Message.id == message_id))
    if msg is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="message_not_found")
    await _assert_conv_member(msg.conversation_id, user.id, db)
    await MessageService.mark_read(message_id=message_id, user_id=user.id, db=db)
    conv = await db.scalar(select(Conversation).where(Conversation.id == msg.conversation_id))
    # Stored regardless; not emitted when either party turned receipts off.
    if conv is not None and await MessageService.read_receipts_enabled(conv=conv, db=db):
        recipients = await MessageService.member_ids(
            conversation_id=msg.conversation_id, db=db
        )
        await ws_manager.publish_to_users(
            recipients,
            WsEventServer.MESSAGE_READ,
            {
                "message_id": str(message_id),
                "conversation_id": str(msg.conversation_id),
                "user_id": str(user.id),
            },
        )
    return OkResponse()


@router.get(ApiRoutes.MESSAGES_RECEIPTS, response_model=list[MessageReceiptOut])
async def message_receipts(
    message_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[MessageReceiptOut]:
    """Message info: who it was delivered to and who read it, with times.
    Sender-only (the way WhatsApp shows it). Groups derive the state from the
    A3 member seq cursors; direct chats from message_receipts rows. A non-member
    gets the same 404 as a message that does not exist."""
    await enforce_rate_limit(user.id, "message_receipts", RATE_LIMIT_READS_PER_MINUTE)
    msg = await db.scalar(select(Message).where(Message.id == message_id))
    if msg is None or msg.is_deleted:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="message_not_found")
    conv = await db.scalar(select(Conversation).where(Conversation.id == msg.conversation_id))
    members = (
        await db.execute(
            select(ConversationMember, User)
            .join(User, User.id == ConversationMember.user_id)
            .where(ConversationMember.conversation_id == msg.conversation_id)
        )
    ).all()
    if conv is None or not any(m.user_id == user.id for m, _ in members):
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="message_not_found")
    if msg.sender_id != user.id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="not_message_sender")
    # Who-read-what is PHI-adjacent access to the thread: audit like a read.
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=AuditAction.MESSAGE_RECEIPTS_READ,
        resource_type="message",
        resource_id=message_id,
        db=db,
    )
    await db.commit()
    receipts: dict[uuid.UUID, MessageReceipt] = {}
    show_read = True
    if conv.type != ConversationType.GROUP:
        rows = await db.scalars(
            select(MessageReceipt).where(MessageReceipt.message_id == message_id)
        )
        receipts = {r.user_id: r for r in rows.all()}
        # Either party opted out of read receipts → delivered only (batch 2).
        show_read = await MessageService.read_receipts_enabled(conv=conv, db=db)
    out: list[MessageReceiptOut] = []
    for member, u in members:
        if member.user_id == msg.sender_id:
            continue
        row = MessageReceiptOut(
            user_id=u.id,
            full_name=u.full_name,
            avatar_color=u.avatar_color,
            avatar_url=u.avatar_url,
            avatar_presigned_url=(
                await FileService.presigned_url(key=u.avatar_url) if u.avatar_url else None
            ),
        )
        if conv.type == ConversationType.GROUP:
            row.read = member.last_read_seq >= msg.seq
            row.delivered = row.read or member.last_delivered_seq >= msg.seq
            row.read_at = member.last_read_at if row.read else None
            row.delivered_at = row.read_at
        else:
            r = receipts.get(member.user_id)
            if r is not None:
                row.read = show_read and r.read_at is not None
                row.delivered = r.read_at is not None or r.delivered_at is not None
                row.read_at = r.read_at if show_read else None
                row.delivered_at = r.delivered_at or r.read_at
        out.append(row)
    # Read first, then delivered, then pending; stable by name inside each.
    out.sort(key=lambda r: (0 if r.read else 1 if r.delivered else 2, r.full_name))
    return out


@router.get(ApiRoutes.MESSAGES_FILE_URL, response_model=FileUrlOut)
async def get_file_url(
    message_id: uuid.UUID,
    thumb: bool = Query(default=False),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> FileUrlOut:
    """Presigned GET for the media object — or, with `?thumb=1`, for a
    video's poster thumbnail (404 `file_not_found` when there is none)."""
    await enforce_rate_limit(user.id, "get_file_url", RATE_LIMIT_READS_PER_MINUTE)
    msg = await db.scalar(select(Message).where(Message.id == message_id))
    key = (msg.thumb_key if thumb else msg.s3_key) if msg is not None else None
    if msg is None or not key:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="file_not_found")
    await _assert_conv_member(msg.conversation_id, user.id, db)
    url = await FileService.presigned_url(key=key)
    await AuditService.log(
        db,
        user_id=user.id,
        action=AuditAction.FILE_ACCESSED,
        resource_type="message",
        resource_id=message_id,
    )
    return FileUrlOut(url=url, expires_in=PRESIGNED_URL_TTL_SECONDS)


# MessageError → HTTP status for the edit/delete/react/forward/star paths.
# Anything not listed is a 409 state conflict (window closed, tombstone, …).
_EDIT_DELETE_STATUS = {
    "message_not_found": status.HTTP_404_NOT_FOUND,
    "conversation_not_found": status.HTTP_404_NOT_FOUND,
    "not_message_sender": status.HTTP_403_FORBIDDEN,
    "not_a_conversation_member": status.HTTP_403_FORBIDDEN,
    "invalid_emoji": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "not_reachable": status.HTTP_403_FORBIDDEN,
    "not_connected": status.HTTP_403_FORBIDDEN,
    "group_dm_request": status.HTTP_403_FORBIDDEN,
    "group_dm_disabled": status.HTTP_403_FORBIDDEN,
    "post_restricted": status.HTTP_403_FORBIDDEN,
    "conversation_not_open": status.HTTP_403_FORBIDDEN,
    "forward_blocked_by_org": status.HTTP_403_FORBIDDEN,
    "forward_limit": status.HTTP_422_UNPROCESSABLE_ENTITY,
    # Batch 5
    "file_not_found": status.HTTP_404_NOT_FOUND,
    "media_export_blocked": status.HTTP_403_FORBIDDEN,
    "not_a_poll": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "poll_option_invalid": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "poll_single_choice": status.HTTP_422_UNPROCESSABLE_ENTITY,
}


def _raise_edit_delete(e: MessageError) -> None:
    raise HTTPException(
        _EDIT_DELETE_STATUS.get(str(e), status.HTTP_409_CONFLICT), detail=str(e)
    ) from e


async def _broadcast(msg: Message, event: WsEventServer, db: AsyncSession) -> MessageOut:
    recipients = await MessageService.member_ids(conversation_id=msg.conversation_id, db=db)
    # Edits keep reactions and the quote; the client swaps the row, so the
    # payload must carry them.
    out = (await MessageService.outs_for([msg], db=db))[0]
    await db.commit()
    await ws_manager.publish_to_users(recipients, event, out.model_dump(mode="json"))
    return out


@router.patch(ApiRoutes.MESSAGES_DETAIL, response_model=MessageOut)
async def edit_message(
    message_id: uuid.UUID,
    body: MessageEditIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Sender edits a text message within the edit window; history is kept."""
    await enforce_rate_limit(user.id, "edit_message")
    try:
        msg = await MessageService.edit_message(
            message_id=message_id, user_id=user.id, content=body.content, db=db
        )
    except MessageError as e:
        _raise_edit_delete(e)
    return await _broadcast(msg, WsEventServer.MESSAGE_EDITED, db)


@router.delete(ApiRoutes.MESSAGES_DETAIL, response_model=MessageOut)
async def delete_message(
    message_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Sender deletes within the delete window → tombstone for every member.
    A group admin may delete any member's message (any age); the thread then
    shows the system line "Admin removed a message"."""
    await enforce_rate_limit(user.id, "delete_message")
    try:
        msg, s3_keys, by_admin = await MessageService.delete_message(
            message_id=message_id, user_id=user.id, db=db
        )
    except MessageError as e:
        _raise_edit_delete(e)
    system_out: MessageOut | None = None
    recipients: list[uuid.UUID] = []
    if by_admin:
        conv = await db.get(Conversation, msg.conversation_id)
        system_msg = await MessageService.send_system(
            conv=conv, sender_id=user.id, content=ADMIN_REMOVED_MESSAGE_TEXT, db=db
        )
        system_out = MessageService.to_out(system_msg)
        recipients = await MessageService.member_ids(conversation_id=conv.id, db=db)
    out = await _broadcast(msg, WsEventServer.MESSAGE_DELETED, db)
    if system_out is not None:
        await ws_manager.publish_to_users(
            recipients, WsEventServer.NEW_MESSAGE, system_out.model_dump(mode="json")
        )
    for s3_key in s3_keys:
        # Best-effort: the row is already shredded; a stray object is caught by
        # the purge job's key sweep if this fails.
        try:
            await FileService.delete_object(key=s3_key)
        except Exception:
            logging.getLogger("doqto.messages").warning("s3 delete failed for %s", s3_key)
    return out


async def _reaction_response(
    msg: Message, changed: bool, actor_id: uuid.UUID, emoji: str | None, db: AsyncSession
) -> MessageOut:
    """Commit, then (only if something changed) fan out `message_reacted` to
    every member — the actor too, for their other devices — and push the
    author when someone else added or replaced a reaction."""
    reactions = (await MessageService.reactions_for(message_ids=[msg.id], db=db)).get(
        msg.id, []
    )
    out = MessageService.to_out(msg, reactions=reactions)
    if not changed:
        return out
    recipients = await MessageService.member_ids(conversation_id=msg.conversation_id, db=db)
    await db.commit()
    event = MessageReactedEvent(
        conversation_id=msg.conversation_id,
        message_id=msg.id,
        reactions=reactions,
        changed_at=msg.changed_at,
        actor_id=actor_id,
        emoji=emoji,
    )
    await ws_manager.publish_to_users(
        recipients, WsEventServer.MESSAGE_REACTED, event.model_dump(mode="json")
    )
    if emoji is not None and msg.sender_id != actor_id:
        PushService.notify_reaction(
            conversation_id=msg.conversation_id,
            author_id=msg.sender_id,
            actor_id=actor_id,
            emoji=emoji,
        )
    return out


@router.put(ApiRoutes.MESSAGES_REACTION, response_model=MessageOut)
async def set_reaction(
    message_id: uuid.UUID,
    body: MessageReactIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Add or replace the caller's one reaction. Same emoji again = no-op."""
    await enforce_rate_limit(user.id, "react_message", RATE_LIMIT_REACTIONS_PER_MINUTE)
    try:
        msg, changed = await MessageService.set_reaction(
            message_id=message_id, user_id=user.id, emoji=body.emoji, db=db
        )
    except MessageError as e:
        _raise_edit_delete(e)
    return await _reaction_response(msg, changed, user.id, body.emoji, db)


@router.delete(ApiRoutes.MESSAGES_REACTION, response_model=MessageOut)
async def remove_reaction(
    message_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Remove the caller's reaction. None to remove = no-op."""
    await enforce_rate_limit(user.id, "react_message", RATE_LIMIT_REACTIONS_PER_MINUTE)
    try:
        msg, changed = await MessageService.remove_reaction(
            message_id=message_id, user_id=user.id, db=db
        )
    except MessageError as e:
        _raise_edit_delete(e)
    return await _reaction_response(msg, changed, user.id, None, db)


@router.post(ApiRoutes.MESSAGES_HIDE, response_model=OkResponse)
async def hide_messages(
    body: MessageHideIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    """'Delete for me': hide messages from this user's view only."""
    await enforce_rate_limit(user.id, "hide_messages")
    await MessageService.hide_messages(message_ids=body.message_ids, user_id=user.id, db=db)
    return OkResponse()


@router.get(ApiRoutes.MESSAGES_EDITS, response_model=list[MessageEditOut])
async def list_message_edits(
    message_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[MessageEditOut]:
    """Every previous version, oldest first — visible to all members."""
    await enforce_rate_limit(user.id, "list_message_edits", RATE_LIMIT_READS_PER_MINUTE)
    msg = await db.scalar(select(Message).where(Message.id == message_id))
    if msg is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="message_not_found")
    await _assert_conv_member(msg.conversation_id, user.id, db)
    return [
        MessageEditOut(content=decrypt_message(e.content_encrypted), replaced_at=e.replaced_at)
        for e in await MessageService.list_edits(message_id=message_id, db=db)
    ]


# --- Media export gate (batch 5) --------------------------------------------- #


@router.post(ApiRoutes.MESSAGES_EXPORT_AUDIT, response_model=OkResponse)
async def export_audit(
    message_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    """The client calls this BEFORE Save to Photos / the share sheet. Checks the
    org policy `allow_media_export` (org chat → that org; network chat → the
    caller's own orgs, strictest wins; no org → allowed) and writes the
    FILE_EXPORTED audit row. 403 `media_export_blocked` means: do not export."""
    await enforce_rate_limit(user.id, "export_audit", RATE_LIMIT_EXPORT_AUDITS_PER_MINUTE)
    try:
        await MediaService.audit_export(message_id=message_id, user_id=user.id, db=db)
    except MessageError as e:
        _raise_edit_delete(e)
    await db.commit()
    return OkResponse()


# --- Polls (batch 5) --------------------------------------------------------- #


async def _poll_response(msg: Message, changed: bool, actor_id: uuid.UUID, db: AsyncSession) -> MessageOut:
    """Commit, then (only if the votes changed) fan out `poll_updated` with
    the full tallies to every member — the actor too, for their other devices."""
    out = (await MessageService.outs_for([msg], db=db))[0]
    if not changed:
        return out
    recipients = await MessageService.member_ids(conversation_id=msg.conversation_id, db=db)
    await db.commit()
    event = PollUpdatedEvent(
        conversation_id=msg.conversation_id,
        message_id=msg.id,
        poll=out.poll,
        changed_at=msg.changed_at,
        actor_id=actor_id,
    )
    await ws_manager.publish_to_users(
        recipients, WsEventServer.POLL_UPDATED, event.model_dump(mode="json")
    )
    return out


@router.put(ApiRoutes.MESSAGES_VOTE, response_model=MessageOut)
async def vote(
    message_id: uuid.UUID,
    body: PollVoteIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Set my selection on a poll (replaces any earlier votes of mine).
    Single-choice polls take exactly one option id."""
    await enforce_rate_limit(user.id, "poll_vote", RATE_LIMIT_VOTES_PER_MINUTE)
    try:
        msg, changed = await MediaService.set_votes(
            message_id=message_id, user_id=user.id, option_ids=body.option_ids, db=db
        )
    except MessageError as e:
        _raise_edit_delete(e)
    return await _poll_response(msg, changed, user.id, db)


@router.delete(ApiRoutes.MESSAGES_VOTE, response_model=MessageOut)
async def unvote(
    message_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Withdraw all my votes on a poll. Nothing to withdraw = no-op."""
    await enforce_rate_limit(user.id, "poll_vote", RATE_LIMIT_VOTES_PER_MINUTE)
    try:
        msg, changed = await MediaService.clear_votes(message_id=message_id, user_id=user.id, db=db)
    except MessageError as e:
        _raise_edit_delete(e)
    return await _poll_response(msg, changed, user.id, db)


# --- Forward (batch 4) ------------------------------------------------------- #


@router.post(ApiRoutes.MESSAGES_FORWARD, response_model=list[MessageOut])
async def forward_message(
    message_id: uuid.UUID,
    body: MessageForwardIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[MessageOut]:
    """Copy a message into up to 5 conversations the caller can post to. Each
    copy is a normal new message (own row, own S3 object) flagged
    `forwarded` with `forward_depth` + 1; at depth 5 forwarding stops
    (422 forward_limit). Org policy allow_forward_outside_org=false blocks
    copies leaving the source org (403 forward_blocked_by_org)."""
    await enforce_rate_limit(user.id, "forward_message", RATE_LIMIT_FORWARDS_PER_MINUTE)

    async def _copy(src_key: str, dst_key: str) -> None:
        await FileService.copy_object(src_key=src_key, dst_key=dst_key)

    try:
        copies = await MessageService.forward_message(
            message_id=message_id,
            user_id=user.id,
            conversation_ids=body.conversation_ids,
            db=db,
            copy_object=_copy,
        )
    except MessageError as e:
        _raise_edit_delete(e)
    outs = await MessageService.outs_for(copies, db=db)
    fanout: list[tuple[list[uuid.UUID], MessageOut]] = []
    for out in outs:
        recipients = await MessageService.member_ids(conversation_id=out.conversation_id, db=db)
        fanout.append((recipients, out))
    await db.commit()
    for recipients, out in fanout:
        await ws_manager.publish_to_users(
            recipients, WsEventServer.NEW_MESSAGE, out.model_dump(mode="json")
        )
        PushService.notify_new_message(
            conversation_id=out.conversation_id, recipient_ids=recipients, sender_id=user.id
        )
    return outs


# --- Stars (batch 4) --------------------------------------------------------- #


async def _star_response(
    msg: Message, changed: bool, starred: bool, user: User, db: AsyncSession
) -> MessageOut:
    out = (await MessageService.outs_for([msg], db=db, viewer_id=user.id))[0]
    if changed:
        await db.commit()
        # Private: only the actor's own devices learn about it.
        await ws_manager.publish_to_users(
            [user.id],
            WsEventServer.MESSAGE_STARRED,
            MessageStarredEvent(
                conversation_id=msg.conversation_id, message_id=msg.id, starred=starred
            ).model_dump(mode="json"),
        )
    return out


@router.put(ApiRoutes.MESSAGES_STAR, response_model=MessageOut)
async def star_message(
    message_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Bookmark a message for myself. Idempotent; nobody else can tell."""
    await enforce_rate_limit(user.id, "star_message", RATE_LIMIT_STARS_PER_MINUTE)
    try:
        msg, changed = await MessageService.set_star(
            message_id=message_id, user_id=user.id, starred=True, db=db
        )
    except MessageError as e:
        _raise_edit_delete(e)
    return await _star_response(msg, changed, True, user, db)


@router.delete(ApiRoutes.MESSAGES_STAR, response_model=MessageOut)
async def unstar_message(
    message_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    await enforce_rate_limit(user.id, "star_message", RATE_LIMIT_STARS_PER_MINUTE)
    try:
        msg, changed = await MessageService.set_star(
            message_id=message_id, user_id=user.id, starred=False, db=db
        )
    except MessageError as e:
        _raise_edit_delete(e)
    return await _star_response(msg, changed, False, user, db)


@router.get(ApiRoutes.MESSAGES_STARRED, response_model=StarredPage)
async def list_starred(
    request: Request,
    cursor: str | None = Query(default=None),
    limit: int = Query(default=STARRED_PAGE_SIZE, ge=1, le=STARRED_PAGE_SIZE),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> StarredPage:
    """My starred messages across every conversation, newest star first.
    Cursor = the last row's starred_at. Deleted / expired / hidden messages
    are never listed (and their stars are purged)."""
    await enforce_rate_limit(user.id, "list_starred", RATE_LIMIT_READS_PER_MINUTE)
    before: datetime | None = None
    if cursor:
        try:
            before = datetime.fromisoformat(cursor)
        except ValueError as e:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="invalid_cursor") from e
    rows = await MessageService.list_starred(user_id=user.id, before=before, limit=limit, db=db)
    next_cursor = None
    if len(rows) > limit:
        rows = rows[:limit]
        next_cursor = rows[-1][0].created_at.isoformat()
    # Decrypted PHI leaves the server: one audit row per page, like a thread read.
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=AuditAction.STARRED_MESSAGES_READ,
        resource_type="user",
        resource_id=user.id,
        db=db,
        metadata={"count": len(rows), "cursor": cursor},
    )
    await db.commit()
    msgs = [m for _, m, _ in rows]
    outs = await MessageService.outs_for(msgs, db=db, viewer_id=user.id)
    # Direct chats are named after the other member.
    other_ids: set[uuid.UUID] = set()
    conv_members: dict[uuid.UUID, list[uuid.UUID]] = {}
    direct_ids = [c.id for _, _, c in rows if c.type == ConversationType.DIRECT]
    if direct_ids:
        conv_members = await MessageService.members_by_conversation(
            conversation_ids=list(set(direct_ids)), db=db
        )
        for ids in conv_members.values():
            other_ids.update(uid for uid in ids if uid != user.id)
    names: dict[uuid.UUID, str] = {}
    if other_ids:
        names = dict(
            (await db.execute(select(User.id, User.full_name).where(User.id.in_(other_ids)))).all()
        )
    data: list[StarredMessageOut] = []
    for (star, _, conv), out in zip(rows, outs):
        if conv.type == ConversationType.DIRECT:
            name = next(
                (names[u] for u in conv_members.get(conv.id, []) if u != user.id and u in names),
                None,
            )
        else:
            name = conv.name
        data.append(
            StarredMessageOut(
                message=out,
                conversation_id=conv.id,
                conversation_type=str(conv.type),
                conversation_name=name,
                starred_at=star.created_at,
            )
        )
    return StarredPage(data=data, next_cursor=next_cursor)
