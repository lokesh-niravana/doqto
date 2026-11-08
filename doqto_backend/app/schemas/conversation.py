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
    created_at: datetime
    updated_at: datetime
    member_ids: list[uuid.UUID] = []
    display_name: str | None = None  # direct chats: the other member's full name
    last_message_at: datetime | None = None
    last_message_preview: str | None = None
    last_message_sender_id: uuid.UUID | None = None
    last_message_type: MessageType | None = None
    unread_count: int = 0
