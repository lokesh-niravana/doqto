from __future__ import annotations

import base64
import re
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import and_, delete, exists, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    FORWARD_MAX_DEPTH,
    MENTION_TOKEN_PATTERN,
    MENTIONS_MAX_PER_MESSAGE,
    MESSAGE_DELETE_WINDOW_SEC,
    MESSAGE_EDIT_WINDOW_SEC,
    MESSAGE_REACTION_MAX_BYTES,
    MESSAGES_PAGE_SIZE,
    ORG_POLICY_ALLOW_FORWARD_OUTSIDE_ORG,
    ORG_POLICY_DEFAULTS,
    PIN_DURATIONS_SEC,
    PURGE_CONTENT_GRACE_SEC,
    REPLY_PREVIEW_DELETED,
    REPLY_PREVIEW_MAX_LEN,
    STARRED_PAGE_SIZE,
)
from app.core.enums import (
    AuditAction,
    ConversationAccess,
    ConversationType,
    GroupMemberState,
    GroupRole,
    MessageType,
    OrgRole,
    TranscriptStatus,
)
import emoji as emoji_lib

from app.core import crypto
from app.models import (
    Conversation,
    ConversationMember,
    ConversationPref,
    DirectConversationKey,
    Group,
    GroupMember,
    Message,
    MessageEdit,
    MessageHide,
    MessageReaction,
    MessageReceipt,
    MessageStar,
    Organization,
    OrgMember,
    PollOption,
    UserPrivacySettings,
)
from app.schemas.message import MessageOut, PollOut, ReactionOut, ReplyPreviewOut
from app.services.audit_service import AuditService

_MENTION_RE = re.compile(MENTION_TOKEN_PATTERN)


