from __future__ import annotations

from pydantic import BaseModel, Field


class RefreshIn(BaseModel):
    refresh_token: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    is_registered: bool


class RegisterIn(BaseModel):
    full_name: str = Field(min_length=1, max_length=255)
    specialty: str | None = None
    npi_number: str = Field(min_length=10, max_length=10)


class FirebaseSignInIn(BaseModel):
    """The ID token minted by Firebase for whichever provider the user chose."""

    id_token: str = Field(min_length=1, max_length=8192)


class LinkPhoneIn(BaseModel):
    """A Firebase ID token refreshed after linking a phone credential.

    Its phone_number claim is Google's word that the SMS was answered.
    """

    id_token: str = Field(min_length=1, max_length=8192)
