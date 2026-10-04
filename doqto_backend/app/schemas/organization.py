from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field

from app.core.enums import (
    DirectoryVisibility,
    ExternalDmPolicy,
    OrgRole,
    OrgStatus,
    PracticeType,
)
from app.schemas.common import ORMModel


class OrgCreateIn(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    address: str | None = None
    city: str | None = None
    state: str | None = Field(default=None, min_length=2, max_length=2)
    practice_type: PracticeType | None = None
    # The org_directory entry picked in lookup, if any.
    directory_source: str | None = Field(default=None, max_length=20)
    directory_id: str | None = Field(default=None, max_length=20)


class DirectoryRefIn(BaseModel):
    directory_source: str = Field(max_length=20)
    directory_id: str = Field(max_length=20)


class DirectoryOrgOut(BaseModel):
    id: uuid.UUID
    name: str
    status: OrgStatus


class DirectoryEntryOut(BaseModel):
    """One lookup result. `doqto_org` is set when it's already on Doqto —
    the app offers to join instead of creating a duplicate."""

    source: str
    source_id: str
    name: str
    legal_name: str
    city: str | None
    state: str | None
    practice_type: str
    member_count: int | None
    you_are_listed: bool
    doqto_org: DirectoryOrgOut | None = None


class OrgJoinIn(BaseModel):
    invite_code: str = Field(min_length=9, max_length=9)


class OrgOut(ORMModel):
    id: uuid.UUID
    name: str
    address: str | None
    city: str | None
    state: str | None
    practice_type: str | None
    invite_code: str
    status: OrgStatus
    review_notes: str | None = None
    directory_source: str | None = None
    directory_id: str | None = None
    verified_at: datetime | None
    created_at: datetime
    member_count: int = 0


class OrgApproveIn(BaseModel):
    notes: str | None = Field(default=None, max_length=500)


class OrgRejectIn(BaseModel):
    reason: str = Field(min_length=1, max_length=500)


class OrgNetworkingSettingsIn(BaseModel):
    """Partial update — only supplied fields change (admin kill switch + policy)."""

    external_networking_enabled: bool | None = None
    external_dm_policy: ExternalDmPolicy | None = None
    directory_visibility: DirectoryVisibility | None = None


class OrgNetworkingSettingsOut(ORMModel):
    external_networking_enabled: bool
    external_dm_policy: ExternalDmPolicy
    directory_visibility: DirectoryVisibility


class MemberOut(BaseModel):
    """Minimum-necessary member view (HIPAA H8) — deliberately NO phone,
    email, or NPI. Full identifiers stay on /users/me (UserOut) only."""

    id: uuid.UUID
    full_name: str
    specialty: str | None
    org_role: OrgRole
    joined_at: datetime
    presence: str | None = None
    avatar_color: str | None = None
    avatar_url: str | None = None
    avatar_presigned_url: str | None = None
