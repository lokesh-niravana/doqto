"""Operator moderation (super admin acting on a report)."""
from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field, field_validator

from app.core.constants import USER_SUSPEND_REASON_MAX_LEN


class UserSuspendIn(BaseModel):
    reason: str = Field(min_length=1, max_length=USER_SUSPEND_REASON_MAX_LEN)

    @field_validator("reason")
    @classmethod
    def _not_blank(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("reason_required")
        return v


class UserModerationOut(BaseModel):
    """Suspension state of an account. Ids and the operator's note only."""

    id: uuid.UUID
    suspended_at: datetime | None = None
    suspended_reason: str | None = None
