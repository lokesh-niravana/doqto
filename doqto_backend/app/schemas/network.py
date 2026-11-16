from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field

from app.core.constants import (
    INVITATION_MESSAGE_MAX_LEN,
    REPORT_CONTEXT_MAX_IDS,
    REPORT_DETAILS_MAX_LEN,
)
from app.core.enums import InvitationStatus, ReportReason, ReportStatus, ReportSubjectType
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
    """A doctor I blocked, with enough directory data to render the row
    (their profile 404s for me by design, so the list must carry it). No
    phone/email/NPI. `id` == `blocked_id` so the client's person-card parser
    routes on it like every other card."""

    id: uuid.UUID
    blocked_id: uuid.UUID
    full_name: str = ""
    headline: str | None = None
    specialty: str | None = None
    location_label: str | None = None
    avatar_color: str | None = None
    avatar_url: str | None = None
    avatar_presigned_url: str | None = None
    created_at: datetime


class MuteOut(BaseModel):
    muted_user_id: uuid.UUID
    created_at: datetime


class ReportCreateIn(BaseModel):
    # The app reports people from their profile and omits this; a message
    # report (batch 4) sends subject_type=message + the message id.
    subject_type: ReportSubjectType = ReportSubjectType.USER
    subject_id: uuid.UUID
    reason: ReportReason
    details: str | None = Field(default=None, max_length=REPORT_DETAILS_MAX_LEN)
    # Message reports: the last few message ids in the thread (ids ONLY, never
    # bodies) so a moderator can pull context through the audited read path.
    context_message_ids: list[uuid.UUID] = Field(
        default_factory=list, max_length=REPORT_CONTEXT_MAX_IDS
    )


class ReportOut(ORMModel):
    """Moderation queue row (super-admin only). Ids only — no message bodies."""

    id: uuid.UUID
    reporter_id: uuid.UUID
    subject_type: str
    subject_id: uuid.UUID
    reason: str
    details: str | None = None
    status: ReportStatus
    context_message_ids: list[uuid.UUID] | None = None
    resolved_by: uuid.UUID | None = None
    resolved_at: datetime | None = None
    created_at: datetime


class ReportStatusIn(BaseModel):
    status: ReportStatus


class CursorPage(BaseModel):
    """Uniform cursor-paginated envelope: {data, next_cursor}."""

    data: list
    next_cursor: str | None = None
