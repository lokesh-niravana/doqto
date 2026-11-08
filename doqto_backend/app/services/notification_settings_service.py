"""Per-user notification preferences (batch 6): tones, vibrate, banner
previews, priority, reaction pushes, in-app sounds and haptics.

The row is optional — absent means defaults. The push pipeline reads the
effective values per recipient to pick `aps.sound`, the Android channel and
priority, and to drop reaction pushes the user turned off. Nothing here is
PHI; tone names are bundled resource names.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    NOTIFICATION_TONE_DEFAULT,
    PUSH_CHANNEL_GROUPS,
    PUSH_CHANNEL_MESSAGES,
)
from app.core.enums import ConversationType, VibratePattern
from app.models import UserNotificationSettings
from app.schemas.settings import NotificationSettingsOut, NotificationSettingsPatch

_FIELDS = (
    "messages_tone",
    "messages_vibrate",
    "messages_show_preview",
    "messages_high_priority",
    "groups_tone",
    "groups_vibrate",
    "groups_show_preview",
    "groups_high_priority",
    "reaction_notifications",
    "conversation_tones",
    "haptics",
)


@dataclass(frozen=True)
class PushPrefs:
    """What the push pipeline needs for one recipient + conversation kind."""

    sound: str | None  # APNs `aps.sound`: "default", "<tone>.caf", or None (silent)
    channel_id: str
    high_priority: bool
    reaction_notifications: bool


def apns_sound(tone: str | None) -> str | None:
    """Tone name → `aps.sound`. "default" is the system sound; "none" is a
    silent push (no sound key); anything else is a bundled CAF."""
    tone = tone or NOTIFICATION_TONE_DEFAULT
    if tone == NOTIFICATION_TONE_DEFAULT:
        return "default"
    if tone == "none":
        return None
    return f"{tone}.caf"


class NotificationSettingsService:
    @staticmethod
    async def has_org(user_id: uuid.UUID, db: AsyncSession) -> bool:
        """True when an unset banner-preview toggle should be OFF: the user is
        in an org and not every one of their orgs sets
        `show_preview_in_banners_default` (batch 7 policy). Kept under its
        historical name — every caller reads it as "previews default off"."""
        from app.services.compliance_service import PolicyService

        return not await PolicyService.banner_preview_default(user_id, db)

    @staticmethod
    async def get_row(user_id: uuid.UUID, db: AsyncSession) -> UserNotificationSettings | None:
        return await db.scalar(
            select(UserNotificationSettings).where(UserNotificationSettings.user_id == user_id)
        )

    @staticmethod
    def to_out(row: UserNotificationSettings | None, *, has_org: bool) -> NotificationSettingsOut:
        """Effective values. A preview toggle the user never set is OFF for a
        doctor in an org (a banner on a shared desk can show PHI) and on
        otherwise."""
        preview_default = not has_org
        if row is None:
            return NotificationSettingsOut(
                messages_tone=NOTIFICATION_TONE_DEFAULT,
                messages_vibrate=VibratePattern.DEFAULT,
                messages_show_preview=preview_default,
                messages_high_priority=True,
                groups_tone=NOTIFICATION_TONE_DEFAULT,
                groups_vibrate=VibratePattern.DEFAULT,
                groups_show_preview=preview_default,
                groups_high_priority=True,
                reaction_notifications=True,
                conversation_tones=True,
                haptics=True,
            )
        return NotificationSettingsOut(
            messages_tone=row.messages_tone,
            messages_vibrate=VibratePattern(row.messages_vibrate),
            messages_show_preview=(
                preview_default if row.messages_show_preview is None else row.messages_show_preview
            ),
            messages_high_priority=row.messages_high_priority,
            groups_tone=row.groups_tone,
            groups_vibrate=VibratePattern(row.groups_vibrate),
            groups_show_preview=(
                preview_default if row.groups_show_preview is None else row.groups_show_preview
            ),
            groups_high_priority=row.groups_high_priority,
            reaction_notifications=row.reaction_notifications,
            conversation_tones=row.conversation_tones,
            haptics=row.haptics,
        )

    @staticmethod
    async def effective(user_id: uuid.UUID, db: AsyncSession) -> NotificationSettingsOut:
        row = await NotificationSettingsService.get_row(user_id, db)
        has_org = await NotificationSettingsService.has_org(user_id, db)
        return NotificationSettingsService.to_out(row, has_org=has_org)

    @staticmethod
    async def update(
        *, user_id: uuid.UUID, body: NotificationSettingsPatch, db: AsyncSession
    ) -> tuple[NotificationSettingsOut, list[str]]:
        """Apply a partial update (or reset). Returns (effective, changed field
        names). Idempotent: unchanged values are not reported as changes."""
        row = await NotificationSettingsService.get_row(user_id, db)
        changed: list[str] = []
        if body.reset:
            if row is not None:
                await db.delete(row)
                await db.flush()
                changed.append("reset")
            row = None
        else:
            data = body.model_dump(exclude_unset=True, exclude={"reset"})
            if data:
                if row is None:
                    row = UserNotificationSettings(user_id=user_id)
                    db.add(row)
                    await db.flush()
                for field in _FIELDS:
                    if field in data and getattr(row, field) != data[field]:
                        setattr(row, field, data[field])
                        changed.append(field)
                await db.flush()
        has_org = await NotificationSettingsService.has_org(user_id, db)
        return NotificationSettingsService.to_out(row, has_org=has_org), changed

    # -- push pipeline -------------------------------------------------------- #
    @staticmethod
    async def push_prefs(
        *,
        user_id: uuid.UUID,
        conv_type: ConversationType | str | None,
        custom_tone: str | None,
        db: AsyncSession,
    ) -> PushPrefs:
        """Sound / channel / priority for one recipient. A per-chat
        `conversation_prefs.custom_tone` wins over the global tone."""
        row = await NotificationSettingsService.get_row(user_id, db)
        is_group = conv_type == ConversationType.GROUP
        if row is None:
            tone = NOTIFICATION_TONE_DEFAULT
            high = True
            reactions = True
        elif is_group:
            tone, high, reactions = row.groups_tone, row.groups_high_priority, row.reaction_notifications
        else:
            tone, high, reactions = (
                row.messages_tone,
                row.messages_high_priority,
                row.reaction_notifications,
            )
        if custom_tone:
            tone = custom_tone
        return PushPrefs(
            sound=apns_sound(tone),
            channel_id=PUSH_CHANNEL_GROUPS if is_group else PUSH_CHANNEL_MESSAGES,
            high_priority=high,
            reaction_notifications=reactions,
        )
