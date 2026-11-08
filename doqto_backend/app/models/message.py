from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import BigInteger, Boolean, DateTime, ForeignKey, Integer, LargeBinary, String, Text, func
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.enums import MessageType, ScheduledMessageStatus, TranscriptStatus
from app.db.postgres import Base
from app.db.tables import Tables


class Message(Base):
    __tablename__ = Tables.MESSAGES

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    conversation_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.CONVERSATIONS}.id"),
        nullable=False,
        index=True,
    )
    sender_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False, index=True
    )
    type: Mapped[MessageType] = mapped_column(String(20), nullable=False)
    # Per-conversation sequence number (1, 2, 3, …) — unique index
    # uq_messages_conv_seq. Clients use it for gapless catch-up sync.
    seq: Mapped[int] = mapped_column(BigInteger, nullable=False)
    # Client-generated idempotency key; unique per conversation (partial index).
    client_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    content_encrypted: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    s3_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    file_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    file_size_bytes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    voice_duration_sec: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Voice-note transcripts are PHI — encrypted at rest like message bodies.
    transcript_encrypted: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    transcript_status: Mapped[TranscriptStatus] = mapped_column(
        String(20), default=TranscriptStatus.NONE, nullable=False
    )
    expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True, index=True
    )
    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    # Sender edited the body (history in message_edits). Distinct from
    # deleted_at: a user-deleted message stays listed as a tombstone, while
    # is_deleted (expiry/purge) hides the row entirely.
    edited_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Bumped on every post-send change other members can see (edit, delete,
    # reaction). Catch-up uses it: after_seq only finds NEW messages.
    changed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class MessageEdit(Base):
    """A superseded version of a text message — PHI, encrypted like bodies.
    Every conversation member may read the history (transparent edits)."""

    __tablename__ = Tables.MESSAGE_EDITS

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    message_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.MESSAGES}.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    content_encrypted: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    replaced_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class MessageHide(Base):
    """'Delete for me': the message stays for everyone else, this user never
    lists it again. No PHI here — just the pair."""

    __tablename__ = Tables.MESSAGE_HIDES

    message_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.MESSAGES}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    hidden_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class MessageReaction(Base):
    """One emoji per (message, user). Not PHI (an emoji alone), stored plain."""

    __tablename__ = Tables.MESSAGE_REACTIONS

    message_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.MESSAGES}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    # Indexed: a member leaving/removed from a group has every reaction of
    # theirs in that conversation purged (migration 0029).
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
        index=True,
    )
    emoji: Mapped[str] = mapped_column(String(32), nullable=False)
    # Re-stamped when the emoji changes: when the CURRENT reaction was made.
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class ScheduledMessage(Base):
    """A text message queued for future delivery. Content is PHI — encrypted
    at rest exactly like sent messages. `scheduled_at` is the UTC instant;
    `timezone` (IANA name) is kept only so clients can display the schedule
    in the zone the sender picked."""

    __tablename__ = Tables.SCHEDULED_MESSAGES

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    conversation_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.CONVERSATIONS}.id"),
        nullable=False,
        index=True,
    )
    sender_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False, index=True
    )
    content_encrypted: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    timezone: Mapped[str] = mapped_column(String(64), nullable=False)
    scheduled_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, index=True
    )
    status: Mapped[ScheduledMessageStatus] = mapped_column(
        String(20), default=ScheduledMessageStatus.PENDING, nullable=False
    )
    error: Mapped[str | None] = mapped_column(String(100), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class MessageReceipt(Base):
    __tablename__ = Tables.MESSAGE_RECEIPTS

    message_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.MESSAGES}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), primary_key=True
    )
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
