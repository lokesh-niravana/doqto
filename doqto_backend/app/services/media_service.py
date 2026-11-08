"""Media (batch 5): presigned multipart uploads, polls, the per-chat media
gallery and the save/share export gate.

Storage rules (same as the inline upload routes): every object key embeds the
message id; network (cross-org) conversations are namespaced by conversation
id; captions / poll text are PHI and encrypted like bodies; thumbnails are
EXIF-stripped JPEGs of their own.
"""

from __future__ import annotations

import math
import re
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    FILE_MAX_BYTES,
    LINK_SCAN_BATCH,
    LINK_SCAN_MAX_MESSAGES,
    MEDIA_PAGE_SIZE,
    ORG_POLICY_ALLOW_MEDIA_EXPORT,
    THUMB_CONTENT_TYPE,
    THUMB_MAX_BYTES,
    UPLOAD_INTENT_TTL_SEC,
    UPLOAD_MULTIPART_THRESHOLD_BYTES,
    UPLOAD_PART_SIZE_BYTES,
    UPLOAD_URL_TTL_SEC,
    URL_PATTERN,
    VIDEO_MAX_BYTES,
    VIDEO_MAX_DURATION_SEC,
)
from app.core.enums import AuditAction, MessageType, TranscriptStatus
from app.core.security import decrypt_message, encrypt_message
from app.models import (
    Conversation,
    Message,
    Organization,
    OrgMember,
    PollOption,
    PollVote,
    UploadIntent,
)
from app.schemas.message import (
    PollCreateIn,
    PollOptionOut,
    PollOut,
    UploadCompleteIn,
    UploadIntentIn,
    UploadIntentOut,
    UploadPartUrlOut,
)
from app.services.audit_service import AuditService
from app.services.file_service import FileService
from app.services.image_service import strip_image_metadata
from app.services.message_service import MessageError, MessageService, org_policy

_URL_RE = re.compile(URL_PATTERN)
_MEDIA_TYPES = {MessageType.IMAGE, MessageType.VIDEO, MessageType.FILE}


def _now() -> datetime:
    return datetime.now(tz=timezone.utc)