def org_policy(org: Organization | None, key: str) -> bool:
    """Effective org content policy — a missing key means the default."""
    if org is None:
        return bool(ORG_POLICY_DEFAULTS[key])
    return bool((org.policies or {}).get(key, ORG_POLICY_DEFAULTS[key]))


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
        disappear_after_sec: int | None = None,
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
            disappear_after_sec=disappear_after_sec,
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
                    MessageService._not_cleared_for(user_id),
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
                    MessageService._not_cleared_for(user_id),
                    Message.seq > ConversationMember.last_read_seq,
                )
                .group_by(Message.conversation_id)
            )
            out.update(dict(rows.all()))

        return out

    @staticmethod
    async def unread_total(*, user_id: uuid.UUID, db: AsyncSession) -> int:
        """App-icon badge number: unread messages across every chat on the
        user's list, skipping muted, archived and deleted-for-me chats, plus
        one for each chat the user marked unread by hand (batch 3)."""
        from app.services.conversation_prefs_service import ConversationPrefsService

        convs = await MessageService.list_for_user(user_id=user_id, db=db)
        prefs = await ConversationPrefsService.for_user(user_id=user_id, db=db)
        now = datetime.now(tz=timezone.utc)
        counted: list[Conversation] = []
        extra = 0
        for c in convs:
            p = prefs.get(c.id)
            if p is None:
                counted.append(c)
                continue
            if (
                p.archived
                or ConversationPrefsService.is_muted(p, now)
                or ConversationPrefsService.is_hidden(p, c)
            ):
                continue
            counted.append(c)
        counts = await MessageService.unread_counts(conversations=counted, user_id=user_id, db=db)
        for c in counted:
            p = prefs.get(c.id)
            if p is not None and p.marked_unread and counts.get(c.id, 0) == 0:
                extra += 1
        return sum(counts.values()) + extra

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
        version = await crypto.active_version(db, conv.org_id)
        msg = Message(
            conversation_id=conv.id,
            sender_id=sender_id,
            type=MessageType.SYSTEM,
            seq=await MessageService.next_seq(conversation_id=conv.id, db=db),
            content_encrypted=crypto.encrypt(content, version),
            key_version=version,
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
        from app.services.compliance_service import not_under_legal_hold

        cutoff = datetime.now(tz=timezone.utc) - timedelta(seconds=PURGE_CONTENT_GRACE_SEC)
        rows = await db.execute(
            select(Message).where(
                # Legal hold (batch 7): nothing in a held org's chats is shredded.
                not_under_legal_hold(),
                or_(
                    and_(Message.is_deleted.is_(True), Message.created_at <= cutoff),
                    and_(Message.expires_at.is_not(None), Message.expires_at <= cutoff),
                ),
                or_(
                    Message.content_encrypted.is_not(None),
                    Message.transcript_encrypted.is_not(None),
                    Message.caption_encrypted.is_not(None),
                    Message.s3_key.is_not(None),
                    Message.thumb_key.is_not(None),
                ),
            )
        )
        keys: list[str] = []
        poll_ids: list[uuid.UUID] = []
        for msg in rows.scalars().all():
            if msg.s3_key:
                keys.append(msg.s3_key)
            if msg.thumb_key:
                keys.append(msg.thumb_key)
            if msg.type == MessageType.POLL:
                poll_ids.append(msg.id)
            msg.content_encrypted = None
            msg.transcript_encrypted = None
            msg.caption_encrypted = None
            msg.waveform = None
            msg.s3_key = None
            msg.thumb_key = None
        if poll_ids:
            # Option text is PHI too; votes cascade with the options.
            await db.execute(delete(PollOption).where(PollOption.message_id.in_(poll_ids)))
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
        reply_to_id: uuid.UUID | None = None,
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

        if reply_to_id is not None:
            await MessageService._validate_reply_target(
                conversation_id=conversation_id, reply_to_id=reply_to_id, db=db
            )
        mentions = await MessageService._validate_mentions(
            conversation_id=conversation_id,
            mention_ids=MessageService.parse_mentions(content),
            db=db,
        )

        version = await crypto.active_version(db, conv.org_id)
        msg = Message(
            conversation_id=conversation_id,
            sender_id=sender_id,
            type=MessageType.TEXT,
            seq=await MessageService.next_seq(conversation_id=conversation_id, db=db),
            client_id=client_id,
            content_encrypted=crypto.encrypt(content, version),
            key_version=version,
            transcript_status=TranscriptStatus.NONE,
            expires_at=MessageService.expiry_for(conv),
            reply_to_id=reply_to_id,
            mentions=mentions or None,
        )
        conv.updated_at = datetime.now(tz=timezone.utc)
        try:
            async with db.begin_nested():
                db.add(msg)
                await db.flush()
        except IntegrityError:
            # Lost a concurrent-retry race on (conversation_id, client_id):
            # the first copy is committed by now — hand it back, as a later
            # retry would have been. Anything else is a genuine failure.
            if client_id is None:
                raise
            existing = await MessageService.find_by_client_id(
                conversation_id=conversation_id, client_id=client_id, db=db
            )
            if existing is None:
                raise
            return existing
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
        changed_since: datetime | None = None,
    ) -> list[Message]:
        stmt = select(Message).where(
            Message.conversation_id == conversation_id,
            Message.is_deleted.is_(False),
            MessageService._not_expired(),
        )
        if user_id is not None:
            stmt = stmt.where(MessageService._not_hidden_for(user_id))
            stmt = stmt.where(MessageService._not_cleared_for(user_id))
        if changed_since is not None:
            # Post-send changes (edits, deletes, reactions) the client missed
            # while offline; seq catch-up can't see them.
            stmt = stmt.where(Message.changed_at > changed_since).order_by(
                Message.changed_at.asc()
            )
        elif after_seq is not None:
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
            stmt = stmt.where(MessageService._not_cleared_for(user_id))
        rows = await db.execute(stmt)
        return {m.conversation_id: m for m in rows.scalars().all()}

    @staticmethod
    def _not_cleared_for(user_id: uuid.UUID):
        """"Clear chat" (batch 3): everything at or before the user's
        cleared_before_seq cursor is gone from their view only."""
        return ~exists(
            select(ConversationPref.conversation_id).where(
                ConversationPref.conversation_id == Message.conversation_id,
                ConversationPref.user_id == user_id,
                ConversationPref.cleared_before_seq.is_not(None),
                ConversationPref.cleared_before_seq >= Message.seq,
            )
        )

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
    def to_out(
        msg: Message,
        read: bool = False,
        delivered: bool = False,
        reactions: list[ReactionOut] | None = None,
        reply_to: ReplyPreviewOut | None = None,
        starred: bool = False,
        poll: PollOut | None = None,
        reveal_deleted: bool = False,
    ) -> MessageOut:
        # Under legal hold a deleted-for-everyone message keeps its content in
        # the row; members still see a bare tombstone. Only the audited
        # break-glass read passes reveal_deleted=True.
        hidden = msg.deleted_at is not None and not reveal_deleted
        kv = msg.key_version or 0
        content = None if hidden else crypto.decrypt_opt(msg.content_encrypted, kv)
        return MessageOut(
            id=msg.id,
            conversation_id=msg.conversation_id,
            sender_id=msg.sender_id,
            type=msg.type,
            seq=msg.seq,
            content=content,
            s3_key=None if hidden else msg.s3_key,
            file_name=None if hidden else msg.file_name,
            file_size_bytes=None if hidden else msg.file_size_bytes,
            voice_duration_sec=msg.voice_duration_sec,
            transcript=None if hidden else crypto.decrypt_opt(msg.transcript_encrypted, kv),
            transcript_status=msg.transcript_status,
            expires_at=msg.expires_at,
            created_at=msg.created_at,
            read=read,
            delivered=delivered or read,  # read implies delivered
            client_id=msg.client_id,
            edited_at=msg.edited_at,
            deleted_at=msg.deleted_at,
            reactions=reactions or [],
            changed_at=msg.changed_at,
            reply_to_id=msg.reply_to_id,
            reply_to=reply_to,
            forwarded=bool(msg.forwarded),
            forward_depth=msg.forward_depth or 0,
            mentions=list(msg.mentions or []),
            starred=starred,
            caption=None if hidden else crypto.decrypt_opt(msg.caption_encrypted, kv),
            thumb_key=None if hidden else msg.thumb_key,
            waveform=(
                base64.b64encode(msg.waveform).decode("ascii")
                if msg.waveform and not hidden
                else None
            ),
            media_width=msg.media_width,
            media_height=msg.media_height,
            poll=poll,
        )

    @staticmethod
    async def outs_for(
        msgs: list[Message],
        *,
        db: AsyncSession,
        viewer_id: uuid.UUID | None = None,
        read_ids: set[uuid.UUID] | None = None,
        delivered_ids: set[uuid.UUID] | None = None,
    ) -> list[MessageOut]:
        """MessageOut for a page: reactions, live reply previews and (for a
        viewer) their stars, each in ONE query for the whole page."""
        from app.services.media_service import MediaService

        ids = [m.id for m in msgs]
        reactions = await MessageService.reactions_for(message_ids=ids, db=db)
        previews = await MessageService.reply_previews_for(msgs=msgs, db=db)
        polls = await MediaService.polls_for(msgs=msgs, db=db)
        starred: set[uuid.UUID] = set()
        if viewer_id is not None:
            starred = await MessageService.starred_ids_for(
                message_ids=ids, user_id=viewer_id, db=db
            )
        read_ids = read_ids or set()
        delivered_ids = delivered_ids or set()
        return [
            MessageService.to_out(
                m,
                read=m.id in read_ids,
                delivered=m.id in delivered_ids,
                reactions=reactions.get(m.id),
                reply_to=previews.get(m.id),
                starred=m.id in starred,
                poll=polls.get(m.id),
            )
            for m in msgs
        ]

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
    async def rekey(msg: Message, db: AsyncSession) -> int:
        """Lazy key migration (batch 7): before any body write, move every
        encrypted field of the row to the conversation's active data key so
        the row never mixes versions. Returns the version to encrypt with."""
        conv = await db.get(Conversation, msg.conversation_id)
        version = await crypto.active_version(db, conv.org_id if conv else None)
        old = msg.key_version or 0
        if old != version:
            msg.content_encrypted = crypto.reencrypt(msg.content_encrypted, old, version)
            msg.transcript_encrypted = crypto.reencrypt(msg.transcript_encrypted, old, version)
            msg.caption_encrypted = crypto.reencrypt(msg.caption_encrypted, old, version)
            msg.key_version = version
        return version

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
        if crypto.decrypt(msg.content_encrypted, msg.key_version) == content:
            return msg
        db.add(
            MessageEdit(
                message_id=msg.id,
                content_encrypted=msg.content_encrypted,
                key_version=msg.key_version,
            )
        )
        await MessageService.rekey(msg, db)
        msg.content_encrypted = crypto.encrypt(content, msg.key_version)
        msg.edited_at = datetime.now(tz=timezone.utc)
        msg.changed_at = msg.edited_at
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
    async def can_moderate(
        *, conv: Conversation, user_id: uuid.UUID, db: AsyncSession
    ) -> bool:
        """Group admin+ (groups row) or org admin (legacy org group chat).
        Direct chats have no moderator."""
        if conv.type != ConversationType.GROUP:
            return False
        group = await db.scalar(select(Group).where(Group.conversation_id == conv.id))
        if group is not None:
            member = await db.scalar(
                select(GroupMember).where(
                    GroupMember.group_id == group.id, GroupMember.user_id == user_id
                )
            )
            return (
                member is not None
                and member.state == GroupMemberState.ACTIVE
                and GroupRole(member.role) in (GroupRole.OWNER, GroupRole.ADMIN)
            )
        if conv.org_id is None:
            return False
        role = await db.scalar(
            select(OrgMember.org_role).where(
                OrgMember.org_id == conv.org_id, OrgMember.user_id == user_id
            )
        )
        return role == OrgRole.ADMIN

    @staticmethod
    async def delete_message(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> tuple[Message, list[str], bool]:
        """Tombstone: crypto-shred body, caption, transcript, media + thumb keys,
        poll options/votes and edit history; keep the row (seq ordering). The
        sender may delete within MESSAGE_DELETE_WINDOW_SEC; a group admin may
        delete any member's message at any age (moderation). Returns (message,
        S3 keys to delete after commit, deleted_by_admin)."""
        msg = await db.scalar(select(Message).where(Message.id == message_id))
        if msg is None or msg.is_deleted:
            raise MessageError("message_not_found")
        conv = await db.get(Conversation, msg.conversation_id)
        if conv is None or not await MessageService._is_member(
            conversation_id=msg.conversation_id, user_id=user_id, db=db
        ):
            raise MessageError("message_not_found")
        by_admin = False
        if msg.sender_id != user_id:
            if not await MessageService.can_moderate(conv=conv, user_id=user_id, db=db):
                raise MessageError("not_message_sender")
            by_admin = True
        if msg.deleted_at is not None:
            raise MessageError("message_deleted")
        if msg.type == MessageType.SYSTEM:
            raise MessageError("message_not_deletable")
        if not by_admin and MessageService._age_sec(msg) > MESSAGE_DELETE_WINDOW_SEC:
            raise MessageError("delete_window_closed")
        from app.services.compliance_service import RetentionService

        # Legal hold (batch 7): the message becomes a tombstone for every
        # member (to_out masks it) but its content, media and edit history
        # stay in place until the hold is lifted.
        held = await RetentionService.is_held(conv, db)
        keys = [] if held else [k for k in (msg.s3_key, msg.thumb_key) if k]
        if not held:
            msg.content_encrypted = None
            msg.transcript_encrypted = None
            msg.caption_encrypted = None
            msg.waveform = None
            msg.s3_key = None
            msg.thumb_key = None
        msg.mentions = None
        msg.deleted_at = datetime.now(tz=timezone.utc)
        msg.changed_at = msg.deleted_at
        if msg.type == MessageType.POLL and not held:
            await db.execute(delete(PollOption).where(PollOption.message_id == msg.id))
        if not held:
            await db.execute(delete(MessageEdit).where(MessageEdit.message_id == msg.id))
        await db.execute(delete(MessageReaction).where(MessageReaction.message_id == msg.id))
        # A deleted message leaves no bookmark anywhere.
        await db.execute(delete(MessageStar).where(MessageStar.message_id == msg.id))
        if conv.pinned_message_id == msg.id:
            conv.pinned_message_id = None
            conv.pinned_until = None
            conv.pinned_by = None
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.MESSAGE_DELETED,
            resource_type="message",
            resource_id=msg.id,
            metadata=(
                {**({"by_admin": True, "sender_id": str(msg.sender_id)} if by_admin else {}),
                 **({"legal_hold": True} if held else {})}
                or None
            ),
        )
        await db.flush()
        return msg, keys, by_admin

    @staticmethod
    async def _is_member(
        *, conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> bool:
        return (
            await db.scalar(
                select(ConversationMember.user_id).where(
                    ConversationMember.conversation_id == conversation_id,
                    ConversationMember.user_id == user_id,
                )
            )
        ) is not None

    @staticmethod
    async def _visible_message(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> Message:
        """A live (not purged/expired) message in a conversation the caller
        belongs to; otherwise the same 404 as a missing id (no oracle)."""
        msg = await db.scalar(
            select(Message).where(Message.id == message_id, MessageService._not_expired())
        )
        if msg is None or msg.is_deleted:
            raise MessageError("message_not_found")
        if not await MessageService._is_member(
            conversation_id=msg.conversation_id, user_id=user_id, db=db
        ):
            raise MessageError("message_not_found")
        return msg

    # --- Reply / quote (batch 4) -------------------------------------------- #

    @staticmethod
    async def _validate_reply_target(
        *, conversation_id: uuid.UUID, reply_to_id: uuid.UUID, db: AsyncSession
    ) -> Message:
        target = await db.scalar(
            select(Message).where(Message.id == reply_to_id, MessageService._not_expired())
        )
        if (
            target is None
            or target.is_deleted
            or target.deleted_at is not None
            or target.conversation_id != conversation_id
        ):
            raise MessageError("reply_target_invalid")
        return target

    @staticmethod
    def reply_preview(target: Message | None) -> ReplyPreviewOut | None:
        """Quote block rendered from the target's CURRENT row. Expired or purged
        → None (the quote disappears with the message); tombstone → the
        deleted placeholder; media → a type label / file name, never bytes."""
        if target is None or target.is_deleted:
            return None
        if target.expires_at is not None and target.expires_at <= datetime.now(tz=timezone.utc):
            return None
        if target.deleted_at is not None:
            preview: str | None = REPLY_PREVIEW_DELETED
        elif target.type in (MessageType.TEXT, MessageType.SYSTEM) and target.content_encrypted:
            text = crypto.decrypt(target.content_encrypted, target.key_version).strip()
            if len(text) > REPLY_PREVIEW_MAX_LEN:
                text = text[: REPLY_PREVIEW_MAX_LEN - 1].rstrip() + "…"
            preview = text
        elif target.type == MessageType.POLL and target.content_encrypted:
            preview = crypto.decrypt(target.content_encrypted, target.key_version).strip()[
                :REPLY_PREVIEW_MAX_LEN
            ]
        elif target.caption_encrypted:
            # A captioned photo / video / file quotes its caption.
            text = crypto.decrypt(target.caption_encrypted, target.key_version).strip()
            if len(text) > REPLY_PREVIEW_MAX_LEN:
                text = text[: REPLY_PREVIEW_MAX_LEN - 1].rstrip() + "…"
            preview = text
        elif target.type == MessageType.IMAGE:
            preview = "Photo"
        elif target.type == MessageType.VIDEO:
            preview = "Video"
        elif target.type == MessageType.VOICE_NOTE:
            preview = "Voice note"
        elif target.type == MessageType.FILE:
            preview = target.file_name or "File"
        else:
            preview = None
        return ReplyPreviewOut(
            id=target.id, sender_id=target.sender_id, type=target.type, preview=preview
        )

    @staticmethod
    async def reply_previews_for(
        *, msgs: list[Message], db: AsyncSession
    ) -> dict[uuid.UUID, ReplyPreviewOut]:
        """message id → quote for every message on the page that replies to
        something, in one query."""
        target_ids = {m.reply_to_id for m in msgs if m.reply_to_id is not None}
        if not target_ids:
            return {}
        rows = await db.execute(select(Message).where(Message.id.in_(target_ids)))
        targets = {t.id: t for t in rows.scalars().all()}
        out: dict[uuid.UUID, ReplyPreviewOut] = {}
        for m in msgs:
            if m.reply_to_id is None:
                continue
            preview = MessageService.reply_preview(targets.get(m.reply_to_id))
            if preview is not None:
                out[m.id] = preview
        return out

    # --- Mentions (batch 4) ------------------------------------------------- #

    @staticmethod
    def parse_mentions(content: str) -> list[uuid.UUID]:
        """`@[<uuid>]` tokens, de-duplicated, in order of appearance."""
        seen: list[uuid.UUID] = []
        for raw in _MENTION_RE.findall(content or ""):
            uid = uuid.UUID(raw)
            if uid not in seen:
                seen.append(uid)
        return seen

    @staticmethod
    async def _validate_mentions(
        *, conversation_id: uuid.UUID, mention_ids: list[uuid.UUID], db: AsyncSession
    ) -> list[uuid.UUID]:
        if not mention_ids:
            return []
        if len(mention_ids) > MENTIONS_MAX_PER_MESSAGE:
            raise MessageError("too_many_mentions")
        rows = await db.execute(
            select(ConversationMember.user_id).where(
                ConversationMember.conversation_id == conversation_id,
                ConversationMember.user_id.in_(mention_ids),
            )
        )
        members = set(rows.scalars().all())
        if set(mention_ids) - members:
            raise MessageError("mention_not_member")
        return mention_ids

    # --- Forward (batch 4) -------------------------------------------------- #

    @staticmethod
    async def forward_message(
        *,
        message_id: uuid.UUID,
        user_id: uuid.UUID,
        conversation_ids: list[uuid.UUID],
        db: AsyncSession,
        copy_object,
    ) -> list[Message]:
        """Create an independent copy of `message_id` in each destination the
        caller may post to. Media is COPIED in S3 (new key per copy) so the
        copies never share an object with the source. `copy_object(src_key,
        dst_key)` is injected so the router owns the storage client."""
        src = await MessageService._visible_message(
            message_id=message_id, user_id=user_id, db=db
        )
        if src.deleted_at is not None:
            raise MessageError("message_deleted")
        if src.type in (MessageType.SYSTEM, MessageType.POLL):
            # A poll's votes belong to its conversation; copies would split them.
            raise MessageError("message_not_forwardable")
        if (src.forward_depth or 0) >= FORWARD_MAX_DEPTH:
            raise MessageError("forward_limit")
        src_conv = await db.get(Conversation, src.conversation_id)
        src_org = (
            await db.get(Organization, src_conv.org_id)
            if src_conv is not None and src_conv.org_id is not None
            else None
        )
        outside_org_blocked = src_org is not None and not org_policy(
            src_org, ORG_POLICY_ALLOW_FORWARD_OUTSIDE_ORG
        )

        from app.core import permissions
        from app.services.group_service import GroupService
        from app.services.relationship_service import RelationshipService

        # Resolve + authorise EVERY destination before writing anything, so a
        # forward is all-or-nothing.
        dests: list[Conversation] = []
        for dest_id in dict.fromkeys(conversation_ids):
            dest = await db.get(Conversation, dest_id)
            if dest is None or not await MessageService._is_member(
                conversation_id=dest_id, user_id=user_id, db=db
            ):
                raise MessageError("conversation_not_found")
            if dest.access != ConversationAccess.OPEN:
                raise MessageError("conversation_not_open")
            if outside_org_blocked and dest.org_id != src_org.id:
                raise MessageError("forward_blocked_by_org")
            if dest.type == ConversationType.GROUP:
                if not await GroupService.check_post_allowed(
                    conversation_id=dest.id, user_id=user_id, db=db
                ):
                    raise MessageError("post_restricted")
            else:
                other_id = await db.scalar(
                    select(ConversationMember.user_id).where(
                        ConversationMember.conversation_id == dest.id,
                        ConversationMember.user_id != user_id,
                    )
                )
                if other_id is not None:
                    ctx = await RelationshipService.load_context(user_id, other_id, db)
                    decision = permissions.can_message(ctx)
                    if decision.mode == "denied":
                        raise MessageError(
                            decision.reason
                            if decision.reason
                            in ("not_connected", "group_dm_request", "group_dm_disabled")
                            else "not_reachable"
                        )
            dests.append(dest)

        from app.services.file_service import FileService

        created: list[Message] = []
        now = datetime.now(tz=timezone.utc)
        for dest in dests:
            version = await crypto.active_version(db, dest.org_id)
            copy = Message(
                conversation_id=dest.id,
                sender_id=user_id,
                type=src.type,
                seq=await MessageService.next_seq(conversation_id=dest.id, db=db),
                key_version=version,
                content_encrypted=crypto.reencrypt(
                    src.content_encrypted, src.key_version, version
                ),
                file_name=src.file_name,
                file_size_bytes=src.file_size_bytes,
                voice_duration_sec=src.voice_duration_sec,
                transcript_encrypted=crypto.reencrypt(
                    src.transcript_encrypted, src.key_version, version
                ),
                transcript_status=src.transcript_status,
                expires_at=MessageService.expiry_for(dest),
                forwarded=True,
                forward_depth=(src.forward_depth or 0) + 1,
                # Batch 5: the caption travels with the media; the waveform
                # and pixel size are shape data, copied verbatim.
                caption_encrypted=crypto.reencrypt(
                    src.caption_encrypted, src.key_version, version
                ),
                waveform=src.waveform,
                media_width=src.media_width,
                media_height=src.media_height,
            )
            db.add(copy)
            dest.updated_at = now
            await db.flush()
            if src.thumb_key:
                tkey = FileService.thumb_key(
                    org_id=dest.org_id, conversation_id=dest.id, message_id=copy.id
                )
                await copy_object(src.thumb_key, tkey)
                copy.thumb_key = tkey
            if src.s3_key:
                filename = src.file_name or "file"
                if src.type == MessageType.VOICE_NOTE:
                    key = (
                        FileService.key_for_voice_note(org_id=dest.org_id, message_id=copy.id)
                        if dest.org_id is not None
                        else FileService.key_for_network_voice_note(
                            conversation_id=dest.id, message_id=copy.id
                        )
                    )
                else:
                    key = (
                        FileService.key_for_file(
                            org_id=dest.org_id, message_id=copy.id, filename=filename
                        )
                        if dest.org_id is not None
                        else FileService.key_for_network_file(
                            conversation_id=dest.id, message_id=copy.id, filename=filename
                        )
                    )
                await copy_object(src.s3_key, key)
                copy.s3_key = key
            await AuditService.log(
                db,
                user_id=user_id,
                action=AuditAction.MESSAGE_SENT,
                resource_type="message",
                resource_id=copy.id,
                metadata={"forwarded_from": str(src.id)},
            )
            created.append(copy)
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.MESSAGE_FORWARDED,
            resource_type="message",
            resource_id=src.id,
            metadata={
                "source_id": str(src.id),
                "destinations": [str(d.id) for d in dests],
                "copies": [str(c.id) for c in created],
            },
        )
        await db.flush()
        return created

    # --- Stars (batch 4, private bookmarks) --------------------------------- #

    @staticmethod
    async def set_star(
        *, message_id: uuid.UUID, user_id: uuid.UUID, starred: bool, db: AsyncSession
    ) -> tuple[Message, bool]:
        """Star or unstar; idempotent. Returns (message, changed)."""
        msg = await MessageService._visible_message(
            message_id=message_id, user_id=user_id, db=db
        )
        if msg.deleted_at is not None:
            raise MessageError("message_deleted")
        if msg.type == MessageType.SYSTEM:
            raise MessageError("message_not_starrable")
        if starred:
            result = await db.execute(
                pg_insert(MessageStar)
                .values(message_id=msg.id, user_id=user_id)
                .on_conflict_do_nothing()
            )
        else:
            result = await db.execute(
                delete(MessageStar).where(
                    MessageStar.message_id == msg.id, MessageStar.user_id == user_id
                )
            )
        await db.flush()
        return msg, bool(result.rowcount)

    @staticmethod
    async def starred_ids_for(
        *, message_ids: list[uuid.UUID], user_id: uuid.UUID, db: AsyncSession
    ) -> set[uuid.UUID]:
        if not message_ids:
            return set()
        rows = await db.execute(
            select(MessageStar.message_id).where(
                MessageStar.message_id.in_(message_ids), MessageStar.user_id == user_id
            )
        )
        return set(rows.scalars().all())

    @staticmethod
    async def list_starred(
        *,
        user_id: uuid.UUID,
        before: datetime | None,
        limit: int,
        db: AsyncSession,
    ) -> list[tuple[MessageStar, Message, Conversation]]:
        """The caller's stars across every conversation, newest star first,
        skipping anything deleted/expired/hidden. Returns limit+1 rows so the
        caller can page."""
        stmt = (
            select(MessageStar, Message, Conversation)
            .join(Message, Message.id == MessageStar.message_id)
            .join(Conversation, Conversation.id == Message.conversation_id)
            .where(
                MessageStar.user_id == user_id,
                Message.is_deleted.is_(False),
                Message.deleted_at.is_(None),
                MessageService._not_expired(),
                MessageService._not_hidden_for(user_id),
            )
        )
        if before is not None:
            stmt = stmt.where(MessageStar.created_at < before)
        stmt = stmt.order_by(MessageStar.created_at.desc()).limit(
            min(limit, STARRED_PAGE_SIZE) + 1
        )
        return [tuple(r) for r in (await db.execute(stmt)).all()]

    @staticmethod
    async def purge_orphan_stars(db: AsyncSession) -> int:
        """Stars never extend retention: drop every star whose message is
        gone (deleted for everyone, expired, or purged)."""
        gone = select(Message.id).where(
            or_(
                Message.is_deleted.is_(True),
                Message.deleted_at.is_not(None),
                and_(Message.expires_at.is_not(None), Message.expires_at <= func.now()),
            )
        )
        result = await db.execute(delete(MessageStar).where(MessageStar.message_id.in_(gone)))
        return result.rowcount or 0

    # --- Pin (batch 4) ------------------------------------------------------ #

    @staticmethod
    async def _assert_can_pin(
        *, conv: Conversation, user_id: uuid.UUID, db: AsyncSession
    ) -> None:
        """Direct: either member. Group: admin+ (legacy org group chats with
        no groups row: any member, like the disappearing timer)."""
        if conv.type != ConversationType.GROUP:
            return
        group = await db.scalar(select(Group).where(Group.conversation_id == conv.id))
        if group is None:
            return
        if not await MessageService.can_moderate(conv=conv, user_id=user_id, db=db):
            raise MessageError("not_authorized")

    @staticmethod
    async def pin_message(
        *,
        conv: Conversation,
        message_id: uuid.UUID,
        user_id: uuid.UUID,
        duration_sec: int,
        db: AsyncSession,
    ) -> Message:
        if duration_sec not in PIN_DURATIONS_SEC:
            raise MessageError("invalid_pin_duration")
        await MessageService._assert_can_pin(conv=conv, user_id=user_id, db=db)
        msg = await MessageService._visible_message(
            message_id=message_id, user_id=user_id, db=db
        )
        if msg.conversation_id != conv.id:
            raise MessageError("message_not_found")
        if msg.deleted_at is not None:
            raise MessageError("message_deleted")
        if msg.type == MessageType.SYSTEM:
            raise MessageError("message_not_pinnable")
        now = datetime.now(tz=timezone.utc)
        conv.pinned_message_id = msg.id
        conv.pinned_until = now + timedelta(seconds=duration_sec)
        conv.pinned_by = user_id
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.MESSAGE_PINNED,
            resource_type="conversation",
            resource_id=conv.id,
            metadata={"message_id": str(msg.id), "duration_sec": duration_sec},
        )
        await db.flush()
        return msg

    @staticmethod
    async def unpin_message(
        *, conv: Conversation, user_id: uuid.UUID, db: AsyncSession
    ) -> uuid.UUID | None:
        """Clear the pin. Returns the message id that was pinned, or None when
        nothing was (idempotent no-op)."""
        await MessageService._assert_can_pin(conv=conv, user_id=user_id, db=db)
        previous = conv.pinned_message_id
        if previous is None:
            return None
        conv.pinned_message_id = None
        conv.pinned_until = None
        conv.pinned_by = None
        await AuditService.log(
            db,
            user_id=user_id,
            action=AuditAction.MESSAGE_UNPINNED,
            resource_type="conversation",
            resource_id=conv.id,
            metadata={"message_id": str(previous)},
        )
        await db.flush()
        return previous

    @staticmethod
    def effective_pin(conv: Conversation) -> tuple[uuid.UUID | None, datetime | None]:
        """(pinned_message_id, pinned_until) as the client should see it: a pin
        past its expiry reads as no pin even before the job clears it."""
        if conv.pinned_message_id is None or conv.pinned_until is None:
            return None, None
        if conv.pinned_until <= datetime.now(tz=timezone.utc):
            return None, None
        return conv.pinned_message_id, conv.pinned_until

    @staticmethod
    async def expire_pins(db: AsyncSession) -> list[tuple[uuid.UUID, uuid.UUID]]:
        """Auto-unpin: clear every pin past pinned_until. Returns the
        (conversation_id, message_id) pairs cleared so the caller can fan out
        `message_unpinned`."""
        rows = await db.execute(
            select(Conversation).where(
                Conversation.pinned_message_id.is_not(None),
                Conversation.pinned_until.is_not(None),
                Conversation.pinned_until <= func.now(),
            )
        )
        cleared: list[tuple[uuid.UUID, uuid.UUID]] = []
        for conv in rows.scalars().all():
            cleared.append((conv.id, conv.pinned_message_id))
            conv.pinned_message_id = None
            conv.pinned_until = None
            conv.pinned_by = None
        return cleared

    # --- Reactions (one emoji per member per message) ------------------------ #

    @staticmethod
    def valid_reaction_emoji(value: str) -> bool:
        """Exactly one emoji grapheme cluster (ZWJ, skin tone, flag ok)."""
        return len(value.encode("utf-8")) <= MESSAGE_REACTION_MAX_BYTES and bool(
            emoji_lib.is_emoji(value)
        )

    @staticmethod
    async def reactions_for(
        *, message_ids: list[uuid.UUID], db: AsyncSession
    ) -> dict[uuid.UUID, list[ReactionOut]]:
        """One query for a whole page. Per message: grouped by emoji, sorted
        by count desc then earliest reaction; user_ids oldest first."""
        if not message_ids:
            return {}
        rows = await db.execute(
            select(MessageReaction)
            .where(MessageReaction.message_id.in_(message_ids))
            .order_by(MessageReaction.created_at.asc(), MessageReaction.user_id.asc())
        )
        grouped: dict[uuid.UUID, dict[str, list[uuid.UUID]]] = {}
        for r in rows.scalars().all():
            grouped.setdefault(r.message_id, {}).setdefault(r.emoji, []).append(r.user_id)
        out: dict[uuid.UUID, list[ReactionOut]] = {}
        for mid, by_emoji in grouped.items():
            # dict keeps first-seen order = earliest reaction; stable sort by count.
            items = [
                ReactionOut(emoji=e, count=len(uids), user_ids=uids)
                for e, uids in by_emoji.items()
            ]
            items.sort(key=lambda x: -x.count)
            out[mid] = items
        return out

    @staticmethod
    async def _reactable_message(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> Message:
        # Expired ("disappeared") rows are invisible to every read path, so they
        # take no reactions either, even before the purge job flags them.
        msg = await db.scalar(
            select(Message).where(Message.id == message_id, MessageService._not_expired())
        )
        if msg is None or msg.is_deleted:
            raise MessageError("message_not_found")
        member = await db.scalar(
            select(ConversationMember.user_id).where(
                ConversationMember.conversation_id == msg.conversation_id,
                ConversationMember.user_id == user_id,
            )
        )
        if member is None:
            # Same answer as a missing id: no oracle for message ids in
            # conversations the caller isn't in.
            raise MessageError("message_not_found")
        if msg.deleted_at is not None:
            raise MessageError("message_deleted")
        if msg.type == MessageType.SYSTEM:
            raise MessageError("message_not_reactable")
        # Direct chats: a reaction is a message to the other person, so the
        # send gate applies — a block or removed connection freezes reactions
        # too (a block must never be observable, and must never ping).
        conv = await db.get(Conversation, msg.conversation_id)
        if conv is not None and conv.type == ConversationType.DIRECT:
            other_id = await db.scalar(
                select(ConversationMember.user_id).where(
                    ConversationMember.conversation_id == conv.id,
                    ConversationMember.user_id != user_id,
                )
            )
            if other_id is not None:
                from app.core import permissions
                from app.services.relationship_service import RelationshipService

                ctx = await RelationshipService.load_context(user_id, other_id, db)
                decision = permissions.can_message(ctx)
                if decision.mode == "denied":
                    raise MessageError(
                        decision.reason
                        if decision.reason
                        in ("not_connected", "group_dm_request", "group_dm_disabled")
                        else "not_reachable"
                    )
        return msg

    @staticmethod
    async def set_reaction(
        *, message_id: uuid.UUID, user_id: uuid.UUID, emoji: str, db: AsyncSession
    ) -> tuple[Message, bool]:
        """Add or replace the caller's reaction. Returns (message, changed);
        the same emoji again is a no-op (changed=False, nothing written)."""
        if not MessageService.valid_reaction_emoji(emoji):
            raise MessageError("invalid_emoji")
        msg = await MessageService._reactable_message(
            message_id=message_id, user_id=user_id, db=db
        )
        current = await db.scalar(
            select(MessageReaction.emoji).where(
                MessageReaction.message_id == msg.id, MessageReaction.user_id == user_id
            )
        )
        if current == emoji:
            return msg, False
        now = datetime.now(tz=timezone.utc)
        stmt = pg_insert(MessageReaction).values(
            message_id=msg.id, user_id=user_id, emoji=emoji, created_at=now
        )
        await db.execute(
            stmt.on_conflict_do_update(
                index_elements=[MessageReaction.message_id, MessageReaction.user_id],
                set_={"emoji": emoji, "created_at": now},
            )
        )
        msg.changed_at = now
        await db.flush()
        return msg, True

    @staticmethod
    async def remove_reaction(
        *, message_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> tuple[Message, bool]:
        """Remove the caller's reaction. No reaction → no-op (changed=False)."""
        msg = await MessageService._reactable_message(
            message_id=message_id, user_id=user_id, db=db
        )
        result = await db.execute(
            delete(MessageReaction).where(
                MessageReaction.message_id == msg.id, MessageReaction.user_id == user_id
            )
        )
        if not result.rowcount:
            return msg, False
        msg.changed_at = datetime.now(tz=timezone.utc)
        await db.flush()
        return msg, True

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
    async def read_receipts_enabled(*, conv: Conversation, db: AsyncSession) -> bool:
        """Direct chats only: read receipts are OFF for the pair when EITHER
        member turned them off (batch 2). Receipts are still stored (audit),
        just never emitted or exposed. Groups always show read-by."""
        if conv.type == ConversationType.GROUP:
            return True
        member_ids = select(ConversationMember.user_id).where(
            ConversationMember.conversation_id == conv.id
        )
        off = await db.scalar(
            select(func.count())
            .select_from(UserPrivacySettings)
            .where(
                UserPrivacySettings.user_id.in_(member_ids),
                UserPrivacySettings.read_receipts.is_(False),
            )
        )
        return not off

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
