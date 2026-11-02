from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import and_, delete, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    MESSAGE_DELETE_WINDOW_SEC,
    MESSAGE_EDIT_WINDOW_SEC,
    MESSAGES_PAGE_SIZE,
    PURGE_CONTENT_GRACE_SEC,
)
from app.core.enums import (
    AuditAction,
    ConversationAccess,
    ConversationType,
    MessageType,
    TranscriptStatus,
)
from app.core.security import decrypt_message, encrypt_message
from app.models import (
    Conversation,
    ConversationMember,
    DirectConversationKey,
    Message,
    MessageEdit,
    MessageHide,
    MessageReceipt,
    User,
)
from app.schemas.message import MessageOut
from app.services.audit_service import AuditService


class MessageError(Exception):
    pass


class MessageService:
    @staticmethod
    async def create_conversation(
        *,
        org_id: uuid.UUID | None,
        creator_id: uuid.UUID,
        conv_type: ConversationType,
        name: str | None,
        member_ids: list[uuid.UUID],
        db: AsyncSession,
        access: ConversationAccess = ConversationAccess.OPEN,
        initiator_id: uuid.UUID | None = None,
    ) -> Conversation:
        if conv_type == ConversationType.GROUP and not name:
            raise MessageError("group_name_required")
        if conv_type == ConversationType.DIRECT and len(member_ids) != 1:
            raise MessageError("direct_requires_one_member")

        full_member_ids = list({creator_id, *member_ids})
        if conv_type == ConversationType.DIRECT and len(full_member_ids) != 2:
            raise MessageError("direct_requires_two_distinct")

        # Direct dedup (A2): the direct_conversation_keys unique pair is the
        # source of truth — one direct conversation per user pair, platform-wide.
        user_lo: uuid.UUID | None = None
        user_hi: uuid.UUID | None = None
        if conv_type == ConversationType.DIRECT:
            user_lo, user_hi = sorted(full_member_ids)
            existing = await MessageService._direct_by_pair(
                user_lo=user_lo, user_hi=user_hi, db=db
            )
            if existing is not None:
                return existing

        # M3/A2: every NEW direct conversation is a NETWORK conversation
        # (org_id=NULL). The direct_conversation_keys pair is the source of
        # truth for one-DM-per-pair; org ownership is irrelevant for direct
        # threads and would wrongly partition cross-org DMs. Groups keep org_id.
        conv = Conversation(
            org_id=None if conv_type == ConversationType.DIRECT else org_id,
            type=conv_type,
            name=name,
            created_by=creator_id,
            access=access,
            initiator_id=initiator_id,
        )
        db.add(conv)
        await db.flush()
        if conv_type == ConversationType.DIRECT:
            db.add(
                DirectConversationKey(
                    conversation_id=conv.id, user_lo=user_lo, user_hi=user_hi
                )
            )
            try:
                await db.flush()
            except IntegrityError:
                # Lost a concurrent-create race: the unique (user_lo, user_hi)
                # violation means the pair's conversation exists — re-select it.
                await db.rollback()
                existing = await MessageService._direct_by_pair(
                    user_lo=user_lo, user_hi=user_hi, db=db
                )
                if existing is None:
                    raise MessageError("direct_conversation_conflict")
                return existing
        for uid in full_member_ids:
            db.add(ConversationMember(conversation_id=conv.id, user_id=uid))
        await AuditService.log(
            db,
            user_id=creator_id,
            action=AuditAction.CONVERSATION_CREATED,
            resource_type="conversation",
            resource_id=conv.id,
        )
        return conv

    @staticmethod
    async def _direct_by_pair(
        *, user_lo: uuid.UUID, user_hi: uuid.UUID, db: AsyncSession
    ) -> Conversation | None:
        """The pair's direct conversation via its dedup key, if any."""
        return await db.scalar(
            select(Conversation)
            .join(
                DirectConversationKey,
                DirectConversationKey.conversation_id == Conversation.id,
            )
            .where(
                DirectConversationKey.user_lo == user_lo,
                DirectConversationKey.user_hi == user_hi,
            )
        )

    @staticmethod
    async def list_for_user(*, user_id: uuid.UUID, db: AsyncSession) -> list[Conversation]:
        """Every conversation the user is a member of."""
        stmt = (
            select(Conversation)
            .join(ConversationMember, ConversationMember.conversation_id == Conversation.id)
            .where(ConversationMember.user_id == user_id)
        )
        rows = await db.execute(stmt.order_by(Conversation.updated_at.desc()))
        return list(rows.scalars().all())

    @staticmethod
    async def conversation_members(
        *, conversation_id: uuid.UUID, db: AsyncSession
    ) -> list[ConversationMember]:
        rows = await db.execute(
            select(ConversationMember).where(ConversationMember.conversation_id == conversation_id)
        )
        return list(rows.scalars().all())

    @staticmethod
    async def members_by_conversation(
        *, conversation_ids: list[uuid.UUID], db: AsyncSession
    ) -> dict[uuid.UUID, list[uuid.UUID]]:
        """Member ids for many conversations in ONE query (chat-list path)."""
        if not conversation_ids:
            return {}
        rows = await db.execute(
            select(ConversationMember.conversation_id, ConversationMember.user_id).where(
                ConversationMember.conversation_id.in_(conversation_ids)
            )
        )
        out: dict[uuid.UUID, list[uuid.UUID]] = {cid: [] for cid in conversation_ids}
        for cid, uid in rows.all():
            out[cid].append(uid)
        return out

    @staticmethod
    async def unread_counts(
        *, conversations: list[Conversation], user_id: uuid.UUID, db: AsyncSession
    ) -> dict[uuid.UUID, int]:
        """unread_count for many conversations, branched by type (A3 hybrid).

        DIRECT conversations count messages without a read MessageReceipt;
        GROUP conversations count messages with seq beyond the member's
        last_read_seq cursor — no per-message receipts."""
        if not conversations:
            return {}
        direct_ids = [c.id for c in conversations if c.type != ConversationType.GROUP]
        group_ids = [c.id for c in conversations if c.type == ConversationType.GROUP]
        out: dict[uuid.UUID, int] = {}

        if direct_ids:
            read_subq = select(MessageReceipt.message_id).where(
                MessageReceipt.user_id == user_id,
                MessageReceipt.read_at.is_not(None),
            )
            rows = await db.execute(
                select(Message.conversation_id, func.count())
                .where(
                    Message.conversation_id.in_(direct_ids),
                    Message.sender_id != user_id,
                    Message.is_deleted.is_(False),
                    Message.type != MessageType.SYSTEM,
                    MessageService._not_expired(),
                    Message.id.not_in(read_subq),
                )
                .group_by(Message.conversation_id)
            )
            out.update(dict(rows.all()))

        if group_ids:
            rows = await db.execute(
                select(Message.conversation_id, func.count())
                .join(
                    ConversationMember,
                    and_(
                        ConversationMember.conversation_id == Message.conversation_id,
                        ConversationMember.user_id == user_id,
                    ),
                )
                .where(
                    Message.conversation_id.in_(group_ids),
                    Message.sender_id != user_id,
                    Message.is_deleted.is_(False),
                    Message.type != MessageType.SYSTEM,
                    MessageService._not_expired(),
                    Message.seq > ConversationMember.last_read_seq,
                )
                .group_by(Message.conversation_id)
            )
            out.update(dict(rows.all()))

        return out

    @staticmethod
    async def member_ids(*, conversation_id: uuid.UUID, db: AsyncSession) -> list[uuid.UUID]:
        """Recipient list for conversation-scoped WS fanout."""
        rows = await db.execute(
            select(ConversationMember.user_id).where(
                ConversationMember.conversation_id == conversation_id
            )
        )
        return list(rows.scalars().all())

    @staticmethod
    def expiry_for(conv: Conversation) -> datetime | None:
        """When a message sent NOW in this conversation should disappear (None = never)."""
        if conv.disappear_after_sec:
            return datetime.now(tz=timezone.utc) + timedelta(seconds=conv.disappear_after_sec)
        return None

    @staticmethod
    def _not_expired():
        """Filter clause: message has no expiry or hasn't reached it yet."""
        return or_(Message.expires_at.is_(None), Message.expires_at > func.now())

    @staticmethod
    async def next_seq(*, conversation_id: uuid.UUID, db: AsyncSession) -> int:
        """Atomically claim the next per-conversation sequence number.

        The UPDATE row-locks the conversation, serializing concurrent senders;
        holes from rolled-back transactions are acceptable (clients treat seq
        as ordered, not dense)."""
        seq = await db.scalar(
            update(Conversation)
            .where(Conversation.id == conversation_id)
            .values(last_seq=Conversation.last_seq + 1)
            .returning(Conversation.last_seq)
        )
        if seq is None:
            raise MessageError("conversation_not_found")
        return seq

    @staticmethod
    async def find_by_client_id(
        *, conversation_id: uuid.UUID, client_id: str, db: AsyncSession
    ) -> Message | None:
        """Idempotency lookup: the original row for a retried client send, if any."""
        return await db.scalar(
            select(Message).where(
                Message.conversation_id == conversation_id,
                Message.client_id == client_id,
            )
        )

    @staticmethod
    async def send_system(
        *,
        conv: Conversation,
        sender_id: uuid.UUID,
        content: str,
        db: AsyncSession,
    ) -> Message:
        """Persist an in-chat system banner (e.g. disappearing-messages change). Never expires."""
        msg = Message(
            conversation_id=conv.id,
            sender_id=sender_id,
            type=MessageType.SYSTEM,
            seq=await MessageService.next_seq(conversation_id=conv.id, db=db),
            content_encrypted=encrypt_message(content),
            transcript_status=TranscriptStatus.NONE,
            expires_at=None,
        )
        db.add(msg)
        conv.updated_at = datetime.now(tz=timezone.utc)
        await db.flush()
        return msg

    @staticmethod
    async def purge_expired(db: AsyncSession) -> int:
        """Soft-delete every message past its expiry. Idempotent; safe to run concurrently."""
        result = await db.execute(
            update(Message)
            .where(
                Message.is_deleted.is_(False),
                Message.expires_at.is_not(None),
                Message.expires_at <= func.now(),
            )
            .values(is_deleted=True)
        )
        return result.rowcount or 0

    @staticmethod
    async def purge_content(db: AsyncSession) -> list[str]:
        """Crypto-shred content of messages soft-deleted/expired past the grace
        period: null the encrypted blobs and s3_key, keep the row (seq ordering,
        receipts). Returns the S3 keys so the caller can delete the objects.
        Reads already exclude these rows (is_deleted/expiry filters), and
        to_out handles NULL content, so nulling is invisible to clients."""
        cutoff = datetime.now(tz=timezone.utc) - timedelta(seconds=PURGE_CONTENT_GRACE_SEC)
        rows = await db.execute(
            select(Message).where(
                or_(
                    and_(Message.is_deleted.is_(True), Message.created_at <= cutoff),
                    and_(Message.expires_at.is_not(None), Message.expires_at <= cutoff),
                ),
                or_(
                    Message.content_encrypted.is_not(None),
                    Message.transcript_encrypted.is_not(None),
                    Message.s3_key.is_not(None),
                ),
            )
        )
        keys: list[str] = []
        for msg in rows.scalars().all():
            if msg.s3_key:
                keys.append(msg.s3_key)
            msg.content_encrypted = None
            msg.transcript_encrypted = None
            msg.s3_key = None
        return keys

    @staticmethod
    async def send_text(
        *,
        conversation_id: uuid.UUID,
        sender_id: uuid.UUID,
        content: str,
        db: AsyncSession,
        client_id: str | None = None,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ) -> Message:
        conv = await db.scalar(select(Conversation).where(Conversation.id == conversation_id))
        if conv is None:
            raise MessageError("conversation_not_found")

        # Idempotency: a retried send (same outbox client_id) returns the
        # original row instead of duplicating. The partial unique index
        # (conversation_id, client_id) backstops concurrent retries.
        if client_id is not None:
            existing = await MessageService.find_by_client_id(
                conversation_id=conversation_id, client_id=client_id, db=db
            )
            if existing is not None:
                return existing

        msg = Message(
            conversation_id=conversation_id,
            sender_id=sender_id,
            type=MessageType.TEXT,
            seq=await MessageService.next_seq(conversation_id=conversation_id, db=db),
            client_id=client_id,
            content_encrypted=encrypt_message(content),
            transcript_status=TranscriptStatus.NONE,
            expires_at=MessageService.expiry_for(conv),
        )
        db.add(msg)
        conv.updated_at = datetime.now(tz=timezone.utc)
        await db.flush()
        await AuditService.log(
            db,
            user_id=sender_id,
            action=AuditAction.MESSAGE_SENT,
            resource_type="message",
            resource_id=msg.id,
            ip_address=ip_address,
            user_agent=user_agent,
        )
        return msg

    @staticmethod
    async def list_messages(
        *,
        conversation_id: uuid.UUID,
        before: datetime | None,
        limit: int,
        db: AsyncSession,
        after_seq: int | None = None,
        user_id: uuid.UUID | None = None,
    ) -> list[Message]:
        stmt = select(Message).where(
            Message.conversation_id == conversation_id,
            Message.is_deleted.is_(False),
            MessageService._not_expired(),
        )
        if user_id is not None:
            stmt = stmt.where(MessageService._not_hidden_for(user_id))
        if after_seq is not None:
            # Forward catch-up sync: everything the client hasn't seen, oldest first.
            stmt = stmt.where(Message.seq > after_seq).order_by(Message.seq.asc())
        else:
            if before is not None:
                stmt = stmt.where(Message.created_at < before)
            stmt = stmt.order_by(Message.created_at.desc())
        stmt = stmt.limit(min(limit, MESSAGES_PAGE_SIZE))
        rows = await db.execute(stmt)
        return list(rows.scalars().all())

    @staticmethod
    async def latest_per_conversation(
        *, conversation_ids: list[uuid.UUID], db: AsyncSession, user_id: uuid.UUID | None = None
    ) -> dict[uuid.UUID, Message]:
        """Return the most recent non-deleted message for each given conversation, keyed by conv id.

        Uses Postgres DISTINCT ON to fetch all latest messages in a single round-trip.
        """
        if not conversation_ids:
            return {}
        stmt = (
            select(Message)
            .where(Message.conversation_id.in_(conversation_ids))
            .where(Message.is_deleted.is_(False))
            .where(MessageService._not_expired())
            .order_by(Message.conversation_id, Message.created_at.desc())
            .distinct(Message.conversation_id)
        )
        if user_id is not None:
            stmt = stmt.where(MessageService._not_hidden_for(user_id))
        rows = await db.execute(stmt)
        return {m.conversation_id: m for m in rows.scalars().all()}

    @staticmethod
    def _not_hidden_for(user_id: uuid.UUID):
        return ~select(MessageHide.message_id).where(
            MessageHide.message_id == Message.id, MessageHide.user_id == user_id
        ).exists()

    @staticmethod
    async def hide_messages(
        *, message_ids: list[uuid.UUID], user_id: uuid.UUID, db: AsyncSession
    ) -> int:
        """'Delete for me': any message in a conversation the user belongs to,
        own or theirs, live or tombstone, any age. Idempotent."""
        rows = await db.execute(
            select(Message.id)
            .join(ConversationMember, ConversationMember.conversation_id == Message.conversation_id)
            .where(
                Message.id.in_(message_ids),
                ConversationMember.user_id == user_id,
                ~select(MessageHide.message_id)
                .where(MessageHide.message_id == Message.id, MessageHide.user_id == user_id)
                .exists(),
            )
        )
        ids = list(rows.scalars().all())
        for mid in ids:
            db.add(MessageHide(message_id=mid, user_id=user_id))
        await db.commit()
        return len(ids)

    @staticmethod
    def to_out(msg: Message, read: bool = False, delivered: bool = False) -> MessageOut:
        content = decrypt_message(msg.content_encrypted) if msg.content_encrypted else None
        return MessageOut(
            id=msg.id,
            conversation_id=msg.conversation_id,
            sender_id=msg.sender_id,
            type=msg.type,
            seq=msg.seq,
            content=content,
            s3_key=msg.s3_key,
            file_name=msg.file_name,
            file_size_bytes=msg.file_size_bytes,
            voice_duration_sec=msg.voice_duration_sec,
            transcript=(
                decrypt_message(msg.transcript_encrypted) if msg.transcript_encrypted else None
            ),
            transcript_status=msg.transcript_status,
            expires_at=msg.expires_at,
            created_at=msg.created_at,
            read=read,
            delivered=delivered or read,  # read implies delivered
            client_id=msg.client_id,
            edited_at=msg.edited_at,
            deleted_at=msg.deleted_at,
        )

    # --- Edit / delete (sender-only, time-boxed) ---------------------------- #

    @staticmethod
    async def _own_live_message(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> Message:
        msg = await db.scalar(select(Message).where(Message.id == message_id))
        if msg is None or msg.is_deleted:
            raise MessageError("message_not_found")
        if msg.sender_id != user_id:
            raise MessageError("not_message_sender")
        if msg.deleted_at is not None:
            raise MessageError("message_deleted")
        return msg

    @staticmethod
    def _age_sec(msg: Message) -> float:
        return (datetime.now(tz=timezone.utc) - msg.created_at).total_seconds()

    @staticmethod
    async def edit_message(
        *, message_id: uuid.UUID, user_id: uuid.UUID, content: str, db: AsyncSession
    ) -> Message:
        """Replace a text body within MESSAGE_EDIT_WINDOW_SEC; the previous
        version goes to message_edits so every member can see the history.
        Identical content is a no-op (no history row, no edited_at)."""
        msg = await MessageService._own_live_message(
            message_id=message_id, user_id=user_id, db=db
        )
        if msg.type != MessageType.TEXT or msg.content_encrypted is None:
            raise MessageError("message_not_editable")
        if MessageService._age_sec(msg) > MESSAGE_EDIT_WINDOW_SEC:
            raise MessageError("edit_window_closed")
        if decrypt_message(msg.content_encrypted) == content:
            return msg
        db.add(MessageEdit(message_id=msg.id, content_encrypted=msg.content_encrypted))
        msg.content_encrypted = encrypt_message(content)
        msg.edited_at = datetime.now(tz=timezone.utc)
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.MESSAGE_EDITED,
            resource_type="message",
            resource_id=msg.id,
        )
        await db.flush()
        return msg

    @staticmethod
    async def delete_message(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> tuple[Message, str | None]:
        """Tombstone within MESSAGE_DELETE_WINDOW_SEC: crypto-shred body,
        transcript, media key and edit history; keep the row (seq ordering).
        Returns the S3 key the caller must delete after commit, if any."""
        msg = await MessageService._own_live_message(
            message_id=message_id, user_id=user_id, db=db
        )
        if msg.type == MessageType.SYSTEM:
            raise MessageError("message_not_deletable")
        if MessageService._age_sec(msg) > MESSAGE_DELETE_WINDOW_SEC:
            raise MessageError("delete_window_closed")
        s3_key = msg.s3_key
        msg.content_encrypted = None
        msg.transcript_encrypted = None
        msg.s3_key = None
        msg.deleted_at = datetime.now(tz=timezone.utc)
        await db.execute(delete(MessageEdit).where(MessageEdit.message_id == msg.id))
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.MESSAGE_DELETED,
            resource_type="message",
            resource_id=msg.id,
        )
        await db.flush()
        return msg, s3_key

    @staticmethod
    async def list_edits(*, message_id: uuid.UUID, db: AsyncSession) -> list[MessageEdit]:
        """Superseded versions, oldest first. Empty after a delete (shredded)."""
        rows = await db.execute(
            select(MessageEdit)
            .where(MessageEdit.message_id == message_id)
            .order_by(MessageEdit.replaced_at.asc())
        )
        return list(rows.scalars().all())

    @staticmethod
    async def mark_conversation_delivered(
        *, conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> bool:
        """Stamp delivered for every message from other senders this user
        hasn't acknowledged yet. Returns True if anything changed.

        A3 hybrid: GROUP conversations advance the O(1) last_delivered_seq
        cursor; DIRECT conversations keep per-message MessageReceipt rows."""
        now = datetime.now(tz=timezone.utc)
        conv = await db.scalar(select(Conversation).where(Conversation.id == conversation_id))
        if conv is not None and conv.type == ConversationType.GROUP:
            member = await db.scalar(
                select(ConversationMember).where(
                    ConversationMember.conversation_id == conversation_id,
                    ConversationMember.user_id == user_id,
                )
            )
            if member is None or member.last_delivered_seq >= conv.last_seq:
                return False
            member.last_delivered_seq = conv.last_seq
            return True
        msg_ids = (
            await db.execute(
                select(Message.id).where(
                    Message.conversation_id == conversation_id,
                    Message.sender_id != user_id,
                    Message.is_deleted.is_(False),
                )
            )
        ).scalars().all()
        if not msg_ids:
            return False
        # One idempotent upsert (same reason as mark_conversation_read: the
        # client stamps delivered on open and per live message, so calls
        # overlap). Rows already delivered are left alone and not returned.
        receipts = MessageReceipt.__table__.c
        stmt = (
            pg_insert(MessageReceipt)
            .values([{"message_id": mid, "user_id": user_id, "delivered_at": now} for mid in msg_ids])
            .on_conflict_do_update(
                index_elements=[receipts.message_id, receipts.user_id],
                set_={"delivered_at": now},
                where=receipts.delivered_at.is_(None),
            )
            .returning(receipts.message_id)
        )
        touched = (await db.execute(stmt)).scalars().all()
        return bool(touched)

    @staticmethod
    async def delivered_message_ids(
        *, message_ids: list[uuid.UUID], db: AsyncSession
    ) -> set[uuid.UUID]:
        """Subset of the given message ids delivered to a recipient."""
        if not message_ids:
            return set()
        rows = await db.execute(
            select(MessageReceipt.message_id).where(
                MessageReceipt.message_id.in_(message_ids),
                MessageReceipt.delivered_at.is_not(None),
            )
        )
        return set(rows.scalars().all())

    @staticmethod
    async def read_message_ids(
        *, message_ids: list[uuid.UUID], db: AsyncSession
    ) -> set[uuid.UUID]:
        """Subset of the given message ids that have been read by a recipient."""
        if not message_ids:
            return set()
        rows = await db.execute(
            select(MessageReceipt.message_id).where(
                MessageReceipt.message_id.in_(message_ids),
                MessageReceipt.read_at.is_not(None),
            )
        )
        return set(rows.scalars().all())

    @staticmethod
    async def group_receipt_ids(
        *, msgs: list[Message], conv: Conversation, db: AsyncSession
    ) -> tuple[set[uuid.UUID], set[uuid.UUID]]:
        """Read/delivered tick sets for a GROUP conversation's messages, derived
        from member seq cursors (A3) instead of MessageReceipt rows.

        A message (sent by S) is 'read' once EVERY other member's last_read_seq
        has reached its seq; 'delivered' once every other member's
        last_delivered_seq has. 'read' implies 'delivered' via to_out."""
        if not msgs:
            return set(), set()
        rows = await db.execute(
            select(
                ConversationMember.user_id,
                ConversationMember.last_read_seq,
                ConversationMember.last_delivered_seq,
            ).where(ConversationMember.conversation_id == conv.id)
        )
        members = rows.all()
        read_ids: set[uuid.UUID] = set()
        delivered_ids: set[uuid.UUID] = set()
        for m in msgs:
            others = [row for row in members if row[0] != m.sender_id]
            if not others:
                continue
            if all(row[1] >= m.seq for row in others):
                read_ids.add(m.id)
            if all(row[2] >= m.seq for row in others):
                delivered_ids.add(m.id)
        return read_ids, delivered_ids

    @staticmethod
    async def unread_count(
        *, conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> int:
        """Messages from other senders this user hasn't read yet."""
        read_subq = select(MessageReceipt.message_id).where(
            MessageReceipt.user_id == user_id,
            MessageReceipt.read_at.is_not(None),
        )
        count = await db.scalar(
            select(func.count())
            .select_from(Message)
            .where(
                Message.conversation_id == conversation_id,
                Message.sender_id != user_id,
                Message.is_deleted.is_(False),
                Message.type != MessageType.SYSTEM,
                MessageService._not_expired(),
                Message.id.not_in(read_subq),
            )
        )
        return count or 0

    @staticmethod
    async def mark_conversation_read(
        *, conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> None:
        """Mark every message from other senders in this conversation as read by user_id.

        A3 hybrid: GROUP conversations use the O(1) seq cursor
        (conversation_members.last_read_seq) — one UPDATE, no per-message
        MessageReceipt rows. DIRECT conversations keep per-message receipts
        (2-person threads are cheap; zero client tick churn)."""
        now = datetime.now(tz=timezone.utc)
        conv = await db.scalar(select(Conversation).where(Conversation.id == conversation_id))
        if conv is not None and conv.type == ConversationType.GROUP:
            # Read implies delivered → advance both cursors to the head seq.
            await db.execute(
                update(ConversationMember)
                .where(
                    ConversationMember.conversation_id == conversation_id,
                    ConversationMember.user_id == user_id,
                )
                .values(
                    last_read_seq=conv.last_seq,
                    last_delivered_seq=func.greatest(
                        ConversationMember.last_delivered_seq, conv.last_seq
                    ),
                    last_read_at=now,
                )
            )
            return
        unread = await db.execute(
            select(Message.id).where(
                Message.conversation_id == conversation_id,
                Message.sender_id != user_id,
                Message.is_deleted.is_(False),
            )
        )
        message_ids = [message_id for (message_id,) in unread.all()]
        if not message_ids:
            return
        # One idempotent upsert. The thread screen marks read on open and
        # again as each live message lands, so two of these overlap routinely;
        # a select-then-insert raced itself into a duplicate-key 500.
        stmt = pg_insert(MessageReceipt).values(
            [
                {"message_id": mid, "user_id": user_id, "delivered_at": now, "read_at": now}
                for mid in message_ids
            ]
        )
        receipts = MessageReceipt.__table__.c
        await db.execute(
            stmt.on_conflict_do_update(
                index_elements=[receipts.message_id, receipts.user_id],
                set_={
                    "delivered_at": func.coalesce(receipts.delivered_at, now),
                    "read_at": func.coalesce(receipts.read_at, now),
                },
            )
        )

    @staticmethod
    async def mark_read(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> None:
        existing = await db.scalar(
            select(MessageReceipt).where(
                MessageReceipt.message_id == message_id, MessageReceipt.user_id == user_id
            )
        )
        now = datetime.now(tz=timezone.utc)
        if existing is None:
            db.add(MessageReceipt(message_id=message_id, user_id=user_id, delivered_at=now, read_at=now))
        else:
            existing.read_at = now
            if not existing.delivered_at:
                existing.delivered_at = now
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.MESSAGE_READ,
            resource_type="message",
            resource_id=message_id,
        )
