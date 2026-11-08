"""Loads a RelationshipContext for the pure permission module (A4).

First-degree edges live in Redis (`net:fd:{user}`), lazily rebuilt from
Postgres on a miss. Blocks, shared orgs, privacy and conversation state come
from indexed Postgres reads. Org networking policy is cached 60s.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Literal
from uuid import UUID

from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    MUTUAL_CONNECTIONS_DEFAULT_LIMIT,
    NET_FD_TTL_SECONDS,
    NET_SD_TTL_SECONDS,
    ORG_POLICY_CACHE_TTL_SECONDS,
    SECOND_DEGREE_LIMIT,
)
from app.core.enums import InvitationStatus
from app.core.permissions import PrivacySnapshot, RelationshipContext
from app.core.redis_keys import first_degree_key, org_policy_key, second_degree_key
from app.db.redis import get_redis
from app.models import (
    Block,
    Connection,
    ConnectionInvitation,
    Conversation,
    DirectConversationKey,
    Organization,
    OrgMember,
    User,
    UserPrivacySettings,
)

Degree = Literal[1, 2, "3+", "out"]

# A Redis set never persists when empty, so a zero-connection user would look
# like a cache miss forever. A sentinel member marks the set as materialised;
# it is filtered out on read.
_FD_SENTINEL = "\x00materialised"


def _pair_id(a: UUID, b: UUID) -> tuple[UUID, UUID]:
    return (a, b) if str(a) < str(b) else (b, a)


class RelationshipService:
    # -- first degree ----------------------------------------------------- #
    @staticmethod
    async def first_degree_ids(user_id: UUID, db: AsyncSession) -> set[UUID]:
        redis = await get_redis()
        key = first_degree_key(user_id)
        if await redis.exists(key):
            members = await redis.smembers(key)
            return {UUID(m) for m in members if m != _FD_SENTINEL}
        # Lazy rebuild from Postgres.
        rows = await db.scalars(
            select(Connection.connected_user_id).where(Connection.user_id == user_id)
        )
        ids = set(rows.all())
        await redis.sadd(key, _FD_SENTINEL, *[str(i) for i in ids])
        await redis.expire(key, NET_FD_TTL_SECONDS)
        return ids

    @staticmethod
    async def is_first_degree(user_id: UUID, other_id: UUID, db: AsyncSession) -> bool:
        return other_id in await RelationshipService.first_degree_ids(user_id, db)

    # -- second degree ---------------------------------------------------- #
    @staticmethod
    async def second_degree_ids(user_id: UUID, db: AsyncSession) -> set[UUID]:
        redis = await get_redis()
        key = second_degree_key(user_id)
        if await redis.exists(key):
            members = await redis.smembers(key)
            return {UUID(m) for m in members if m != _FD_SENTINEL}

        first = await RelationshipService.first_degree_ids(user_id, db)
        second: set[UUID] = set()
        if first:
            # Connections of my connections, capped.
            rows = await db.scalars(
                select(Connection.connected_user_id)
                .where(Connection.user_id.in_(first))
                .limit(SECOND_DEGREE_LIMIT * 4)
            )
            second = set(rows.all())
        blocked = await RelationshipService._blocked_ids(user_id, db)
        second -= first
        second.discard(user_id)
        second -= blocked
        second = set(list(second)[:SECOND_DEGREE_LIMIT])

        await redis.sadd(key, _FD_SENTINEL, *[str(i) for i in second])
        await redis.expire(key, NET_SD_TTL_SECONDS)
        return second

    # -- blocks ----------------------------------------------------------- #
    @staticmethod
    async def _blocked_ids(user_id: UUID, db: AsyncSession) -> set[UUID]:
        """Everyone in a block relationship with user_id (either direction)."""
        rows = await db.execute(
            select(Block.blocker_id, Block.blocked_id).where(
                or_(Block.blocker_id == user_id, Block.blocked_id == user_id)
            )
        )
        out: set[UUID] = set()
        for blocker, blocked in rows.all():
            out.add(blocked if blocker == user_id else blocker)
        return out

    @staticmethod
    async def is_blocked_either_way(a: UUID, b: UUID, db: AsyncSession) -> bool:
        row = await db.scalar(
            select(Block.id).where(
                or_(
                    (Block.blocker_id == a) & (Block.blocked_id == b),
                    (Block.blocker_id == b) & (Block.blocked_id == a),
                )
            )
        )
        return row is not None

    # -- shared orgs + policy --------------------------------------------- #
    @staticmethod
    async def _org_ids(user_id: UUID, db: AsyncSession) -> set[UUID]:
        rows = await db.scalars(select(OrgMember.org_id).where(OrgMember.user_id == user_id))
        return set(rows.all())

    @staticmethod
    async def _org_external_enabled(org_id: UUID, db: AsyncSession) -> bool:
        redis = await get_redis()
        cached = await redis.get(org_policy_key(org_id))
        if cached is not None:
            return cached == "1"
        val = await db.scalar(
            select(Organization.external_networking_enabled).where(Organization.id == org_id)
        )
        enabled = bool(val)
        await redis.setex(
            org_policy_key(org_id), ORG_POLICY_CACHE_TTL_SECONDS, "1" if enabled else "0"
        )
        return enabled

    @staticmethod
    async def _user_external_enabled(org_ids: set[UUID], db: AsyncSession) -> bool:
        """A user is externally enabled only if EVERY org they belong to allows
        it — the kill switch on any org gates that member."""
        for oid in org_ids:
            if not await RelationshipService._org_external_enabled(oid, db):
                return False
        return True

    # -- privacy ---------------------------------------------------------- #
    @staticmethod
    async def privacy(user_id: UUID, db: AsyncSession) -> PrivacySnapshot:
        """Effective privacy settings (defaults when no row exists)."""
        return await RelationshipService._privacy(user_id, db)

    @staticmethod
    async def _privacy(user_id: UUID, db: AsyncSession) -> PrivacySnapshot:
        row = await db.scalar(
            select(UserPrivacySettings).where(UserPrivacySettings.user_id == user_id)
        )
        if row is None:
            return PrivacySnapshot()
        return PrivacySnapshot(
            invite_policy=row.invite_policy,
            dm_policy=row.dm_policy,
            discoverability=row.discoverability,
            show_mutual_connections=row.show_mutual_connections,
            last_seen_visibility=row.last_seen_visibility,
            online_visibility=row.online_visibility,
            profile_photo_visibility=row.profile_photo_visibility,
            about_visibility=row.about_visibility,
            read_receipts=row.read_receipts,
        )

    # -- context ---------------------------------------------------------- #
    @staticmethod
    async def load_context(
        viewer_id: UUID, target_id: UUID, db: AsyncSession
    ) -> RelationshipContext:
        is_first = await RelationshipService.is_first_degree(viewer_id, target_id, db)
        blocked = await RelationshipService.is_blocked_either_way(viewer_id, target_id, db)

        viewer_orgs = await RelationshipService._org_ids(viewer_id, db)
        target_orgs = await RelationshipService._org_ids(target_id, db)
        shared = viewer_orgs & target_orgs

        external_both = await RelationshipService._user_external_enabled(
            viewer_orgs, db
        ) and await RelationshipService._user_external_enabled(target_orgs, db)

        viewer_privacy = await RelationshipService._privacy(viewer_id, db)
        target_privacy = await RelationshipService._privacy(target_id, db)

        pending = await db.scalar(
            select(ConnectionInvitation.id).where(
                ConnectionInvitation.status == InvitationStatus.PENDING,
                or_(
                    (ConnectionInvitation.sender_id == viewer_id)
                    & (ConnectionInvitation.recipient_id == target_id),
                    (ConnectionInvitation.sender_id == target_id)
                    & (ConnectionInvitation.recipient_id == viewer_id),
                ),
            )
        )

        shared_group_dm = await RelationshipService._shared_group_dm_mode(
            viewer_id, target_id, db
        )

        lo, hi = _pair_id(viewer_id, target_id)
        access = await db.scalar(
            select(Conversation.access)
            .join(
                DirectConversationKey,
                DirectConversationKey.conversation_id == Conversation.id,
            )
            .where(DirectConversationKey.user_lo == lo, DirectConversationKey.user_hi == hi)
        )

        target_created = await db.scalar(
            select(User.created_at).where(User.id == target_id)
        )
        age_days = 0
        if target_created is not None:
            now = datetime.now(timezone.utc)
            age_days = max(0, (now - target_created).days)

        return RelationshipContext(
            viewer_id=viewer_id,
            target_id=target_id,
            shared_org_ids=frozenset(shared),
            is_first_degree=is_first,
            is_blocked_either_way=blocked,
            viewer_privacy=viewer_privacy,
            target_privacy=target_privacy,
            external_networking_enabled_for_both=external_both,
            target_account_age_days=age_days,
            has_pending_invitation=pending is not None,
            existing_conversation_access=access,
            shared_group_dm_mode=shared_group_dm,
        )

    # -- shared groups (M5 member_dm_policy) ------------------------------- #
    _GROUP_DM_RANK = {"open": 2, "request": 1, "denied": 0}

    @staticmethod
    async def _shared_group_dm_mode(
        viewer_id: UUID, target_id: UUID, db: AsyncSession
    ) -> str | None:
        """The most permissive member_dm_policy verdict across every group both
        users are ACTIVE members of; None when they share none. Imported lazily:
        group_service depends on this module."""
        from app.core.enums import GroupMemberState
        from app.models import Group, GroupMember
        from app.services.group_service import GroupService

        mine = GroupMember.__table__.alias("mine")
        theirs = GroupMember.__table__.alias("theirs")
        rows = await db.execute(
            select(Group)
            .join(mine, mine.c.group_id == Group.id)
            .join(theirs, theirs.c.group_id == Group.id)
            .where(
                mine.c.user_id == viewer_id,
                mine.c.state == GroupMemberState.ACTIVE,
                theirs.c.user_id == target_id,
                theirs.c.state == GroupMemberState.ACTIVE,
            )
        )
        best: str | None = None
        for group in rows.scalars().all():
            mode = await GroupService.group_dm_decision(
                group=group, actor_id=viewer_id, target_id=target_id, db=db
            )
            if best is None or RelationshipService._GROUP_DM_RANK[mode] > (
                RelationshipService._GROUP_DM_RANK[best]
            ):
                best = mode
        return best

    # -- mutual + degree -------------------------------------------------- #
    @staticmethod
    async def mutual_connections(
        a: UUID, b: UUID, db: AsyncSession, limit: int = MUTUAL_CONNECTIONS_DEFAULT_LIMIT
    ) -> list[UUID]:
        fd_a = await RelationshipService.first_degree_ids(a, db)
        fd_b = await RelationshipService.first_degree_ids(b, db)
        mutual = sorted(fd_a & fd_b, key=str)
        return mutual[:limit]

    @staticmethod
    async def degree_of(viewer: UUID, target: UUID, db: AsyncSession) -> Degree:
        if viewer == target:
            return "out"
        if await RelationshipService.is_blocked_either_way(viewer, target, db):
            return "out"
        if await RelationshipService.is_first_degree(viewer, target, db):
            return 1
        if target in await RelationshipService.second_degree_ids(viewer, db):
            return 2
        return "3+"

    # -- cache maintenance (called by connection_service on edge changes) - #
    @staticmethod
    async def add_edge_cache(a: UUID, b: UUID) -> None:
        redis = await get_redis()
        await redis.sadd(first_degree_key(a), _FD_SENTINEL, str(b))
        await redis.expire(first_degree_key(a), NET_FD_TTL_SECONDS)
        await redis.sadd(first_degree_key(b), _FD_SENTINEL, str(a))
        await redis.expire(first_degree_key(b), NET_FD_TTL_SECONDS)
        await RelationshipService.invalidate_second_degree(a, b)

    @staticmethod
    async def remove_edge_cache(a: UUID, b: UUID) -> None:
        redis = await get_redis()
        await redis.srem(first_degree_key(a), str(b))
        await redis.srem(first_degree_key(b), str(a))
        await RelationshipService.invalidate_second_degree(a, b)

    @staticmethod
    async def invalidate_second_degree(*user_ids: UUID) -> None:
        redis = await get_redis()
        for uid in user_ids:
            await redis.delete(second_degree_key(uid))
