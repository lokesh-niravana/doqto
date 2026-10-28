from __future__ import annotations

import logging
import uuid

from fastapi import APIRouter, Depends, Form, HTTPException, UploadFile, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.constants import (
    FILE_MAX_BYTES,
    PRESIGNED_URL_TTL_SECONDS,
    RATE_LIMIT_READS_PER_MINUTE,
    VOICE_NOTE_MAX_FILE_BYTES,
)
from app.core.dependencies import get_current_user
from app.core.enums import (
    AuditAction,
    MessageType,
    TranscriptStatus,
    WsEventServer,
)
from app.core.routes import ApiRoutes
from app.core.rate_limit import enforce_rate_limit
from app.core.security import decrypt_message, encrypt_message
from app.db.postgres import get_db
from app.models import Conversation, ConversationMember, Message, User
from app.schemas.common import OkResponse
from app.schemas.message import (
    FileUrlOut,
    MessageEditIn,
    MessageEditOut,
    MessageHideIn,
    MessageOut,
)
from app.services.audit_service import AuditService
from app.services.file_service import FileService
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


@router.post("/upload/{conversation_id}", response_model=MessageOut)
async def upload_file(
    conversation_id: uuid.UUID,
    file: UploadFile,
    client_id: str | None = Form(default=None, max_length=64),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    await enforce_rate_limit(user.id, "upload_file")
    conv = await _assert_conv_member(conversation_id, user.id, db)

    # Idempotency: a retried upload (same outbox client_id) returns the
    # original row — no re-upload, no re-broadcast.
    if client_id is not None:
        existing = await MessageService.find_by_client_id(
            conversation_id=conversation_id, client_id=client_id, db=db
        )
        if existing is not None:
            return MessageService.to_out(existing)

    data = await file.read()
    if len(data) > FILE_MAX_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="file_too_large")

    msg = Message(
        conversation_id=conversation_id,
        sender_id=user.id,
        type=MessageType.FILE if not (file.content_type or "").startswith("image/") else MessageType.IMAGE,
        seq=await MessageService.next_seq(conversation_id=conversation_id, db=db),
        client_id=client_id,
        file_name=file.filename,
        file_size_bytes=len(data),
        expires_at=MessageService.expiry_for(conv),
    )
    db.add(msg)
    await db.flush()
    # Network (cross-org) conversations have no org_id → conversation-scoped key.
    if conv.org_id is None:
        key = FileService.key_for_network_file(
            conversation_id=conversation_id, message_id=msg.id, filename=file.filename or "file"
        )
    else:
        key = FileService.key_for_file(
            org_id=conv.org_id, message_id=msg.id, filename=file.filename or "file"
        )
    await FileService.upload_bytes(key=key, data=data, content_type=file.content_type or "application/octet-stream")
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
    return out


@router.post("/voice-notes/{conversation_id}", response_model=MessageOut)
async def upload_voice_note(
    conversation_id: uuid.UUID,
    file: UploadFile,
    duration_sec: int = Form(default=0),
    transcript: str = Form(default=""),
    client_id: str | None = Form(default=None, max_length=64),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    await enforce_rate_limit(user.id, "upload_voice_note")
    conv = await _assert_conv_member(conversation_id, user.id, db)

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
    if conv is not None:
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


@router.get(ApiRoutes.MESSAGES_FILE_URL, response_model=FileUrlOut)
async def get_file_url(
    message_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> FileUrlOut:
    await enforce_rate_limit(user.id, "get_file_url", RATE_LIMIT_READS_PER_MINUTE)
    msg = await db.scalar(select(Message).where(Message.id == message_id))
    if msg is None or not msg.s3_key:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="file_not_found")
    await _assert_conv_member(msg.conversation_id, user.id, db)
    url = await FileService.presigned_url(key=msg.s3_key)
    await AuditService.log(
        db,
        user_id=user.id,
        action=AuditAction.FILE_ACCESSED,
        resource_type="message",
        resource_id=message_id,
    )
    return FileUrlOut(url=url, expires_in=PRESIGNED_URL_TTL_SECONDS)


# MessageError → HTTP status for the edit/delete paths.
_EDIT_DELETE_STATUS = {
    "message_not_found": status.HTTP_404_NOT_FOUND,
    "not_message_sender": status.HTTP_403_FORBIDDEN,
}


def _raise_edit_delete(e: MessageError) -> None:
    raise HTTPException(
        _EDIT_DELETE_STATUS.get(str(e), status.HTTP_409_CONFLICT), detail=str(e)
    ) from e


async def _broadcast(msg: Message, event: WsEventServer, db: AsyncSession) -> MessageOut:
    recipients = await MessageService.member_ids(conversation_id=msg.conversation_id, db=db)
    out = MessageService.to_out(msg)
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
    """Sender deletes within the delete window → tombstone for every member."""
    await enforce_rate_limit(user.id, "delete_message")
    try:
        msg, s3_key = await MessageService.delete_message(
            message_id=message_id, user_id=user.id, db=db
        )
    except MessageError as e:
        _raise_edit_delete(e)
    out = await _broadcast(msg, WsEventServer.MESSAGE_DELETED, db)
    if s3_key:
        # Best-effort: the row is already shredded; a stray object is caught by
        # the purge job's key sweep if this fails.
        try:
            await FileService.delete_object(key=s3_key)
        except Exception:
            logging.getLogger("doqto.messages").warning("s3 delete failed for %s", s3_key)
    return out


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
