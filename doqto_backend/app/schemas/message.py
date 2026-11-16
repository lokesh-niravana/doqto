from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field, model_validator

from app.core.constants import (
    CAPTION_MAX_LEN,
    FORWARD_MAX_DESTINATIONS,
    PIN_DURATIONS_SEC,
    POLL_OPTION_MAX_LEN,
    POLL_OPTIONS_MAX,
    POLL_OPTIONS_MIN,
    POLL_QUESTION_MAX_LEN,
)
from app.core.enums import MessageType, TranscriptStatus


class PollCreateIn(BaseModel):
    """Batch 5: `poll` on POST /conversations/{id}/messages with type=poll."""

    question: str = Field(min_length=1, max_length=POLL_QUESTION_MAX_LEN)
    options: list[str] = Field(min_length=POLL_OPTIONS_MIN, max_length=POLL_OPTIONS_MAX)
    multiple: bool = False

    @model_validator(mode="after")
    def _options_clean(self) -> "PollCreateIn":
        cleaned = [o.strip() for o in self.options]
        if any(not o or len(o) > POLL_OPTION_MAX_LEN for o in cleaned):
            raise ValueError("poll_option_invalid")
        if len({o.casefold() for o in cleaned}) != len(cleaned):
            raise ValueError("poll_options_duplicate")
        self.options = cleaned
        self.question = self.question.strip()
        if not self.question:
            raise ValueError("poll_question_empty")
        return self


class MessageSendIn(BaseModel):
    type: MessageType = MessageType.TEXT
    # Required for text; for a poll the question is the body (content ignored).
    content: str | None = Field(default=None, min_length=1, max_length=5000)
    # Idempotency key (uuid from the client outbox); retries return the
    # original message instead of creating a duplicate.
    client_id: str | None = Field(default=None, max_length=64)
    # Reply/quote (batch 4): a live message in the SAME conversation.
    reply_to_id: uuid.UUID | None = None
    # Polls (batch 5).
    poll: PollCreateIn | None = None

    @model_validator(mode="after")
    def _shape(self) -> "MessageSendIn":
        if self.type == MessageType.POLL:
            if self.poll is None:
                raise ValueError("poll_required")
        elif self.type == MessageType.TEXT:
            if self.content is None:
                raise ValueError("content_required")
        else:
            # Media goes through the upload routes, system is server-only.
            raise ValueError("type_not_sendable")
        return self


class PollVoteIn(BaseModel):
    """PUT /messages/{id}/vote — the caller's full selection (replaces)."""

    option_ids: list[uuid.UUID] = Field(min_length=1, max_length=POLL_OPTIONS_MAX)


class PollOptionOut(BaseModel):
    id: uuid.UUID
    position: int
    text: str
    vote_count: int
    voter_ids: list[uuid.UUID]  # oldest vote first — visible to every member


class PollOut(BaseModel):
    question: str
    multiple: bool
    options: list[PollOptionOut]
    voter_count: int  # distinct members who voted


class PollUpdatedEvent(BaseModel):
    """WS `poll_updated` — every member, after a vote changed."""

    conversation_id: uuid.UUID
    message_id: uuid.UUID
    poll: PollOut
    changed_at: datetime
    actor_id: uuid.UUID


class UploadIntentIn(BaseModel):
    """POST /messages/upload-intent/{conv}: describe the object the client is
    about to PUT straight to S3. Size is validated again on complete."""

    file_name: str = Field(min_length=1, max_length=255)
    content_type: str = Field(min_length=3, max_length=255)
    size_bytes: int = Field(ge=1)
    client_id: str | None = Field(default=None, max_length=64)
    # Video: the client also uploads a JPEG poster (no ffmpeg server-side).
    with_thumb: bool = False


class UploadPartUrlOut(BaseModel):
    part_number: int
    url: str


class UploadIntentOut(BaseModel):
    intent_id: uuid.UUID
    type: MessageType
    key: str
    part_size: int
    expires_in: int
    # Exactly one of: a single presigned PUT, or multipart part URLs.
    put_url: str | None = None
    upload_id: str | None = None
    part_urls: list[UploadPartUrlOut] = []
    thumb_put_url: str | None = None
    # Set when `client_id` matched an already-sent message: nothing to upload.
    message: "MessageOut | None" = None


class UploadPartIn(BaseModel):
    part_number: int = Field(ge=1, le=10000)
    etag: str = Field(min_length=1, max_length=255)


class UploadCompleteIn(BaseModel):
    intent_id: uuid.UUID
    parts: list[UploadPartIn] = []
    caption: str | None = Field(default=None, max_length=CAPTION_MAX_LEN)
    duration_sec: int | None = Field(default=None, ge=0)
    width: int | None = Field(default=None, ge=1, le=20000)
    height: int | None = Field(default=None, ge=1, le=20000)
    has_thumb: bool = False


class MessageForwardIn(BaseModel):
    """Forward one message to up to FORWARD_MAX_DESTINATIONS conversations."""

    conversation_ids: list[uuid.UUID] = Field(
        min_length=1, max_length=FORWARD_MAX_DESTINATIONS
    )


class ConversationPinIn(BaseModel):
    message_id: uuid.UUID
    # One of PIN_DURATIONS_SEC (24h / 7d / 30d).
    duration_sec: int = Field(default=max(PIN_DURATIONS_SEC))


class ReplyPreviewOut(BaseModel):
    """The quoted message, rendered live from its current row: deleted →
    preview "Message deleted"; expired/purged → the whole object is null."""

    id: uuid.UUID
    sender_id: uuid.UUID
    type: MessageType
    preview: str | None


class MessageEditIn(BaseModel):
    content: str = Field(min_length=1, max_length=5000)


