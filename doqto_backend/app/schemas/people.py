"""People-search + public-profile payloads (M2).

HIPAA HARD RULE: neither PersonCardOut nor PublicProfileOut may EVER carry
phone, email, or npi_number. NPI is a restricted licensure identifier. This
extends the minimum-necessary rule already applied to MemberOut. The absence of
those fields is asserted by tests/test_m2_search.py + tests/test_m2_profile.py.

Degree is serialised as a plain wire STRING ('1st' | '2nd' | '3rd' | 'out'),
NOT a shared enum — this avoids a three-file enum-parity dance for what is a
purely client-facing display badge. See docs/enums.md note.
"""
from __future__ import annotations

import uuid
from typing import Literal

from pydantic import BaseModel

DegreeLabel = Literal["1st", "2nd", "3rd", "out"]
ConnectionState = Literal["none", "pending_outgoing", "pending_incoming", "connected"]
CanMessage = Literal["open", "request", "denied"]


def location_label(city: str | None, state: str | None) -> str | None:
    """Serialise 'City, ST' from the reused user.city / user.state columns.

    No new about/location columns exist — bio IS 'about', city/state ARE the
    location. Returns None when both are blank.
    """
    city = (city or "").strip()
    state = (state or "").strip()
    if city and state:
        return f"{city}, {state}"
    return city or state or None


class PersonCardOut(BaseModel):
    """A single search-result card. NO phone / email / npi_number."""

    id: uuid.UUID
    full_name: str
    headline: str | None = None
    specialty: str | None = None
    location_label: str | None = None
    avatar_color: str | None = None
    avatar_url: str | None = None
    avatar_presigned_url: str | None = None
    degree: DegreeLabel
    mutual_count: int = 0
    # Suggestions only: why this doctor is suggested. colleague | mutual |
    # specialty_nearby | specialty | nearby | new_member.
    reason: str | None = None


class PeopleSearchPage(BaseModel):
    """Cursor-paginated search results. `next_cursor` is an opaque offset token."""

    data: list[PersonCardOut] = []
    next_cursor: str | None = None


class PublicProfileOut(BaseModel):
    """A viewable public profile. NO phone / email / npi_number, ever — not
    even when the viewer is a colleague/connection."""

    id: uuid.UUID
    full_name: str
    headline: str | None = None
    specialty: str | None = None
    location_label: str | None = None
    avatar_color: str | None = None
    avatar_url: str | None = None
    avatar_presigned_url: str | None = None
    about: str | None = None  # reuse of user.bio
    years_of_experience: int | None = None
    skills: list[str] = []
    degree: DegreeLabel
    connection_state: ConnectionState
    mutual_count: int = 0
    can_message: CanMessage
    context_label: str | None = None
    # True when viewer and target share an organization. `can_message: open`
    # alone can't stand in for this — an org with dm_policy 'everyone' also
    # yields open, and there a Connect prompt is still meaningful.
    is_colleague: bool = False
