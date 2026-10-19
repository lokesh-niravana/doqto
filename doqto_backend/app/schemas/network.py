from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field

from app.core.constants import INVITATION_MESSAGE_MAX_LEN, REPORT_DETAILS_MAX_LEN
from app.core.enums import InvitationStatus
from app.schemas.common import ORMModel


class InvitationCreateIn(BaseModel):
    recipient_id: uuid.UUID
    message: str | None = Field(default=None, max_length=INVITATION_MESSAGE_MAX_LEN)


class InvitationPartyOut(BaseModel):
    """Directory-only identity of a party to an invitation, so the client can
    render a name + avatar. NO phone/email/NPI (minimum-necessary)."""

    id: uuid.UUID
    full_name: str
    headline: str | None = None
    specialty: str | None = None
    avatar_color: str | None = None
    avatar_url: str | None = None
    avatar_presigned_url: str | None = None


class InvitationOut(ORMModel):
    id: uuid.UUID
    sender_id: uuid.UUID
    recipient_id: uuid.UUID
    message: str | None = None
    status: InvitationStatus
    created_at: datetime
    responded_at: datetime | None = None
    # Populated on list responses; a bare id alone leaves the card nameless.
    sender: InvitationPartyOut | None = None
    recipient: InvitationPartyOut | None = None


class InvitationSendResult(BaseModel):
    """Send returns either the created invitation or, on reciprocal auto-accept,
    a formed connection."""

    result: str  # 'invited' | 'connected'
    invitation: InvitationOut | None = None
    connected_user_id: uuid.UUID | None = None


class ConnectionCardOut(BaseModel):
    """The *other* party in one of my connections (directory data only — no
    phone/email/NPI, ever).

    `id` is the person's user id — same key as PersonCardOut, because the
    client parses both with one person-card model and routes on `id`.
    """

    id: uuid.UUID
    full_name: str
    specialty: str | None = None
    avatar_color: str | None = None
    avatar_url: str | None = None
    avatar_presigned_url: str | None = None
    connected_at: datetime


class MutualConnectionOut(BaseModel):
    user_id: uuid.UUID
    full_name: str
    avatar_color: str | None = None
    avatar_url: str | None = None


class BlockOut(BaseModel):
    blocked_id: uuid.UUID
    created_at: datetime


class MuteOut(BaseModel):
    muted_user_id: uuid.UUID
    created_at: datetime


class ReportCreateIn(BaseModel):
    # The app reports people from their profile and omits this.
    subject_type: str = Field(default="user", max_length=20)
    subject_id: uuid.UUID
    reason: str = Field(max_length=50)
    details: str | None = Field(default=None, max_length=REPORT_DETAILS_MAX_LEN)


class CursorPage(BaseModel):
    """Uniform cursor-paginated envelope: {data, next_cursor}."""

    data: list
    next_cursor: str | None = None
