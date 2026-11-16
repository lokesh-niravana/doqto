"""Settings (batch 6): per-user notification preferences and linked-device
sessions. Nothing here is PHI — tone names, device models and jtis only."""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, String, func, true
from sqlalchemy.dialects.postgresql import INET, UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.constants import NOTIFICATION_TONE_DEFAULT
from app.core.enums import VibratePattern
from app.db.postgres import Base
from app.db.tables import Tables


class UserNotificationSettings(Base):
    """Row absent = defaults (see NotificationSettingsService.defaults).
    `*_show_preview` is nullable: NULL means "not chosen", which resolves to
    off for a user in an org and on otherwise."""

    __tablename__ = Tables.USER_NOTIFICATION_SETTINGS

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    messages_tone: Mapped[str] = mapped_column(
        String(32), nullable=False, default=NOTIFICATION_TONE_DEFAULT,
        server_default=NOTIFICATION_TONE_DEFAULT,
    )
    messages_vibrate: Mapped[VibratePattern] = mapped_column(
        String(16), nullable=False, default=VibratePattern.DEFAULT,
        server_default=VibratePattern.DEFAULT.value,
    )
    messages_show_preview: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    messages_high_priority: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default=true()
    )
    groups_tone: Mapped[str] = mapped_column(
        String(32), nullable=False, default=NOTIFICATION_TONE_DEFAULT,
        server_default=NOTIFICATION_TONE_DEFAULT,
    )
    groups_vibrate: Mapped[VibratePattern] = mapped_column(
        String(16), nullable=False, default=VibratePattern.DEFAULT,
        server_default=VibratePattern.DEFAULT.value,
    )
    groups_show_preview: Mapped[bool | None] = mapped_column(Boolean, nullable=True)
    groups_high_priority: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default=true()
    )
    reaction_notifications: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default=true()
    )
    conversation_tones: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default=true()
    )
    haptics: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=True, server_default=true()
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


class Session(Base):
    """One sign-in on one device. The jtis mirror the Redis session keys: the
    row is the durable list, Redis is the live gate. Revoking deletes the
    Redis keys and stamps revoked_at; the row stays for the audit trail."""

    __tablename__ = Tables.SESSIONS

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    device_name: Mapped[str | None] = mapped_column(String(80), nullable=True)
    # DevicePlatform wire value ("ios" / "android"), or NULL when unknown.
    platform: Mapped[str | None] = mapped_column(String(10), nullable=True)
    app_version: Mapped[str | None] = mapped_column(String(32), nullable=True)
    ip: Mapped[str | None] = mapped_column(INET, nullable=True)
    refresh_jti: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    access_jti: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    # Two-step PIN (batch 6): NULL while the device still owes a PIN. Set at
    # issue time for devices this user has signed in from before, or when
    # the user has no PIN at all.
    pin_verified_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    @property
    def active(self) -> bool:
        return self.revoked_at is None
