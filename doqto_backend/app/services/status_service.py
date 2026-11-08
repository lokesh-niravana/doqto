"""Status under the name + account info export (batch 6).

Status: `users.status_text` holds a StatusPreset wire value or custom text
(≤ 40 chars), with an optional expiry the settings loop enforces. It is
directory data (like a headline), shown on the public profile and in presence
snapshots; it is never message content.

Export: a JSON of the user's own profile, settings, connections and groups —
NO messages — uploaded to S3 and handed back as a 10-minute presigned URL.
Audited (ACCOUNT_EXPORTED).
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.constants import EXPORT_URL_TTL_SEC
from app.core.enums import GroupMemberState, WsEventServer
from app.models import (
    Connection,
    Group,
    GroupMember,
    Organization,
    OrgMember,
    User,
    UserPrivacySettings,
)
from app.schemas.settings import StatusOut, StatusPatch, split_status
from app.services.file_service import FileService
from app.services.notification_settings_service import NotificationSettingsService
from app.services.presence_service import PresenceService


def _now() -> datetime:
    return datetime.now(tz=timezone.utc)


class StatusService:
    @staticmethod
    def to_out(user: User) -> StatusOut:
        preset, text = split_status(user.status_text)
        return StatusOut(
            status_preset=preset, status_text=text, status_expires_at=user.status_expires_at
        )

    @staticmethod
    def is_live(user: User, now: datetime | None = None) -> bool:
        if user.status_text is None:
            return False
        if user.status_expires_at is None:
            return True
        return user.status_expires_at > (now or _now())

    @staticmethod
    async def update(*, user: User, body: StatusPatch, db: AsyncSession) -> bool:
        """Apply the patch. Returns whether anything changed (idempotent)."""
        if body.preset is not None:
            new_text: str | None = body.preset.value
        else:
            new_text = body.text
        new_expiry = (
            None
            if new_text is None or body.expires_in_sec is None
            else _now() + timedelta(seconds=body.expires_in_sec)
        )
        if user.status_text == new_text and (
            new_text is None or (user.status_expires_at is None and new_expiry is None)
        ):
            return False
        user.status_text = new_text
        user.status_expires_at = new_expiry
        await db.flush()
        return True

    @staticmethod
    async def publish(user_id: uuid.UUID, db: AsyncSession) -> None:
        """Post-commit: the audience re-fetches the profile (`profile_updated`
        already means "something you render about this doctor changed")."""
        recipients = await PresenceService.audience(user_id, db)
        if recipients:
            await ws_manager.publish_to_users(
                recipients, WsEventServer.PROFILE_UPDATED, {"user_id": str(user_id)}
            )

    @staticmethod
    async def expire(db: AsyncSession) -> list[uuid.UUID]:
        """Loop job: clear statuses past their expiry. Returns the users."""
        rows = (
            await db.scalars(
                select(User).where(
                    User.status_text.is_not(None), User.status_expires_at <= _now()
                )
            )
        ).all()
        for user in rows:
            user.status_text = None
            user.status_expires_at = None
        if rows:
            await db.flush()
        return [u.id for u in rows]


class ExportService:
    @staticmethod
    def key_for(user_id: uuid.UUID) -> str:
        return f"exports/{user_id}/{uuid.uuid4().hex}.json"

    @staticmethod
    async def build(*, user: User, db: AsyncSession) -> dict:
        """Everything the user may take with them that is theirs alone. No
        messages, no other doctor's contact details — names and ids only."""
        privacy = await db.scalar(
            select(UserPrivacySettings).where(UserPrivacySettings.user_id == user.id)
        )
        notifications = await NotificationSettingsService.effective(user.id, db)
        conn_rows = await db.execute(
            select(User.id, User.full_name, User.specialty, Connection.created_at)
            .join(Connection, Connection.connected_user_id == User.id)
            .where(Connection.user_id == user.id)
            .order_by(Connection.created_at)
        )
        group_rows = await db.execute(
            select(Group.id, Group.name, GroupMember.role, GroupMember.joined_at)
            .join(GroupMember, GroupMember.group_id == Group.id)
            .where(
                GroupMember.user_id == user.id,
                GroupMember.state == GroupMemberState.ACTIVE.value,
            )
            .order_by(GroupMember.joined_at)
        )
        org_rows = await db.execute(
            select(Organization.id, Organization.name, OrgMember.org_role, OrgMember.joined_at)
            .join(OrgMember, OrgMember.org_id == Organization.id)
            .where(OrgMember.user_id == user.id)
        )
        status = StatusService.to_out(user)

        def iso(d: datetime | None) -> str | None:
            return d.isoformat() if d else None

        return {
            "exported_at": _now().isoformat(),
            "profile": {
                "id": str(user.id),
                "full_name": user.full_name,
                "phone": user.phone,
                "email": user.email,
                "npi_number": user.npi_number,
                "handle": user.handle,
                "headline": user.headline,
                "specialty": user.specialty,
                "bio": user.bio,
                "city": user.city,
                "state": user.state,
                "years_of_experience": user.years_of_experience,
                "skills": list(user.skills or []),
                "status": status.model_dump(mode="json"),
                "created_at": iso(user.created_at),
            },
            "settings": {
                "privacy": (
                    {
                        "invite_policy": privacy.invite_policy,
                        "dm_policy": privacy.dm_policy,
                        "discoverability": privacy.discoverability,
                        "show_mutual_connections": privacy.show_mutual_connections,
                        "last_seen_visibility": privacy.last_seen_visibility,
                        "online_visibility": privacy.online_visibility,
                        "profile_photo_visibility": privacy.profile_photo_visibility,
                        "about_visibility": privacy.about_visibility,
                        "read_receipts": privacy.read_receipts,
                        "default_disappear_sec": privacy.default_disappear_sec,
                        "link_previews": privacy.link_previews,
                    }
                    if privacy is not None
                    else None
                ),
                "notifications": notifications.model_dump(mode="json"),
                "two_step_pin_enabled": user.pin_hash is not None,
            },
            "organizations": [
                {"id": str(oid), "name": name, "role": role, "joined_at": iso(joined)}
                for oid, name, role, joined in org_rows.all()
            ],
            "connections": [
                {
                    "user_id": str(uid),
                    "full_name": name,
                    "specialty": spec,
                    "connected_at": iso(since),
                }
                for uid, name, spec, since in conn_rows.all()
            ],
            "groups": [
                {"id": str(gid), "name": name, "role": role, "joined_at": iso(joined)}
                for gid, name, role, joined in group_rows.all()
            ],
        }

    @staticmethod
    async def upload(*, user: User, db: AsyncSession) -> tuple[str, datetime]:
        data = await ExportService.build(user=user, db=db)
        key = ExportService.key_for(user.id)
        await FileService.upload_bytes(
            key=key,
            data=json.dumps(data, indent=2, ensure_ascii=False).encode(),
            content_type="application/json",
        )
        url = await FileService.presigned_url(key=key, expires_in=EXPORT_URL_TTL_SEC)
        return url, _now() + timedelta(seconds=EXPORT_URL_TTL_SEC)
