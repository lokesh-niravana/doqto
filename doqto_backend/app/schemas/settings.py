"""Settings payloads (batch 6): notification preferences, linked devices,
two-step PIN, status, export, app metadata. Nothing here carries PHI."""
from __future__ import annotations

import uuid
from datetime import datetime

from pydantic import BaseModel, Field, field_validator, model_validator

from app.core.constants import (
    APP_VERSION_MAX_LEN,
    DEVICE_NAME_MAX_LEN,
    NOTIFICATION_TONES,
    PIN_LENGTH,
    STATUS_CUSTOM_MAX_LEN,
    STATUS_EXPIRY_OPTIONS_SEC,
)
from app.core.enums import DevicePlatform, StatusPreset, VibratePattern


def _known_tone(v: str | None) -> str | None:
    if v is not None and v not in NOTIFICATION_TONES:
        raise ValueError("tone_invalid")
    return v


class NotificationSettingsOut(BaseModel):
    """Effective values — `*_show_preview` already resolved from NULL."""

    messages_tone: str
    messages_vibrate: VibratePattern
    messages_show_preview: bool
    messages_high_priority: bool
    groups_tone: str
    groups_vibrate: VibratePattern
    groups_show_preview: bool
    groups_high_priority: bool
    reaction_notifications: bool
    conversation_tones: bool
    haptics: bool


class NotificationSettingsPatch(BaseModel):
    messages_tone: str | None = None
    messages_vibrate: VibratePattern | None = None
    messages_show_preview: bool | None = None
    messages_high_priority: bool | None = None
    groups_tone: str | None = None
    groups_vibrate: VibratePattern | None = None
    groups_show_preview: bool | None = None
    groups_high_priority: bool | None = None
    reaction_notifications: bool | None = None
    conversation_tones: bool | None = None
    haptics: bool | None = None
    # "Reset notification settings": drop the row, back to defaults.
    reset: bool = False

    _tone_m = field_validator("messages_tone")(_known_tone)
    _tone_g = field_validator("groups_tone")(_known_tone)


class SessionOut(BaseModel):
    id: uuid.UUID
    device_name: str | None
    platform: DevicePlatform | None
    app_version: str | None
    ip: str | None
    created_at: datetime
    last_seen_at: datetime
    # The session behind the token that made this request.
    current: bool = False


class SessionRevokeOut(BaseModel):
    revoked: int


class PinIn(BaseModel):
    pin: str = Field(min_length=PIN_LENGTH, max_length=PIN_LENGTH)

    @field_validator("pin")
    @classmethod
    def _digits(cls, v: str) -> str:
        if not v.isdigit():
            raise ValueError("pin_invalid_format")
        return v


class PinSetIn(PinIn):
    # Required when a PIN already exists (change); ignored otherwise.
    current_pin: str | None = Field(default=None, min_length=PIN_LENGTH, max_length=PIN_LENGTH)


class PinDeleteIn(PinIn):
    pass


class PinVerifyIn(PinIn):
    pass


class PinStatusOut(BaseModel):
    pin_enabled: bool
    # When a forgot-PIN cooldown is running: the instant the PIN clears.
    pin_clears_at: datetime | None = None


class StatusPatch(BaseModel):
    """Exactly one of `preset` / `text`, or neither to clear. `expires_in_sec`
    is one of STATUS_EXPIRY_OPTIONS_SEC or null for never."""

    preset: StatusPreset | None = None
    text: str | None = Field(default=None, max_length=STATUS_CUSTOM_MAX_LEN)
    expires_in_sec: int | None = None

    @field_validator("text")
    @classmethod
    def _strip(cls, v: str | None) -> str | None:
        if v is None:
            return None
        v = v.strip()
        return v or None

    @field_validator("expires_in_sec")
    @classmethod
    def _known_expiry(cls, v: int | None) -> int | None:
        if v is not None and v not in STATUS_EXPIRY_OPTIONS_SEC:
            raise ValueError("status_expiry_invalid")
        return v

    @model_validator(mode="after")
    def _one_of(self):
        if self.preset is not None and self.text is not None:
            raise ValueError("status_preset_and_text")
        return self


class StatusOut(BaseModel):
    status_preset: StatusPreset | None = None
    status_text: str | None = None
    status_expires_at: datetime | None = None


def split_status(raw: str | None) -> tuple[StatusPreset | None, str | None]:
    """users.status_text holds a preset wire value OR custom text."""
    if raw is None:
        return None, None
    try:
        return StatusPreset(raw), None
    except ValueError:
        return None, raw


class ExportOut(BaseModel):
    url: str
    expires_at: datetime


class ScreenshotAuditIn(BaseModel):
    conversation_id: uuid.UUID


class MinVersionOut(BaseModel):
    ios: str
    android: str
    message: str


class LegalOut(BaseModel):
    help: str
    contact: str
    terms: str
    privacy: str
    hipaa: str


class DeviceInfo(BaseModel):
    """Optional device description sent with a sign-in (batch 6)."""

    device_name: str | None = Field(default=None, max_length=DEVICE_NAME_MAX_LEN)
    platform: DevicePlatform | None = None
    app_version: str | None = Field(default=None, max_length=APP_VERSION_MAX_LEN)

    @field_validator("device_name")
    @classmethod
    def _clean_name(cls, v: str | None) -> str | None:
        if v is None:
            return None
        v = " ".join(v.split())
        return v or None