class MessageReactIn(BaseModel):
    # One emoji grapheme cluster; validated with the `emoji` package in the
    # service (ZWJ sequences, skin tones, flags allowed). 32 bytes UTF-8 max.
    emoji: str = Field(min_length=1, max_length=32)


class ReactionOut(BaseModel):
    emoji: str
    count: int
    user_ids: list[uuid.UUID]  # oldest reaction first


class MessageHideIn(BaseModel):
    message_ids: list[uuid.UUID] = Field(min_length=1, max_length=100)


class MessageEditOut(BaseModel):
    content: str
    replaced_at: datetime


class MessageScheduleIn(BaseModel):
    content: str = Field(min_length=1, max_length=5000)
    # Wall-clock time in the picked zone, naive ISO ("2026-08-09T14:30:00").
    scheduled_local: str = Field(max_length=32)
    # IANA zone name ("Asia/Kolkata"); the server resolves the UTC instant so
    # DST rules live in one place (Python zoneinfo), not in every client.
    timezone: str = Field(max_length=64)


class ScheduledMessageOut(BaseModel):
    id: uuid.UUID
    conversation_id: uuid.UUID
    scheduled_at: datetime  # resolved UTC instant
    timezone: str
    status: str


class MessageOut(BaseModel):
    id: uuid.UUID
    conversation_id: uuid.UUID
    sender_id: uuid.UUID
    type: MessageType
    seq: int  # per-conversation sequence number (catch-up sync cursor)
    content: str | None
    s3_key: str | None
    file_name: str | None
    file_size_bytes: int | None
    voice_duration_sec: int | None
    transcript: str | None
    transcript_status: TranscriptStatus
    expires_at: datetime | None
    created_at: datetime
    read: bool = False  # read by a recipient (blue double-check)
    delivered: bool = False  # delivered to a recipient (gray double-check)
    client_id: str | None = None  # echoes the sender's idempotency key
    edited_at: datetime | None = None
    deleted_at: datetime | None = None  # tombstone: content/media gone, row kept
    # Same for every viewer (no per-user fields), so one payload fans out.
    # Sorted by count desc, then earliest reaction.
    reactions: list[ReactionOut] = []
    changed_at: datetime | None = None  # last edit/delete/reaction (catch-up cursor)
    # Batch 4. reply_to is rebuilt from the target row on every read.
    reply_to_id: uuid.UUID | None = None
    reply_to: ReplyPreviewOut | None = None
    forwarded: bool = False
    forward_depth: int = 0
    mentions: list[uuid.UUID] = []
    # The ONE per-viewer field: true only in responses to the viewer's own
    # reads (thread page, starred list). Always false in fanned-out WS payloads.
    starred: bool = False
    # Batch 5 (media). caption: image/video/file/voice; thumb_key: video
    # poster (fetch via GET /messages/{id}/file-url?thumb=1); waveform:
    # base64 of ≤ 64 amplitude bytes; voice_duration_sec doubles as the video
    # length; poll: tallies + voter ids (same for every viewer).
    caption: str | None = None
    thumb_key: str | None = None
    waveform: str | None = None
    media_width: int | None = None
    media_height: int | None = None
    poll: PollOut | None = None


class MediaItemOut(BaseModel):
    """One row of GET /conversations/{id}/media. `urls` is filled for
    type=link (every http(s) URL found in the text), empty otherwise."""

    message: MessageOut
    urls: list[str] = []


class MediaPage(BaseModel):
    data: list[MediaItemOut]
    next_cursor: str | None = None


class StarredMessageOut(BaseModel):
    """One row of GET /messages/starred — the message plus where it lives."""

    message: MessageOut
    conversation_id: uuid.UUID
    conversation_type: str
    conversation_name: str | None = None  # group name / other member's name
    starred_at: datetime


class StarredPage(BaseModel):
    data: list[StarredMessageOut]
    next_cursor: str | None = None


class MessageStarredEvent(BaseModel):
    """WS `message_starred` — actor's own devices only (stars are private)."""

    conversation_id: uuid.UUID
    message_id: uuid.UUID
    starred: bool


class MessagePinnedEvent(BaseModel):
    """WS `message_pinned` / `message_unpinned` — every member. On unpin
    `message_id` is the message that WAS pinned and `pinned_until` is null."""

    conversation_id: uuid.UUID
    message_id: uuid.UUID | None
    pinned_until: datetime | None
    actor_id: uuid.UUID | None


class LinkPreviewOut(BaseModel):
    url: str  # final URL after redirects
    title: str | None = None
    description: str | None = None
    site_name: str | None = None
    # data: URL (base64) ≤ LINK_PREVIEW_IMAGE_MAX_BYTES, proxied by the server so
    # the client never contacts the third-party host.
    image_data_url: str | None = None



class MessageReactedEvent(BaseModel):
    """WS `message_reacted`: patch reactions only — never the whole row, so
    the receiver's read/delivered ticks are left alone."""

    conversation_id: uuid.UUID
    message_id: uuid.UUID
    reactions: list[ReactionOut]
    changed_at: datetime
    actor_id: uuid.UUID
    emoji: str | None  # None = the actor removed their reaction


class MessageReceiptOut(BaseModel):
    """One recipient's delivery/read state for a message (sender-only view).
    Group chats derive it from the member seq cursors, so read_at is the
    member's last read time and delivered carries no timestamp."""

    user_id: uuid.UUID
    full_name: str
    avatar_color: str | None = None
    avatar_url: str | None = None
    avatar_presigned_url: str | None = None
    delivered: bool = False
    read: bool = False
    delivered_at: datetime | None = None
    read_at: datetime | None = None


class FileUrlOut(BaseModel):
    url: str
    expires_in: int


UploadIntentOut.model_rebuild()
