"""Compliance (batch 7) wire shapes: org policies, break-glass requests,
audit rows, scheduled-message list, .well-known payloads. None of them
carries message content; the break-glass page reuses MessageOut."""
from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field

from app.core.constants import (
    ACCESS_REQUEST_REASON_MAX_LEN,
    RETENTION_DAYS_MAX,
    RETENTION_DAYS_MIN,
)
from app.core.enums import AccessRequestStatus
from app.schemas.common import ORMModel
from app.schemas.message import MessageOut


class OrgPoliciesOut(BaseModel):
    """Effective org policies — every key present, defaults filled in."""

    allow_forward_outside_org: bool
    allow_copy: bool
    allow_media_export: bool
    block_screenshots: bool
    show_preview_in_banners_default: bool
    default_disappear_sec: int | None = None
    retention_days: int | None = None
    legal_hold: bool


class OrgPoliciesPatch(BaseModel):
    """Partial update — only supplied keys change. Nullable ints accept
    `null` to clear (no timer / keep forever)."""

    model_config = {"extra": "forbid"}

    allow_forward_outside_org: bool | None = None
    allow_copy: bool | None = None
    allow_media_export: bool | None = None
    block_screenshots: bool | None = None
    show_preview_in_banners_default: bool | None = None
    default_disappear_sec: int | None = None
    retention_days: int | None = Field(default=None, ge=RETENTION_DAYS_MIN, le=RETENTION_DAYS_MAX)
    legal_hold: bool | None = None

    def changes(self) -> dict[str, Any]:
        """Keys the client actually sent (so `null` clears a nullable int)."""
        return {k: getattr(self, k) for k in self.model_fields_set}


class AccessRequestCreateIn(BaseModel):
    conversation_id: uuid.UUID
    reason: str = Field(min_length=1, max_length=ACCESS_REQUEST_REASON_MAX_LEN)


class AccessRequestOut(ORMModel):
    id: uuid.UUID
    org_id: uuid.UUID
    conversation_id: uuid.UUID
    requester_id: uuid.UUID
    reason: str
    status: AccessRequestStatus
    decided_by: uuid.UUID | None = None
    decided_at: datetime | None = None
    expires_at: datetime | None = None
    first_read_at: datetime | None = None
    created_at: datetime


class AccessRequestPage(BaseModel):
    data: list[AccessRequestOut]
    next_cursor: datetime | None = None


class BreakGlassPage(BaseModel):
    data: list[MessageOut]
    next_cursor: str | None = None


class AuditRowOut(BaseModel):
    """One audit row. `ip_address` / `user_agent` are included for
    super-admins only; org admins get them as null (minimum necessary)."""

    id: uuid.UUID
    seq: int | None
    user_id: uuid.UUID | None
    action: str
    resource_type: str | None
    resource_id: uuid.UUID | None
    ip_address: str | None = None
    user_agent: str | None = None
    metadata: dict[str, Any] | None = None
    prev_hash: str | None = None
    hash: str | None = None
    created_at: datetime


class AuditPage(BaseModel):
    data: list[AuditRowOut]
    next_cursor: int | None = None


class ScheduledMessageListOut(BaseModel):
    id: uuid.UUID
    conversation_id: uuid.UUID
    scheduled_at: datetime
    timezone: str
    status: str
    error: str | None = None
    created_at: datetime