class MediaService:
    # ------------------------------------------------------------------ #
    # Helpers
    # ------------------------------------------------------------------ #

    @staticmethod
    def type_for(content_type: str | None) -> MessageType:
        ct = (content_type or "").lower()
        if ct.startswith("image/"):
            return MessageType.IMAGE
        if ct.startswith("video/"):
            return MessageType.VIDEO
        return MessageType.FILE

    @staticmethod
    def size_limit(msg_type: MessageType) -> int:
        return VIDEO_MAX_BYTES if msg_type == MessageType.VIDEO else FILE_MAX_BYTES

    @staticmethod
    def encrypt_caption(caption: str | None) -> bytes | None:
        text = (caption or "").strip()
        return encrypt_message(text) if text else None

    @staticmethod
    def extract_urls(text: str) -> list[str]:
        seen: dict[str, None] = {}
        for m in _URL_RE.finditer(text):
            url = m.group(0).rstrip(".,;:!?")
            seen.setdefault(url, None)
        return list(seen)

    # ------------------------------------------------------------------ #
    # Export gate (Save to Photos / share sheet)
    # ------------------------------------------------------------------ #

    @staticmethod
    async def _user_orgs(user_id: uuid.UUID, db: AsyncSession) -> list[Organization]:
        rows = await db.execute(
            select(Organization)
            .join(OrgMember, OrgMember.org_id == Organization.id)
            .where(OrgMember.user_id == user_id)
        )
        return list(rows.scalars().all())

    @staticmethod
    async def export_allowed_map(
        *, user_id: uuid.UUID, convs: list[Conversation], db: AsyncSession
    ) -> dict[uuid.UUID, bool]:
        """Per conversation: may this user export media from it. Org chat →
        that org's policy (default off). Network chat → the strictest of the
        user's own orgs; a user with no org may export."""
        if not convs:
            return {}
        org_ids = {c.org_id for c in convs if c.org_id is not None}
        orgs: dict[uuid.UUID, Organization] = {}
        if org_ids:
            rows = await db.execute(select(Organization).where(Organization.id.in_(org_ids)))
            orgs = {o.id: o for o in rows.scalars().all()}
        own = await MediaService._user_orgs(user_id, db)
        network_allowed = all(org_policy(o, ORG_POLICY_ALLOW_MEDIA_EXPORT) for o in own)
        out: dict[uuid.UUID, bool] = {}
        for c in convs:
            if c.org_id is None:
                out[c.id] = network_allowed
            else:
                out[c.id] = org_policy(orgs.get(c.org_id), ORG_POLICY_ALLOW_MEDIA_EXPORT)
        return out

    @staticmethod
    async def export_allowed(*, user_id: uuid.UUID, conv: Conversation, db: AsyncSession) -> bool:
        return (await MediaService.export_allowed_map(user_id=user_id, convs=[conv], db=db))[
            conv.id
        ]

    @staticmethod
    async def audit_export(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> Message:
        """The client calls this before Save / Share. Outsider → 404 (same as
        a missing message); member in a chat whose policy forbids it → 403."""
        msg = await MessageService._visible_message(message_id=message_id, user_id=user_id, db=db)
        if msg.deleted_at is not None or not msg.s3_key or msg.type not in _MEDIA_TYPES | {
            MessageType.VOICE_NOTE
        }:
            raise MessageError("file_not_found")
        conv = await db.get(Conversation, msg.conversation_id)
        if not await MediaService.export_allowed(user_id=user_id, conv=conv, db=db):
            raise MessageError("media_export_blocked")
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.FILE_EXPORTED,
            resource_type="message",
            resource_id=msg.id,
            metadata={"type": str(msg.type), "conversation_id": str(msg.conversation_id)},
        )
        return msg

    # ------------------------------------------------------------------ #
    # Presigned (multipart) uploads
    # ------------------------------------------------------------------ #

    @staticmethod
    async def create_intent(
        *, conv: Conversation, user_id: uuid.UUID, body: UploadIntentIn, db: AsyncSession
    ) -> UploadIntentOut:
        msg_type = MediaService.type_for(body.content_type)
        if body.size_bytes > MediaService.size_limit(msg_type):
            raise MessageError("file_too_large")
        if body.with_thumb and msg_type != MessageType.VIDEO:
            raise MessageError("thumb_not_allowed")

        # Idempotency: the outbox retried an upload that already landed.
        if body.client_id is not None:
            existing = await MessageService.find_by_client_id(
                conversation_id=conv.id, client_id=body.client_id, db=db
            )
            if existing is not None:
                out = (await MessageService.outs_for([existing], db=db))[0]
                return UploadIntentOut(
                    intent_id=uuid.uuid4(),
                    type=existing.type,
                    key=existing.s3_key or "",
                    part_size=UPLOAD_PART_SIZE_BYTES,
                    expires_in=0,
                    message=out,
                )

        message_id = uuid.uuid4()
        filename = body.file_name.replace("/", "_") or "file"
        key = FileService.media_key(
            org_id=conv.org_id, conversation_id=conv.id, message_id=message_id, filename=filename
        )
        thumb_key = (
            FileService.thumb_key(org_id=conv.org_id, conversation_id=conv.id, message_id=message_id)
            if body.with_thumb
            else None
        )
        intent = UploadIntent(
            conversation_id=conv.id,
            user_id=user_id,
            message_id=message_id,
            type=msg_type,
            s3_key=key,
            thumb_key=thumb_key,
            content_type=body.content_type,
            file_name=filename,
            size_bytes=body.size_bytes,
            client_id=body.client_id,
            expires_at=_now() + timedelta(seconds=UPLOAD_INTENT_TTL_SEC),
        )
        out = UploadIntentOut(
            intent_id=uuid.uuid4(),  # replaced after flush
            type=msg_type,
            key=key,
            part_size=UPLOAD_PART_SIZE_BYTES,
            expires_in=UPLOAD_URL_TTL_SEC,
        )
        if body.size_bytes > UPLOAD_MULTIPART_THRESHOLD_BYTES:
            upload_id = await FileService.create_multipart_upload(
                key=key, content_type=body.content_type
            )
            part_count = math.ceil(body.size_bytes / UPLOAD_PART_SIZE_BYTES)
            intent.upload_id = upload_id
            intent.part_count = part_count
            out.upload_id = upload_id
            out.part_urls = [
                UploadPartUrlOut(
                    part_number=n,
                    url=await FileService.presigned_upload_part(
                        key=key, upload_id=upload_id, part_number=n
                    ),
                )
                for n in range(1, part_count + 1)
            ]
        else:
            intent.part_count = 1
            out.put_url = await FileService.presigned_put(key=key, content_type=body.content_type)
        if thumb_key:
            out.thumb_put_url = await FileService.presigned_put(
                key=thumb_key, content_type=THUMB_CONTENT_TYPE
            )
        db.add(intent)
        await db.flush()
        out.intent_id = intent.id
        return out

    @staticmethod
    async def _clean_image_object(key: str, content_type: str) -> int:
        """Defence in depth: strip metadata from an image the client PUT
        straight to S3. Returns the stored size."""
        data = await FileService.get_object(key=key)
        clean = strip_image_metadata(data, content_type)
        if clean != data:
            await FileService.upload_bytes(key=key, data=clean, content_type=content_type)
        return len(clean)

    @staticmethod
    async def complete_intent(
        *, conv: Conversation, user_id: uuid.UUID, body: UploadCompleteIn, db: AsyncSession
    ) -> tuple[Message, bool]:
        """Returns (message, created). created=False is a replay of an intent
        that already completed — nothing new to fan out."""
        intent = await db.scalar(
            select(UploadIntent).where(
                UploadIntent.id == body.intent_id,
                UploadIntent.conversation_id == conv.id,
                UploadIntent.user_id == user_id,
            )
        )
        if intent is None:
            raise MessageError("upload_intent_not_found")
        if intent.completed_at is not None:
            # Retry after a lost response: hand back the message it made.
            existing = await db.get(Message, intent.message_id)
            if existing is not None:
                return existing, False
            raise MessageError("upload_intent_completed")
        if intent.expires_at <= _now():
            raise MessageError("upload_intent_expired")
        if intent.type == MessageType.VIDEO and body.duration_sec is not None:
            if body.duration_sec > VIDEO_MAX_DURATION_SEC:
                raise MessageError("video_too_long")

        if intent.upload_id:
            numbers = sorted(p.part_number for p in body.parts)
            if numbers != list(range(1, intent.part_count + 1)):
                raise MessageError("upload_parts_invalid")
            await FileService.complete_multipart_upload(
                key=intent.s3_key,
                upload_id=intent.upload_id,
                parts=[(p.part_number, p.etag) for p in body.parts],
            )
        head = await FileService.head_object(key=intent.s3_key)
        if head is None:
            raise MessageError("upload_missing")
        size = int(head["size"])
        if size > MediaService.size_limit(intent.type):
            await FileService.delete_object(key=intent.s3_key)
            raise MessageError("file_too_large")
        if intent.type == MessageType.IMAGE:
            size = await MediaService._clean_image_object(intent.s3_key, intent.content_type)

        thumb_key: str | None = None
        if intent.thumb_key and body.has_thumb:
            thead = await FileService.head_object(key=intent.thumb_key)
            if thead is not None:
                if int(thead["size"]) > THUMB_MAX_BYTES:
                    await FileService.delete_object(key=intent.thumb_key)
                else:
                    await MediaService._clean_image_object(intent.thumb_key, THUMB_CONTENT_TYPE)
                    thumb_key = intent.thumb_key

        msg = Message(
            id=intent.message_id,
            conversation_id=conv.id,
            sender_id=user_id,
            type=intent.type,
            seq=await MessageService.next_seq(conversation_id=conv.id, db=db),
            client_id=intent.client_id,
            s3_key=intent.s3_key,
            thumb_key=thumb_key,
            file_name=intent.file_name,
            file_size_bytes=size,
            voice_duration_sec=body.duration_sec if intent.type == MessageType.VIDEO else None,
            caption_encrypted=MediaService.encrypt_caption(body.caption),
            media_width=body.width,
            media_height=body.height,
            transcript_status=TranscriptStatus.NONE,
            expires_at=MessageService.expiry_for(conv),
        )
        db.add(msg)
        intent.completed_at = _now()
        conv.updated_at = intent.completed_at
        await db.flush()
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.FILE_UPLOADED,
            resource_type="message",
            resource_id=msg.id,
            metadata={"multipart": intent.upload_id is not None, "size": size},
        )
        return msg, True

    @staticmethod
    async def purge_intents(db: AsyncSession) -> list[tuple[str, str | None, str | None]]:
        """Drop intents past their expiry that never completed. Returns
        (key, upload_id, thumb_key) so the caller can abort / delete in S3
        after commit. Completed intents older than the TTL are dropped too."""
        rows = await db.execute(select(UploadIntent).where(UploadIntent.expires_at <= _now()))
        stale: list[tuple[str, str | None, str | None]] = []
        for intent in rows.scalars().all():
            if intent.completed_at is None:
                stale.append((intent.s3_key, intent.upload_id, intent.thumb_key))
            await db.delete(intent)
        await db.flush()
        return stale

    # ------------------------------------------------------------------ #
    # Polls
    # ------------------------------------------------------------------ #

    @staticmethod
    async def create_poll(
        *,
        conv: Conversation,
        sender_id: uuid.UUID,
        poll: PollCreateIn,
        db: AsyncSession,
        client_id: str | None = None,
        reply_to_id: uuid.UUID | None = None,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ) -> Message:
        if client_id is not None:
            existing = await MessageService.find_by_client_id(
                conversation_id=conv.id, client_id=client_id, db=db
            )
            if existing is not None:
                return existing
        if reply_to_id is not None:
            await MessageService._validate_reply_target(
                conversation_id=conv.id, reply_to_id=reply_to_id, db=db
            )
        msg = Message(
            conversation_id=conv.id,
            sender_id=sender_id,
            type=MessageType.POLL,
            seq=await MessageService.next_seq(conversation_id=conv.id, db=db),
            client_id=client_id,
            content_encrypted=encrypt_message(poll.question),
            poll_multiple=poll.multiple,
            transcript_status=TranscriptStatus.NONE,
            expires_at=MessageService.expiry_for(conv),
            reply_to_id=reply_to_id,
        )
        db.add(msg)
        conv.updated_at = _now()
        await db.flush()
        for i, text in enumerate(poll.options):
            db.add(PollOption(message_id=msg.id, position=i, text_encrypted=encrypt_message(text)))
        await db.flush()
        await AuditService.log(
            db,
            user_id=sender_id,
            action=AuditAction.MESSAGE_SENT,
            resource_type="message",
            resource_id=msg.id,
            ip_address=ip_address,
            user_agent=user_agent,
            metadata={"poll": True, "options": len(poll.options)},
        )
        return msg

    @staticmethod
    async def polls_for(
        *, msgs: list[Message], db: AsyncSession
    ) -> dict[uuid.UUID, PollOut]:
        """Tallies + voter ids for every poll on a page — two queries."""
        polls = [m for m in msgs if m.type == MessageType.POLL and m.deleted_at is None]
        if not polls:
            return {}
        ids = [m.id for m in polls]
        options = (
            await db.execute(
                select(PollOption)
                .where(PollOption.message_id.in_(ids))
                .order_by(PollOption.position.asc())
            )
        ).scalars().all()
        votes = (
            await db.execute(
                select(PollVote)
                .where(PollVote.message_id.in_(ids))
                .order_by(PollVote.created_at.asc(), PollVote.user_id.asc())
            )
        ).scalars().all()
        by_option: dict[uuid.UUID, list[uuid.UUID]] = {}
        voters: dict[uuid.UUID, set[uuid.UUID]] = {}
        for v in votes:
            by_option.setdefault(v.option_id, []).append(v.user_id)
            voters.setdefault(v.message_id, set()).add(v.user_id)
        by_msg: dict[uuid.UUID, list[PollOptionOut]] = {}
        for o in options:
            uids = by_option.get(o.id, [])
            by_msg.setdefault(o.message_id, []).append(
                PollOptionOut(
                    id=o.id,
                    position=o.position,
                    text=decrypt_message(o.text_encrypted),
                    vote_count=len(uids),
                    voter_ids=uids,
                )
            )
        out: dict[uuid.UUID, PollOut] = {}
        for m in polls:
            out[m.id] = PollOut(
                question=decrypt_message(m.content_encrypted) if m.content_encrypted else "",
                multiple=bool(m.poll_multiple),
                options=by_msg.get(m.id, []),
                voter_count=len(voters.get(m.id, set())),
            )
        return out

    @staticmethod
    async def _votable_poll(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> Message:
        msg = await MessageService._visible_message(message_id=message_id, user_id=user_id, db=db)
        if msg.type != MessageType.POLL:
            raise MessageError("not_a_poll")
        if msg.deleted_at is not None:
            raise MessageError("message_deleted")
        return msg

    @staticmethod
    async def set_votes(
        *, message_id: uuid.UUID, user_id: uuid.UUID, option_ids: list[uuid.UUID], db: AsyncSession
    ) -> tuple[Message, bool]:
        """Replace the caller's selection. Single-choice polls take exactly one
        option. Same selection again = no change (idempotent)."""
        msg = await MediaService._votable_poll(message_id=message_id, user_id=user_id, db=db)
        wanted = list(dict.fromkeys(option_ids))
        valid = set(
            (
                await db.execute(select(PollOption.id).where(PollOption.message_id == msg.id))
            ).scalars().all()
        )
        if not set(wanted) <= valid:
            raise MessageError("poll_option_invalid")
        if not msg.poll_multiple and len(wanted) > 1:
            raise MessageError("poll_single_choice")
        current = set(
            (
                await db.execute(
                    select(PollVote.option_id).where(
                        PollVote.message_id == msg.id, PollVote.user_id == user_id
                    )
                )
            ).scalars().all()
        )
        if current == set(wanted):
            return msg, False
        await db.execute(
            delete(PollVote).where(PollVote.message_id == msg.id, PollVote.user_id == user_id)
        )
        for oid in wanted:
            db.add(PollVote(option_id=oid, user_id=user_id, message_id=msg.id))
        msg.changed_at = _now()
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.POLL_VOTED,
            resource_type="message",
            resource_id=msg.id,
            metadata={"options": len(wanted)},
        )
        await db.flush()
        return msg, True

    @staticmethod
    async def clear_votes(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> tuple[Message, bool]:
        msg = await MediaService._votable_poll(message_id=message_id, user_id=user_id, db=db)
        result = await db.execute(
            delete(PollVote).where(PollVote.message_id == msg.id, PollVote.user_id == user_id)
        )
        if not (result.rowcount or 0):
            return msg, False
        msg.changed_at = _now()
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.POLL_VOTED,
            resource_type="message",
            resource_id=msg.id,
            metadata={"options": 0},
        )
        await db.flush()
        return msg, True

    @staticmethod
    async def purge_votes_for_member(
        *, conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> list[uuid.UUID]:
        """A member who left a group takes their votes with them. Returns the
        touched poll message ids (changed_at stamped) for a `poll_updated`
        fan-out after commit."""
        touched = list(
            (
                await db.execute(
                    select(PollVote.message_id)
                    .join(Message, Message.id == PollVote.message_id)
                    .where(PollVote.user_id == user_id, Message.conversation_id == conversation_id)
                    .distinct()
                )
            ).scalars().all()
        )
        if not touched:
            return []
        await db.execute(
            delete(PollVote).where(PollVote.user_id == user_id, PollVote.message_id.in_(touched))
        )
        now = _now()
        for msg in (await db.execute(select(Message).where(Message.id.in_(touched)))).scalars():
            msg.changed_at = now
        await db.flush()
        return touched

    @staticmethod
    async def shred_poll(*, message_id: uuid.UUID, db: AsyncSession) -> None:
        """Delete / purge: option text is PHI, so the rows go (votes cascade)."""
        await db.execute(delete(PollOption).where(PollOption.message_id == message_id))

    # ------------------------------------------------------------------ #
    # Media gallery
    # ------------------------------------------------------------------ #

    @staticmethod
    def _gallery_base(conversation_id: uuid.UUID, user_id: uuid.UUID):
        return select(Message).where(
            Message.conversation_id == conversation_id,
            Message.is_deleted.is_(False),
            Message.deleted_at.is_(None),
            MessageService._not_expired(),
            MessageService._not_hidden_for(user_id),
            MessageService._not_cleared_for(user_id),
        )

    @staticmethod
    async def list_media(
        *,
        conversation_id: uuid.UUID,
        user_id: uuid.UUID,
        media_type: str,
        before_seq: int | None,
        limit: int,
        db: AsyncSession,
    ) -> tuple[list[tuple[Message, list[str]]], str | None]:
        """Newest first, cursor = seq of the last row. `link` scans text
        messages (decrypted) in batches and returns the ones with URLs; the
        page may come back short with a cursor when the scan cap is hit."""
        limit = max(1, min(limit, MEDIA_PAGE_SIZE))
        if media_type == "link":
            return await MediaService._list_links(
                conversation_id=conversation_id,
                user_id=user_id,
                before_seq=before_seq,
                limit=limit,
                db=db,
            )
        try:
            msg_type = MessageType(media_type)
        except ValueError as e:
            raise MessageError("invalid_media_type") from e
        if msg_type not in _MEDIA_TYPES:
            raise MessageError("invalid_media_type")
        stmt = MediaService._gallery_base(conversation_id, user_id).where(
            Message.type == msg_type, Message.s3_key.is_not(None)
        )
        if before_seq is not None:
            stmt = stmt.where(Message.seq < before_seq)
        rows = list(
            (await db.execute(stmt.order_by(Message.seq.desc()).limit(limit + 1))).scalars().all()
        )
        next_cursor = None
        if len(rows) > limit:
            rows = rows[:limit]
            next_cursor = str(rows[-1].seq)
        return [(m, []) for m in rows], next_cursor

    @staticmethod
    async def _list_links(
        *,
        conversation_id: uuid.UUID,
        user_id: uuid.UUID,
        before_seq: int | None,
        limit: int,
        db: AsyncSession,
    ) -> tuple[list[tuple[Message, list[str]]], str | None]:
        items: list[tuple[Message, list[str]]] = []
        cursor = before_seq
        scanned = 0
        while len(items) < limit and scanned < LINK_SCAN_MAX_MESSAGES:
            stmt = MediaService._gallery_base(conversation_id, user_id).where(
                Message.type == MessageType.TEXT, Message.content_encrypted.is_not(None)
            )
            if cursor is not None:
                stmt = stmt.where(Message.seq < cursor)
            batch = list(
                (await db.execute(stmt.order_by(Message.seq.desc()).limit(LINK_SCAN_BATCH)))
                .scalars()
                .all()
            )
            if not batch:
                return items, None
            for m in batch:
                scanned += 1
                cursor = m.seq
                try:
                    urls = MediaService.extract_urls(decrypt_message(m.content_encrypted))
                except Exception:  # noqa: BLE001 — undecryptable row, skip it
                    continue
                if urls:
                    items.append((m, urls))
                    if len(items) >= limit:
                        break
            if len(batch) < LINK_SCAN_BATCH and len(items) < limit:
                return items, None
        # More rows may remain below the cursor.
        remaining = await db.scalar(
            select(func.count())
            .select_from(Message)
            .where(
                Message.conversation_id == conversation_id,
                Message.type == MessageType.TEXT,
                Message.seq < (cursor or 0),
                Message.is_deleted.is_(False),
                Message.deleted_at.is_(None),
            )
        )
        return items, (str(cursor) if remaining else None)
