from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field

from app.core.enums import ConversationAccess, ConversationType, MessageType
from app.schemas.common import ORMModel


class ConversationCreateIn(BaseModel):
    type: ConversationType
    name: str | None = Field(default=None, max_length=100)
    member_ids: list[uuid.UUID] = Field(min_length=1)


class ConversationSettingsIn(BaseModel):
    disappear_after_sec: int | None = None


class ConversationAddMembersIn(BaseModel):
    user_ids: list[uuid.UUID] = Field(min_length=1)


class ConversationPrefsOut(ORMModel):
    """The caller's private view of a conversation (batch 3). Defaults when
    no row exists."""

    pinned_at: datetime | None = None
    archived: bool = False
    muted_until: datetime | None = None
    custom_tone: str | None = None
    custom_vibrate: str | None = None
    theme: str | None = None
    wallpaper: str | None = None
    marked_unread: bool = False
    cleared_before_seq: int | None = None
    hidden_until_seq: int | None = None


class ConversationPrefsIn(BaseModel):
    """Partial update: only fields present in the body change. `pinned` maps
    to pinned_at (now / NULL); `clear_chat` / `delete_chat` are one-shot
    actions that move the seq cursors."""

    pinned: bool | None = None
    archived: bool | None = None
    muted_until: datetime | None = None
    custom_tone: str | None = Field(default=None, max_length=64)
    custom_vibrate: str | None = Field(default=None, max_length=32)
    theme: str | None = Field(default=None, max_length=32)
    wallpaper: str | None = Field(default=None, max_length=64)
    marked_unread: bool | None = None
    clear_chat: bool = False
    delete_chat: bool = False


class UnreadTotalOut(BaseModel):
    total: int


class ConversationOut(ORMModel):
    id: uuid.UUID
    org_id: uuid.UUID | None  # NULL = network (cross-org) conversation
    type: ConversationType
    name: str | None
    created_by: uuid.UUID | None
    # Networking tier + provenance (M3, additive). is_network mirrors org_id IS
    # NULL (populated from the model's is_network property).
    access: ConversationAccess = ConversationAccess.OPEN
    initiator_id: uuid.UUID | None = None
    is_network: bool = False
    # Requests filter only (M4, compute-on-read): a low-quality request the
    # client hides from the badge / surfaces separately. Always False elsewhere.
    is_hidden: bool = False
    disappear_after_sec: int | None
    # Pinned message (batch 4) — null when nothing is pinned / pin expired.
    pinned_message_id: uuid.UUID | None = None
    pinned_until: datetime | None = None
    # The `groups` row behind a network group chat (batch 4): the client needs
    # it for @mention members and admin actions when the thread is opened from
    # the chat list. Null for direct chats and legacy org group chats.
    group_id: uuid.UUID | None = None
    created_at: datetime
    updated_at: datetime
    member_ids: list[uuid.UUID] = []
    display_name: str | None = None  # direct chats: the other member's full name
    last_message_at: datetime | None = None
    last_message_preview: str | None = None
    last_message_sender_id: uuid.UUID | None = None
    last_message_type: MessageType | None = None
    unread_count: int = 0
    # The caller's own pin / archive / mute / … state (batch 3).
    prefs: ConversationPrefsOut = Field(default_factory=ConversationPrefsOut)
    # Batch 5: may THIS caller save / share media from this chat
    # (org policy allow_media_export; users with no org may). The server
    # re-checks on POST /messages/{id}/export-audit.
    media_export_allowed: bool = False
