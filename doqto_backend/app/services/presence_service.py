"""Presence + last seen (batch 2).

Live state lives in Redis (`presence:{user}` = online|away, TTL'd); the
durable `users.last_seen_at` is written at most once per
LAST_SEEN_WRITE_INTERVAL_SECONDS while a socket is alive and always on
disconnect. `presence_update` fans out to the user's AUDIENCE — first-degree
connections ∪ members of every org they belong to — filtered by the user's own
visibility (hidden → no event at all) and by the reciprocal rule (a recipient
who hides their own last seen receives nobody's).

Reads go through `snapshot_for`, which applies the same rules per target so a
hidden doctor is indistinguishable from an offline stranger.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.constants import LAST_SEEN_WRITE_INTERVAL_SECONDS
from app.core.enums import LastSeenVisibility, OnlineVisibility, PresenceStatus, WsEventServer
from app.core.permissions import can_see_last_seen, can_see_online
from app.core.redis_keys import last_seen_throttle_key, presence_key
from app.db.redis import get_redis
from app.models import OrgMember, User, UserPrivacySettings
from app.schemas.privacy import PresenceOut
from app.services.relationship_service import RelationshipService


class PresenceService:
    # -- audience ----------------------------------------------------------- #
    @staticmethod
    async def audience(user_id: uuid.UUID, db: AsyncSession) -> list[uuid.UUID]:
        """Everyone who renders this user from a cache: first-degree
        connections ∪ members of every org the user belongs to, minus the user."""
        first_degree = await RelationshipService.first_degree_ids(user_id, db)
        my_orgs = select(OrgMember.org_id).where(OrgMember.user_id == user_id)
        colleagues = await db.scalars(
            select(OrgMember.user_id).where(OrgMember.org_id.in_(my_orgs)).distinct()
        )
        out = {*first_degree, *colleagues.all()}
        out.discard(user_id)
        return list(out)

    @staticmethod
    async def _presence_recipients(user_id: uuid.UUID, db: AsyncSession) -> list[uuid.UUID]:
        """The audience, minus everyone the user's own settings hide presence
        from and everyone who hides their own (reciprocal rule)."""
        mine = await RelationshipService.privacy(user_id, db)
        if (
            mine.last_seen_visibility == LastSeenVisibility.NOBODY
            or mine.online_visibility == OnlineVisibility.NOBODY
        ):
            return []
        recipients = await PresenceService.audience(user_id, db)
        if not recipients:
            return []
        hiding = await db.scalars(
            select(UserPrivacySettings.user_id).where(
                UserPrivacySettings.user_id.in_(recipients),
                UserPrivacySettings.last_seen_visibility == LastSeenVisibility.NOBODY.value,
            )
        )
        hidden = set(hiding.all())
        # Blocked pairs are not connected and a block tears the edge down, but
        # colleagues can still block each other: drop them too.
        blocked = await RelationshipService._blocked_ids(user_id, db)
        return [r for r in recipients if r not in hidden and r not in blocked]

    # -- writes --------------------------------------------------------------- #
    @staticmethod
    async def touch_last_seen(
        user_id: uuid.UUID, db: AsyncSession, *, force: bool = False
    ) -> datetime | None:
        """Stamp users.last_seen_at = now, throttled through Redis unless
        forced (disconnect). Returns the stamp written, or None when skipped."""
        redis = await get_redis()
        if not force:
            fresh = await redis.set(
                last_seen_throttle_key(user_id), "1", ex=LAST_SEEN_WRITE_INTERVAL_SECONDS, nx=True
            )
            if not fresh:
                return None
        now = datetime.now(tz=timezone.utc)
        await db.execute(update(User).where(User.id == user_id).values(last_seen_at=now))
        await db.commit()
        if force:
            await redis.delete(last_seen_throttle_key(user_id))
        return now

    @staticmethod
    async def publish(
        user_id: uuid.UUID,
        status: PresenceStatus,
        db: AsyncSession,
        *,
        last_seen_at: datetime | None = None,
    ) -> None:
        recipients = await PresenceService._presence_recipients(user_id, db)
        if not recipients:
            return
        await ws_manager.publish_to_users(
            recipients,
            WsEventServer.PRESENCE_UPDATE,
            {
                "user_id": str(user_id),
                "status": status.value,
                "last_seen_at": last_seen_at.isoformat() if last_seen_at else None,
            },
        )

    # -- reads ---------------------------------------------------------------- #
    @staticmethod
    async def snapshot_for(
        viewer_id: uuid.UUID, target_ids: list[uuid.UUID], db: AsyncSession
    ) -> list[PresenceOut]:
        """Presence of each target AS THE VIEWER MAY SEE IT. Unknown ids are
        omitted; hidden ones read offline with no last_seen_at."""
        if not target_ids:
            return []
        rows = await db.execute(
            select(User.id, User.last_seen_at).where(
                User.id.in_(target_ids), User.deleted_at.is_(None)
            )
        )
        last_seen = dict(rows.all())
        redis = await get_redis()
        out: list[PresenceOut] = []
        for tid in target_ids:
            if tid not in last_seen:
                continue
            ctx = await RelationshipService.load_context(viewer_id, tid, db)
            status = PresenceStatus.OFFLINE
            seen: datetime | None = None
            if can_see_online(ctx):
                raw = await redis.get(presence_key(tid))
                if raw in (PresenceStatus.ONLINE.value, PresenceStatus.AWAY.value):
                    status = PresenceStatus(raw)
            if can_see_last_seen(ctx):
                seen = last_seen[tid]
            out.append(PresenceOut(user_id=tid, status=status, last_seen_at=seen))
        return out
