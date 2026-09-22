from __future__ import annotations

import re
import uuid
from datetime import datetime

from pydantic import BaseModel, EmailStr, Field, field_validator

from app.core.constants import (
    BIO_MAX_LEN,
    HANDLE_MAX_LEN,
    HANDLE_MIN_LEN,
    HANDLE_PATTERN,
    HEADLINE_MAX_LEN,
    SKILL_MAX_LEN,
    SKILLS_MAX_COUNT,
    YEARS_OF_EXPERIENCE_MAX,
    YEARS_OF_EXPERIENCE_MIN,
)
from app.core.enums import UserRole
from app.schemas.common import ORMModel


class UserOut(ORMModel):
    id: uuid.UUID
    phone: str | None
    email: str | None
    full_name: str
    specialty: str | None
    npi_number: str
    role: UserRole
    avatar_color: str | None
    avatar_url: str | None
    avatar_presigned_url: str | None = None
    handle: str | None = None
    headline: str | None = None
    bio: str | None
    city: str | None
    state: str | None
    years_of_experience: int | None
    skills: list[str] = []
    last_seen_at: datetime | None
    created_at: datetime


class UserPatch(BaseModel):
    full_name: str | None = None
    email: EmailStr | None = None
    handle: str | None = Field(default=None, min_length=HANDLE_MIN_LEN, max_length=HANDLE_MAX_LEN)
    headline: str | None = Field(default=None, max_length=HEADLINE_MAX_LEN)
    specialty: str | None = Field(default=None, max_length=100)
    bio: str | None = Field(default=None, max_length=BIO_MAX_LEN)
    city: str | None = Field(default=None, max_length=120)
    state: str | None = Field(default=None, max_length=120)
    years_of_experience: int | None = Field(
        default=None, ge=YEARS_OF_EXPERIENCE_MIN, le=YEARS_OF_EXPERIENCE_MAX
    )
    skills: list[str] | None = None

    @field_validator("handle")
    @classmethod
    def _validate_handle(cls, v: str | None) -> str | None:
        if v is None:
            return None
        v = v.strip()
        if not re.fullmatch(HANDLE_PATTERN, v):
            raise ValueError("handle_invalid")
        return v

    @field_validator("skills")
    @classmethod
    def _validate_skills(cls, v: list[str] | None) -> list[str] | None:
        if v is None:
            return None
        cleaned = [s.strip() for s in v if s and s.strip()]
        if len(cleaned) > SKILLS_MAX_COUNT:
            raise ValueError("skills_too_many")
        for s in cleaned:
            if len(s) > SKILL_MAX_LEN:
                raise ValueError("skill_too_long")
        return cleaned


async def build_user_out(user) -> UserOut:  # type: ignore[no-untyped-def]
    """Serialize a User ORM row into UserOut, embedding a fresh presigned avatar URL."""
    out = UserOut.model_validate(user)
    if user.avatar_url:
        from app.services.file_service import FileService

        out = out.model_copy(
            update={"avatar_presigned_url": await FileService.presigned_url(key=user.avatar_url)}
        )
    return out
