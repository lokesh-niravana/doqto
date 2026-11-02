"""Connection lifecycle: invite / accept / ignore / withdraw / remove / block /
mute / report (M1).

Every mutation is audit-logged. Blocks are silent (the caller surfaces a
generic `user_unavailable`). First-degree Redis sets and second-degree caches
are maintained on every edge change. Quotas and cooldowns gate invitations.
"""
from __future__ import annotations

import math
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import Request
from sqlalchemy import delete, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core import constants
from app.core.enums import AuditAction, InvitationStatus
from app.services.relationship_service import RelationshipService, _pair_id
from app.core.permissions import can_send_invitation
from app.models import (
    Block,
    Connection,
    ConnectionInvitation,
    ConnectionRemoval,
    Mute,
    Report,
    User,
)
from app.services.audit_service import AuditService
from app.services.notification_service import (
    TYPE_INVITATION_ACCEPTED,
    TYPE_INVITATION_RECEIVED,
    NotificationService,
)
from app.api.ws_manager import ws_manager
from app.core.enums import WsEventServer


class ConnectionError(Exception):
    def __init__(
        self, code: str, *, status_code: int = 400, retry_after_days: int | None = None
    ) -> None:
        super().__init__(code)
        self.code = code
        self.status_code = status_code
        self.retry_after_days = retry_after_days


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _days_remaining(event_time: datetime, window_days: int) -> int:
    """Whole days left in a cooldown window (>=1 while active, 0 if elapsed)."""
    if event_time.tzinfo is None:
        event_time = event_time.replace(tzinfo=timezone.utc)
    end = event_time + timedelta(days=window_days)
    now = _now()
    if now >= end:
        return 0
    return max(1, math.ceil((end - now).total_seconds() / 86400))


