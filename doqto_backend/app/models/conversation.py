from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
    false,
    func,
)
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.enums import ConversationAccess, ConversationType
from app.db.postgres import Base
from app.db.tables import Tables


class Conversation(Base):
    __tablename__ = Tables.CONVERSATIONS

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    # NULL = network conversation (cross-org); non-NULL = org conversation.
    org_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.ORGANIZATIONS}.id"),
        nullable=True,
        index=True,
    )
    type: Mapped[ConversationType] = mapped_column(String(10), nullable=False)
    # Networking tier: open | pending_request | declined (M4 request flow).
    access: Mapped[ConversationAccess] = mapped_column(
        String(20),
        default=ConversationAccess.OPEN,
        server_default=ConversationAccess.OPEN.value,
        nullable=False,
    )
    # Who initiated a request-tier conversation (NULL for legacy/open).
    initiator_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=True
    )
    name: Mapped[str | None] = mapped_column(String(100), nullable=True)
    created_by: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=True
    )
    disappear_after_sec: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Highest message seq handed out — bumped atomically by MessageService.next_seq().
    last_seq: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0", nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    @property
    def is_network(self) -> bool:
        """Network conversation (no owning org)."""
        return self.org_id is None


class ConversationMember(Base):
    __tablename__ = Tables.CONVERSATION_MEMBERS
    __table_args__ = (UniqueConstraint("conversation_id", "user_id"),)

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    conversation_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.CONVERSATIONS}.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False, index=True
    )
    joined_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    last_read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Seq-based receipts for group-scale unread/read-by (A3 hybrid; wired in M3+).
    last_read_seq: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0", nullable=False
    )
    last_delivered_seq: Mapped[int] = mapped_column(
        BigInteger, default=0, server_default="0", nullable=False
    )


class DirectConversationKey(Base):
    """Exactly one direct conversation per user pair, platform-wide.

    (user_lo, user_hi) is the sorted pair; the UNIQUE constraint makes
    concurrent direct-conversation creation race-proof (A2)."""

    __tablename__ = Tables.DIRECT_CONVERSATION_KEYS
    __table_args__ = (
        UniqueConstraint("user_lo", "user_hi", name="uq_direct_conversation_keys_pair"),
        CheckConstraint("user_lo < user_hi", name="ck_direct_conversation_keys_lo_lt_hi"),
    )

    conversation_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.CONVERSATIONS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    user_lo: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    user_hi: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)


class ConversationPref(Base):
    """One member's private view of a conversation (batch 3): pin, archive,
    mute, mark-unread, clear / delete-for-me cursors and cosmetic choices.
    Row absent = defaults. Never visible to the other members."""

    __tablename__ = Tables.CONVERSATION_PREFS

    conversation_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.CONVERSATIONS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
        index=True,
    )
    pinned_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    archived: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default=false(), nullable=False
    )
    # NULL = not muted; MUTE_ALWAYS_UNTIL (far future) = always.
    muted_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    custom_tone: Mapped[str | None] = mapped_column(String(64), nullable=True)
    custom_vibrate: Mapped[str | None] = mapped_column(String(32), nullable=True)
    theme: Mapped[str | None] = mapped_column(String(32), nullable=True)
    wallpaper: Mapped[str | None] = mapped_column(String(64), nullable=True)
    marked_unread: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default=false(), nullable=False
    )
    # "Clear chat": messages with seq <= this are hidden from this user only.
    cleared_before_seq: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    # "Delete chat" (direct): the conversation stays off the list until a
    # message with a higher seq arrives.
    hidden_until_seq: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
