from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import BigInteger, Boolean, DateTime, ForeignKey, Index, Integer, LargeBinary, String, Text, false, func
from sqlalchemy.dialects.postgresql import ARRAY, UUID as PgUUID
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
    # --- Batch 4 ---------------------------------------------------------- #
    # Reply/quote: the message this one answers (same conversation). The quote
    # is rendered live from the target row, so nothing is copied here.
    reply_to_id: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.MESSAGES}.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    # Forwarded copy: own row, own (copied) S3 object. forward_depth counts
    # hops; at FORWARD_MAX_DEPTH the client shows "Forwarded many times" and the
    # server refuses to forward again.
    forwarded: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default=false(), nullable=False
    )
    forward_depth: Mapped[int] = mapped_column(
        Integer, default=0, server_default="0", nullable=False
    )
    # Members referenced with `@[<uuid>]` tokens in the body (validated as
    # conversation members at send time). Ids only — not PHI.
    mentions: Mapped[list[uuid.UUID] | None] = mapped_column(
        ARRAY(PgUUID(as_uuid=True)), nullable=True
    )
    # --- Batch 5 (media) --------------------------------------------------- #
    # Caption under a photo / video / file / voice note — PHI, encrypted like
    # the body. Copied on forward, shredded with the message.
    caption_encrypted: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    # Poster thumbnail (video) — JPEG object of its own, EXIF-stripped.
    thumb_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Voice-note amplitude envelope: ≤ 64 raw bytes (0–255 each), base64 on
    # the wire. Not PHI (shape only) but goes with the message everywhere.
    waveform: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    # Pixel size of an image / video so the client can size the bubble
    # before the bytes arrive. voice_duration_sec doubles as the video length.
    media_width: Mapped[int | None] = mapped_column(Integer, nullable=True)
    media_height: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Polls: the question is the (encrypted) body; options + votes live in
    # poll_options / poll_votes. multiple = several options per voter.
    poll_multiple: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class PollOption(Base):
    """One answer of a poll message. Option text is PHI-adjacent (a doctor
    could poll about a case) — encrypted like bodies, shredded with the poll."""

    __tablename__ = Tables.POLL_OPTIONS

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    message_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.MESSAGES}.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    text_encrypted: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)


class PollVote(Base):
    """A member's vote on one option. Visible to every member (no anonymous
    polls). A member who leaves a group takes their votes with them."""

    __tablename__ = Tables.POLL_VOTES

    option_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.POLL_OPTIONS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
        index=True,
    )
    # Denormalised so "my votes on this poll" and the leave-group purge are
    # one indexed lookup instead of a join through poll_options.
    message_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.MESSAGES}.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class UploadIntent(Base):
    """A presigned (multipart) upload the client is filling. Holds everything
    needed to create the message on complete, plus the S3 upload id so an
    abandoned intent can be aborted by the purge job. No PHI except the file
    name (same as messages.file_name)."""

    __tablename__ = Tables.UPLOAD_INTENTS

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
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"), nullable=False
    )
    # The message row is pre-allocated so the S3 key can embed its id.
    message_id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    type: Mapped[MessageType] = mapped_column(String(20), nullable=False)
    s3_key: Mapped[str] = mapped_column(Text, nullable=False)
    thumb_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    # S3 multipart upload id; NULL for a single presigned PUT.
    upload_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    part_count: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    content_type: Mapped[str] = mapped_column(String(255), nullable=False)
    file_name: Mapped[str] = mapped_column(String(255), nullable=False)
    size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    client_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class MessageStar(Base):
    """A member's private bookmark on a message. Not PHI (just the pair).
    Stars never extend retention: the purge job drops stars on deleted /
    expired messages."""

    __tablename__ = Tables.MESSAGE_STARS
    __table_args__ = (Index("ix_message_stars_user_created", "user_id", "created_at"),)

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