class ConnectionService:
    # ------------------------------------------------------------------ #
    # Invitations
    # ------------------------------------------------------------------ #
    @staticmethod
    async def invite(
        *,
        request: Request,
        sender: User,
        recipient_id: uuid.UUID,
        message: str | None,
        db: AsyncSession,
    ) -> tuple[str, ConnectionInvitation | Connection]:
        """Returns ('invited', invitation) or ('connected', connection) when a
        reciprocal pending invitation auto-accepts."""
        if recipient_id == sender.id:
            raise ConnectionError("cannot_invite_self")

        recipient = await db.scalar(select(User).where(User.id == recipient_id))
        if recipient is None:
            # Silence rule: unknown target is indistinguishable from a block.
            raise ConnectionError("user_unavailable", status_code=404)

        ctx = await RelationshipService.load_context(sender.id, recipient_id, db)

        # 1. Block check (silent).
        if ctx.is_blocked_either_way:
            raise ConnectionError("user_unavailable", status_code=404)

        # 2. Reciprocal pending → auto-accept instead of a duplicate edge.
        reciprocal = await db.scalar(
            select(ConnectionInvitation).where(
                ConnectionInvitation.sender_id == recipient_id,
                ConnectionInvitation.recipient_id == sender.id,
                ConnectionInvitation.status == InvitationStatus.PENDING,
            )
        )
        if reciprocal is not None:
            connection = await ConnectionService._accept_locked(
                request=request, acceptor=sender, invitation=reciprocal, db=db
            )
            return ("connected", connection)

        # 3. Permission (spec §6.3).
        decision = can_send_invitation(ctx)
        if not decision.allowed:
            if decision.reason == "already_connected":
                raise ConnectionError("already_connected", status_code=409)
            if decision.reason == "invitation_exists":
                raise ConnectionError("invitation_exists", status_code=409)
            if decision.reason == "networking_disabled":
                await AuditService.log_request(
                    request,
                    user_id=sender.id,
                    action=AuditAction.NETWORKING_POLICY_DENIED,
                    resource_type="user",
                    resource_id=recipient_id,
                    db=db,
                    metadata={"path": "invite", "reason": decision.reason},
                )
                await db.commit()
                raise ConnectionError("networking_disabled", status_code=403)
            # invite-policy denials → generic policy 403.
            raise ConnectionError("networking_not_allowed", status_code=403)

        # 4. Quotas (two stacked windows) — raise generic 429 rate_limited.
        from app.core.rate_limit import enforce_rate_limit

        await enforce_rate_limit(
            sender.id, "send_invitation_day", constants.INVITE_QUOTA_PER_DAY, 86400
        )
        await enforce_rate_limit(
            sender.id, "send_invitation_week", constants.INVITE_QUOTA_PER_WEEK, 604800
        )

        # 5. Cooldowns (ignored 21d / withdrawn 3d / removed 30d).
        await ConnectionService._assert_no_cooldown(sender.id, recipient_id, db)

        # 6. Create the pending invitation.
        invitation = ConnectionInvitation(
            sender_id=sender.id, recipient_id=recipient_id, message=message
        )
        db.add(invitation)
        try:
            await db.flush()
        except IntegrityError as e:
            await db.rollback()
            raise ConnectionError("invitation_exists", status_code=409) from e

        await AuditService.log_request(
            request,
            user_id=sender.id,
            action=AuditAction.INVITATION_SENT,
            resource_type="connection_invitation",
            resource_id=invitation.id,
            db=db,
        )
        notif = await NotificationService.create(
            db=db,
            user_id=recipient_id,
            type=TYPE_INVITATION_RECEIVED,
            actor_id=sender.id,
            subject_type="invitation",
            subject_id=invitation.id,
            payload={"actor_name": sender.full_name},
        )
        unread = await NotificationService.unread_count(db=db, user_id=recipient_id)
        await db.commit()

        # Post-commit fanout.
        await ws_manager.publish_to_users(
            [recipient_id],
            WsEventServer.INVITATION_RECEIVED,
            {
                "invitation_id": str(invitation.id),
                "sender_id": str(sender.id),
                "sender_name": sender.full_name,
            },
        )
        await NotificationService.publish(notification=notif, unread_count=unread)
        return ("invited", invitation)

    @staticmethod
    async def _assert_no_cooldown(
        sender_id: uuid.UUID, recipient_id: uuid.UUID, db: AsyncSession
    ) -> None:
        lo, hi = _pair_id(sender_id, recipient_id)

        ignored = await db.scalar(
            select(ConnectionInvitation.responded_at)
            .where(
                ConnectionInvitation.sender_id == sender_id,
                ConnectionInvitation.recipient_id == recipient_id,
                ConnectionInvitation.status == InvitationStatus.IGNORED,
            )
            .order_by(ConnectionInvitation.responded_at.desc())
            .limit(1)
        )
        withdrawn = await db.scalar(
            select(ConnectionInvitation.responded_at)
            .where(
                ConnectionInvitation.sender_id == sender_id,
                ConnectionInvitation.recipient_id == recipient_id,
                ConnectionInvitation.status == InvitationStatus.WITHDRAWN,
            )
            .order_by(ConnectionInvitation.responded_at.desc())
            .limit(1)
        )
        removed = await db.scalar(
            select(ConnectionRemoval.removed_at)
            .where(ConnectionRemoval.user_a == lo, ConnectionRemoval.user_b == hi)
            .order_by(ConnectionRemoval.removed_at.desc())
            .limit(1)
        )

        remaining = 0
        if ignored is not None:
            remaining = max(remaining, _days_remaining(ignored, constants.COOLDOWN_IGNORED_DAYS))
        if withdrawn is not None:
            remaining = max(
                remaining, _days_remaining(withdrawn, constants.COOLDOWN_WITHDRAWN_DAYS)
            )
        if removed is not None:
            remaining = max(remaining, _days_remaining(removed, constants.COOLDOWN_REMOVED_DAYS))
        if remaining > 0:
            raise ConnectionError(
                "rate_limited", status_code=429, retry_after_days=remaining
            )

    @staticmethod
    async def accept(
        *, request: Request, user: User, invitation_id: uuid.UUID, db: AsyncSession
    ) -> Connection:
        invitation = await db.scalar(
            select(ConnectionInvitation).where(ConnectionInvitation.id == invitation_id)
        )
        if invitation is None or invitation.recipient_id != user.id:
            raise ConnectionError("invitation_not_found", status_code=404)
        if invitation.status != InvitationStatus.PENDING:
            raise ConnectionError("invitation_not_pending", status_code=409)
        connection = await ConnectionService._accept_locked(
            request=request, acceptor=user, invitation=invitation, db=db
        )
        return connection

    @staticmethod
    async def _accept_locked(
        *,
        request: Request,
        acceptor: User,
        invitation: ConnectionInvitation,
        db: AsyncSession,
    ) -> Connection:
        """Form the connection + close the invitation in one transaction, then
        fan out. `acceptor` is the user accepting (the invitation's recipient)."""
        a = invitation.sender_id
        b = invitation.recipient_id
        pair = uuid.uuid4()
        row_ab = Connection(user_id=a, connected_user_id=b, pair_id=pair)
        row_ba = Connection(user_id=b, connected_user_id=a, pair_id=pair)
        db.add_all([row_ab, row_ba])
        invitation.status = InvitationStatus.ACCEPTED
        invitation.responded_at = _now()
        try:
            await db.flush()
        except IntegrityError:
            # Already connected (race) — idempotent success.
            await db.rollback()
            invitation.status = InvitationStatus.ACCEPTED
            invitation.responded_at = _now()
            await db.flush()
            existing = await db.scalar(
                select(Connection).where(
                    Connection.user_id == a, Connection.connected_user_id == b
                )
            )
            await db.commit()
            return existing

        await AuditService.log_request(
            request,
            user_id=acceptor.id,
            action=AuditAction.INVITATION_ACCEPTED,
            resource_type="connection_invitation",
            resource_id=invitation.id,
            db=db,
        )
        # Notify the ORIGINAL sender (a) that acceptor accepted.
        notif = await NotificationService.create(
            db=db,
            user_id=invitation.sender_id,
            type=TYPE_INVITATION_ACCEPTED,
            actor_id=acceptor.id,
            subject_type="invitation",
            subject_id=invitation.id,
            payload={"actor_name": acceptor.full_name},
        )
        unread = await NotificationService.unread_count(db=db, user_id=invitation.sender_id)
        await db.commit()

        # Redis edge cache + second-degree invalidation.
        await RelationshipService.add_edge_cache(a, b)
        # WS to the original sender.
        await ws_manager.publish_to_users(
            [invitation.sender_id],
            WsEventServer.INVITATION_ACCEPTED,
            {
                "invitation_id": str(invitation.id),
                "user_id": str(acceptor.id),
                "user_name": acceptor.full_name,
            },
        )
        await NotificationService.publish(notification=notif, unread_count=unread)
        return row_ab

    @staticmethod
    async def ignore(
        *, request: Request, user: User, invitation_id: uuid.UUID, db: AsyncSession
    ) -> None:
        invitation = await db.scalar(
            select(ConnectionInvitation).where(ConnectionInvitation.id == invitation_id)
        )
        if invitation is None or invitation.recipient_id != user.id:
            raise ConnectionError("invitation_not_found", status_code=404)
        if invitation.status != InvitationStatus.PENDING:
            raise ConnectionError("invitation_not_pending", status_code=409)
        invitation.status = InvitationStatus.IGNORED
        invitation.responded_at = _now()
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.INVITATION_IGNORED,
            resource_type="connection_invitation",
            resource_id=invitation.id,
            db=db,
        )
        await db.commit()
        # SILENT: no notification, no WS to sender.

    @staticmethod
    async def withdraw(
        *, request: Request, user: User, invitation_id: uuid.UUID, db: AsyncSession
    ) -> None:
        invitation = await db.scalar(
            select(ConnectionInvitation).where(ConnectionInvitation.id == invitation_id)
        )
        if invitation is None or invitation.sender_id != user.id:
            raise ConnectionError("invitation_not_found", status_code=404)
        if invitation.status != InvitationStatus.PENDING:
            raise ConnectionError("invitation_not_pending", status_code=409)
        invitation.status = InvitationStatus.WITHDRAWN
        invitation.responded_at = _now()
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.INVITATION_WITHDRAWN,
            resource_type="connection_invitation",
            resource_id=invitation.id,
            db=db,
        )
        await db.commit()
        # Sync the recipient's inbox (no notification/push — silent).
        await ws_manager.publish_to_users(
            [invitation.recipient_id],
            WsEventServer.INVITATION_WITHDRAWN,
            {"invitation_id": str(invitation.id), "sender_id": str(user.id)},
        )

    # ------------------------------------------------------------------ #
    # Connections
    # ------------------------------------------------------------------ #
    @staticmethod
    async def remove_connection(
        *, request: Request, user: User, other_id: uuid.UUID, db: AsyncSession
    ) -> None:
        row = await db.scalar(
            select(Connection).where(
                Connection.user_id == user.id, Connection.connected_user_id == other_id
            )
        )
        if row is None:
            raise ConnectionError("not_connected", status_code=404)
        pair_id = row.pair_id
        await db.execute(
            delete(Connection).where(
                or_(
                    (Connection.user_id == user.id)
                    & (Connection.connected_user_id == other_id),
                    (Connection.user_id == other_id)
                    & (Connection.connected_user_id == user.id),
                )
            )
        )
        lo, hi = _pair_id(user.id, other_id)
        db.add(
            ConnectionRemoval(
                pair_id=pair_id, removed_by=user.id, user_a=lo, user_b=hi
            )
        )
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.CONNECTION_REMOVED,
            resource_type="user",
            resource_id=other_id,
            db=db,
        )
        await db.commit()
        await RelationshipService.remove_edge_cache(user.id, other_id)
        # Sync the other party's graph view (no notification/push — silent).
        await ws_manager.publish_to_users(
            [other_id], WsEventServer.CONNECTION_REMOVED, {"user_id": str(user.id)}
        )

    # ------------------------------------------------------------------ #
    # Blocks
    # ------------------------------------------------------------------ #
    @staticmethod
    async def block(
        *, request: Request, user: User, target_id: uuid.UUID, db: AsyncSession
    ) -> None:
        if target_id == user.id:
            raise ConnectionError("cannot_block_self")
        existing = await db.scalar(
            select(Block).where(
                Block.blocker_id == user.id, Block.blocked_id == target_id
            )
        )
        if existing is None:
            db.add(Block(blocker_id=user.id, blocked_id=target_id))

        # Tear down any connection.
        conn = await db.scalar(
            select(Connection).where(
                Connection.user_id == user.id, Connection.connected_user_id == target_id
            )
        )
        had_connection = conn is not None
        if had_connection:
            pair_id = conn.pair_id
            await db.execute(
                delete(Connection).where(
                    or_(
                        (Connection.user_id == user.id)
                        & (Connection.connected_user_id == target_id),
                        (Connection.user_id == target_id)
                        & (Connection.connected_user_id == user.id),
                    )
                )
            )
            lo, hi = _pair_id(user.id, target_id)
            db.add(
                ConnectionRemoval(
                    pair_id=pair_id, removed_by=user.id, user_a=lo, user_b=hi
                )
            )

        # Withdraw/ignore pending invitations in both directions. The outgoing
        # one is read first: the target sees it vanish exactly as a withdraw.
        now = _now()
        withdrawn_invitation_id = await db.scalar(
            select(ConnectionInvitation.id).where(
                ConnectionInvitation.sender_id == user.id,
                ConnectionInvitation.recipient_id == target_id,
                ConnectionInvitation.status == InvitationStatus.PENDING,
            )
        )
        await db.execute(
            ConnectionInvitation.__table__.update()
            .where(
                ConnectionInvitation.sender_id == user.id,
                ConnectionInvitation.recipient_id == target_id,
                ConnectionInvitation.status == InvitationStatus.PENDING,
            )
            .values(status=InvitationStatus.WITHDRAWN, responded_at=now)
        )
        await db.execute(
            ConnectionInvitation.__table__.update()
            .where(
                ConnectionInvitation.sender_id == target_id,
                ConnectionInvitation.recipient_id == user.id,
                ConnectionInvitation.status == InvitationStatus.PENDING,
            )
            .values(status=InvitationStatus.IGNORED, responded_at=now)
        )

        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.USER_BLOCKED,
            resource_type="user",
            resource_id=target_id,
            db=db,
        )
        await db.commit()
        if had_connection:
            await RelationshipService.remove_edge_cache(user.id, target_id)
        else:
            await RelationshipService.invalidate_second_degree(user.id, target_id)
        # SILENT about the block itself: the target only sees what a removal
        # or a withdraw would have shown them (identical frames), never that
        # they were blocked. The ignored incoming invitation publishes nothing.
        if had_connection:
            await ws_manager.publish_to_users(
                [target_id], WsEventServer.CONNECTION_REMOVED, {"user_id": str(user.id)}
            )
        if withdrawn_invitation_id is not None:
            await ws_manager.publish_to_users(
                [target_id],
                WsEventServer.INVITATION_WITHDRAWN,
                {"invitation_id": str(withdrawn_invitation_id), "sender_id": str(user.id)},
            )

    @staticmethod
    async def unblock(
        *, request: Request, user: User, target_id: uuid.UUID, db: AsyncSession
    ) -> None:
        await db.execute(
            delete(Block).where(
                Block.blocker_id == user.id, Block.blocked_id == target_id
            )
        )
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.USER_UNBLOCKED,
            resource_type="user",
            resource_id=target_id,
            db=db,
        )
        await db.commit()

    # ------------------------------------------------------------------ #
    # Mutes
    # ------------------------------------------------------------------ #
    @staticmethod
    async def mute(*, user: User, target_id: uuid.UUID, db: AsyncSession) -> None:
        if target_id == user.id:
            raise ConnectionError("cannot_mute_self")
        existing = await db.scalar(
            select(Mute).where(Mute.user_id == user.id, Mute.muted_user_id == target_id)
        )
        if existing is None:
            db.add(Mute(user_id=user.id, muted_user_id=target_id))
            await db.flush()
        await db.commit()

    @staticmethod
    async def unmute(*, user: User, target_id: uuid.UUID, db: AsyncSession) -> None:
        await db.execute(
            delete(Mute).where(Mute.user_id == user.id, Mute.muted_user_id == target_id)
        )
        await db.commit()

    # ------------------------------------------------------------------ #
    # Reports
    # ------------------------------------------------------------------ #
    @staticmethod
    async def report(
        *,
        request: Request,
        user: User,
        subject_type: str,
        subject_id: uuid.UUID,
        reason: str,
        details: str | None,
        db: AsyncSession,
    ) -> Report:
        report = Report(
            reporter_id=user.id,
            subject_type=subject_type,
            subject_id=subject_id,
            reason=reason,
            details=details,
        )
        db.add(report)
        await db.flush()
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.REPORT_FILED,
            resource_type=subject_type,
            resource_id=subject_id,
            db=db,
            metadata={"reason": reason},
        )
        await db.commit()
        return report
