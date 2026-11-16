from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field

from app.schemas.settings import DeviceInfo


class RefreshIn(BaseModel):
    refresh_token: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    is_registered: bool
    # Linked devices (batch 6): the row this pair belongs to, so the client
    # can tell "this device" apart in the sessions list and in WS events.
    session_id: uuid.UUID | None = None
    # Two-step PIN (batch 6): true when this device still owes a PIN — every
    # route except /auth/pin/* answers 403 pin_required until it is entered.
    pin_required: bool = False
    pin_clears_at: datetime | None = None


class RegisterIn(BaseModel):
    full_name: str = Field(min_length=1, max_length=255)
    specialty: str | None = None
    npi_number: str = Field(min_length=10, max_length=10)


class FirebaseSignInIn(DeviceInfo):
    """The ID token minted by Firebase for whichever provider the user chose,
    plus an optional description of the device (batch 6, linked devices)."""

    id_token: str = Field(min_length=1, max_length=8192)


class LinkPhoneIn(BaseModel):
    """A Firebase ID token refreshed after linking a phone credential.

    Its phone_number claim is Google's word that the SMS was answered.
    """

    id_token: str = Field(min_length=1, max_length=8192)
