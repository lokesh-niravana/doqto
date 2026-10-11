"""In-app notification feed + fanout (M1).

A notification is a DB row (created inside the caller's transaction) plus a
best-effort delivery signal: a WS NOTIFICATION_CREATED envelope to the owner
and, for push-worthy types, a presence-gated push.

payload is PHI-FREE — names and counts only, never message content. `actor_name`
is directory data (a doctor's name), explicitly allowed.
"""
from __future__ import annotations

from typing import Any
from uuid import UUID

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.enums import WsEventServer
from app.models import Notification
from app.services.push_service import PushService

# Notification `type` values (backend-defined; client renders by type).
TYPE_INVITATION_RECEIVED = "invitation_received"
TYPE_INVITATION_ACCEPTED = "invitation_accepted"
# Groups (M5) — badge-only feed types; group_service fans out the specific WS
# event itself, so these stay out of _PUSH_WORTHY (no push in M5).
TYPE_GROUP_INVITE_RECEIVED = "group_invite_received"

# Someone you invited by NPI finished registering; you are now connected.
TYPE_INVITE_JOINED = "invite_joined"

_PUSH_WORTHY = {TYPE_INVITATION_RECEIVED, TYPE_INVITATION_ACCEPTED, TYPE_INVITE_JOINED}


class NotificationService:
    @staticmethod
    async def create(
        *,
        db: AsyncSession,
        user_id: UUID,
        type: str,
        actor_id: UUID | None = None,
        subject_type: str | None = None,
        subject_id: UUID | None = None,
        payload: dict[str, Any] | None = None,
    ) -> Notification:
        """Insert the row (in the caller's transaction) and return it. Call
        publish() AFTER commit to fan out."""
        row = Notification(
            user_id=user_id,
            type=type,
            actor_id=actor_id,
            subject_type=subject_type,
            subject_id=subject_id,
            payload=payload or {},
        )
        db.add(row)
        await db.flush()
        return row

    @staticmethod
    async def publish(*, notification: Notification, unread_count: int) -> None:
        """Post-commit fanout: WS signal + push for push-worthy types."""
        await ws_manager.publish_to_users(
            [notification.user_id],
            WsEventServer.NOTIFICATION_CREATED,
            {
                "notification_id": str(notification.id),
                "type": notification.type,
                "unread_count": unread_count,
            },
        )
        if notification.type not in _PUSH_WORTHY:
            return
        actor_name = notification.payload.get("actor_name") if notification.payload else None
        if not actor_name:
            return
        if notification.type == TYPE_INVITATION_RECEIVED:
            PushService.notify_invitation_received(
                recipient_id=notification.user_id,
                actor_name=actor_name,
                invitation_id=notification.subject_id or notification.id,
            )
        elif notification.type == TYPE_INVITATION_ACCEPTED:
            PushService.notify_invitation_accepted(
                recipient_id=notification.user_id, actor_name=actor_name
            )
        elif notification.type == TYPE_INVITE_JOINED:
            PushService.notify_invite_joined(
                recipient_id=notification.user_id,
                actor_name=actor_name,
                user_id=notification.subject_id,
            )

    @staticmethod
    async def unread_count(*, db: AsyncSession, user_id: UUID) -> int:
        return (
            await db.scalar(
                select(func.count())
                .select_from(Notification)
                .where(Notification.user_id == user_id, Notification.read_at.is_(None))
            )
        ) or 0

    @staticmethod
    async def list(
        *,
        db: AsyncSession,
        user_id: UUID,
        unread_only: bool = False,
        cursor: Any = None,
        limit: int = 30,
    ) -> list[Notification]:
        stmt = select(Notification).where(Notification.user_id == user_id)
        if unread_only:
            stmt = stmt.where(Notification.read_at.is_(None))
        if cursor is not None:
            stmt = stmt.where(Notification.created_at < cursor)
        stmt = stmt.order_by(Notification.created_at.desc()).limit(limit)
        rows = await db.scalars(stmt)
        return list(rows.all())

    @staticmethod
    async def mark_read(
        *,
        db: AsyncSession,
        user_id: UUID,
        ids: list[UUID] | None = None,
        mark_all: bool = False,
    ) -> None:
        stmt = (
            update(Notification)
            .where(Notification.user_id == user_id, Notification.read_at.is_(None))
            .values(read_at=func.now())
        )
        if not mark_all:
            stmt = stmt.where(Notification.id.in_(ids or []))
        await db.execute(stmt)
        await db.flush()
