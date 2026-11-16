from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, field_validator

from app.core.constants import DISAPPEAR_OPTIONS_SEC
from app.core.enums import (
    Discoverability,
    DmPolicy,
    InvitePolicy,
    LastSeenVisibility,
    OnlineVisibility,
    PresenceStatus,
    ProfileFieldVisibility,
    StatusPreset,
)
from app.schemas.common import ORMModel


class PrivacyOut(ORMModel):
    invite_policy: InvitePolicy
    dm_policy: DmPolicy
    discoverability: Discoverability
    show_mutual_connections: bool
    last_seen_visibility: LastSeenVisibility
    online_visibility: OnlineVisibility
    profile_photo_visibility: ProfileFieldVisibility
    about_visibility: ProfileFieldVisibility
    read_receipts: bool
    default_disappear_sec: int | None
    link_previews: bool


class PrivacyPatch(BaseModel):
    invite_policy: InvitePolicy | None = None
    dm_policy: DmPolicy | None = None
    discoverability: Discoverability | None = None
    show_mutual_connections: bool | None = None
    last_seen_visibility: LastSeenVisibility | None = None
    online_visibility: OnlineVisibility | None = None
    profile_photo_visibility: ProfileFieldVisibility | None = None
    about_visibility: ProfileFieldVisibility | None = None
    read_receipts: bool | None = None
    # None clears it (off). Must be one of the app's timer options.
    default_disappear_sec: int | None = None
    link_previews: bool | None = None

    @field_validator("default_disappear_sec")
    @classmethod
    def _known_timer(cls, v: int | None) -> int | None:
        if v is not None and v not in DISAPPEAR_OPTIONS_SEC:
            raise ValueError("disappear_option_invalid")
        return v


class PresenceOut(BaseModel):
    """One user's presence as the CALLER may see it: a hidden target reads
    exactly like an offline stranger (status offline, no last_seen_at)."""

    user_id: uuid.UUID
    status: PresenceStatus
    last_seen_at: datetime | None = None
    # Status under the name (batch 6) — directory data, shown to anyone who
    # may see the profile; not gated by last-seen visibility.
    status_preset: StatusPreset | None = None
    status_text: str | None = None
    status_expires_at: datetime | None = None
