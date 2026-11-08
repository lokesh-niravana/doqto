"""Linked devices + two-step PIN (batch 6).

A `sessions` row is the durable record of one sign-in on one device; the Redis
jti keys (app/core/redis_keys.py) stay the live gate every request checks.
Revoking a session deletes its Redis keys and stamps `revoked_at`, so the
device's next call answers 401 `session_revoked` and the app wipes itself.

Two-step PIN: a user with a `pin_hash` must enter it once per NEW device — a
(device_name, platform) pair this user has never signed in from. Tokens are
issued regardless, but `sessions.pin_verified_at` stays NULL and
`get_current_user` answers 403 `pin_required` until `POST /auth/pin/verify`
succeeds. Forgot PIN: `POST /auth/pin/reset-request` stamps `pin_reset_at`;
the settings loop clears the PIN once PIN_RESET_COOLDOWN_SEC has passed.
No PHI anywhere here.
"""
from __future__ import annotations

import logging
import uuid
from datetime import datetime, timedelta, timezone

from passlib.context import CryptContext
from redis.asyncio import Redis
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.constants import (
    PIN_RESET_COOLDOWN_SEC,
    PIN_VERIFY_WINDOW_SEC,
    RATE_LIMIT_PIN_VERIFY_PER_15_MIN,
)
from app.core.enums import AuditAction, WsEventServer
from app.core.redis_keys import pin_verify_attempts_key, refresh_session_key, session_key
from app.models import Session, User
from app.services.audit_service import AuditService
from app.services.notification_service import NotificationService

log = logging.getLogger("doqto.sessions")

_pin_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")

# In-app notification feed type for a new sign-in (payload: device_name only).
TYPE_NEW_SIGN_IN = "new_sign_in"


class PinError(Exception):
    """Code string is the API `detail`; the router maps it to a status."""


def _now() -> datetime:
    return datetime.now(tz=timezone.utc)


class SessionService:
    # -- lookups -------------------------------------------------------------- #
    @staticmethod
    async def by_access_jti(jti: str, db: AsyncSession) -> Session | None:
        return await db.scalar(select(Session).where(Session.access_jti == jti))

    @staticmethod
    async def by_refresh_jti(jti: str, db: AsyncSession) -> Session | None:
        return await db.scalar(select(Session).where(Session.refresh_jti == jti))

    @staticmethod
    async def list_active(user_id: uuid.UUID, db: AsyncSession) -> list[Session]:
        rows = await db.scalars(
            select(Session)
            .where(Session.user_id == user_id, Session.revoked_at.is_(None))
            .order_by(Session.last_seen_at.desc())
        )
        return list(rows.all())

    @staticmethod
    async def is_known_device(
        *, user_id: uuid.UUID, device_name: str | None, platform: str | None, db: AsyncSession
    ) -> bool:
        """Has this user signed in from this (device_name, platform) before?
        An unnamed device is never "known" — the PIN is asked."""
        if not device_name:
            return False
        row = await db.scalar(
            select(Session.id)
            .where(
                Session.user_id == user_id,
                Session.device_name == device_name,
                Session.platform == platform,
            )
            .limit(1)
        )
        return row is not None

    # -- lifecycle ------------------------------------------------------------ #
    @staticmethod
    async def create(
        *,
        user: User,
        jti: str,
        device_name: str | None,
        platform: str | None,
        app_version: str | None,
        ip: str | None,
        db: AsyncSession,
    ) -> Session:
        """Row for a fresh sign-in. The PIN gate opens immediately when the
        user has no PIN or the device is already known."""
        known = await SessionService.is_known_device(
            user_id=user.id, device_name=device_name, platform=platform, db=db
        )
        row = Session(
            user_id=user.id,
            device_name=device_name,
            platform=platform,
            app_version=app_version,
            ip=ip,
            refresh_jti=jti,
            access_jti=jti,
            pin_verified_at=_now() if (user.pin_hash is None or known) else None,
        )
        db.add(row)
        await db.flush()
        return row

    @staticmethod
    async def rotate(*, old_jti: str, new_jti: str, db: AsyncSession) -> Session | None:
        """Refresh: the pair's jtis move on; last_seen_at is the refresh time.
        Legacy pairs issued before the table existed have no row — fine."""
        row = await SessionService.by_refresh_jti(old_jti, db)
        if row is None or row.revoked_at is not None:
            return row
        row.refresh_jti = new_jti
        row.access_jti = new_jti
        row.last_seen_at = _now()
        await db.flush()
        return row

    @staticmethod
    async def revoke(*, row: Session, redis: Redis, db: AsyncSession) -> None:
        """Kill the live keys and stamp the row. Idempotent."""
        await redis.delete(session_key(row.access_jti), refresh_session_key(row.refresh_jti))
        if row.revoked_at is None:
            row.revoked_at = _now()
            await db.flush()

    @staticmethod
    async def revoke_by_access_jti(*, jti: str, redis: Redis, db: AsyncSession) -> None:
        """Logout path: the row (if any) follows the Redis keys."""
        row = await SessionService.by_access_jti(jti, db)
        if row is not None:
            await SessionService.revoke(row=row, redis=redis, db=db)

    @staticmethod
    async def revoke_others(
        *, user_id: uuid.UUID, keep_jti: str | None, redis: Redis, db: AsyncSession
    ) -> list[Session]:
        rows = await SessionService.list_active(user_id, db)
        revoked = []
        for row in rows:
            if keep_jti is not None and row.access_jti == keep_jti:
                continue
            await SessionService.revoke(row=row, redis=redis, db=db)
            revoked.append(row)
        return revoked

    @staticmethod
    async def publish_revoked(user_id: uuid.UUID, session_ids: list[uuid.UUID]) -> None:
        """Post-commit: every device of the user hears which sessions died; the
        one that matches its own session_id wipes and returns to login."""
        for sid in session_ids:
            await ws_manager.publish_to_users(
                [user_id], WsEventServer.SESSION_REVOKED, {"session_id": str(sid)}
            )

    # -- new sign-in alert ------------------------------------------------------ #
    @staticmethod
    async def notify_new_sign_in(
        *, user: User, session: Session, other_count: int, db: AsyncSession
    ) -> None:
        """In-app notification + WS `session_created` + PHI-free push to the
        user's devices when a registered user signs in while other sessions
        are alive. Call pre-commit for the row; publish() after commit."""
        if other_count == 0:
            return
        notif = await NotificationService.create(
            db=db,
            user_id=user.id,
            type=TYPE_NEW_SIGN_IN,
            subject_type="session",
            subject_id=session.id,
            payload={"device_name": session.device_name, "platform": session.platform},
        )
        unread = await NotificationService.unread_count(db=db, user_id=user.id)
        await db.commit()
        await ws_manager.publish_to_users(
            [user.id],
            WsEventServer.SESSION_CREATED,
            {
                "session_id": str(session.id),
                "device_name": session.device_name,
                "platform": session.platform,
                "created_at": session.created_at.isoformat() if session.created_at else None,
            },
        )
        await NotificationService.publish(notification=notif, unread_count=unread)
        # Local import: push_service imports message_service, which is heavy.
        from app.services.push_service import PushService

        PushService.notify_new_sign_in(
            recipient_id=user.id,
            device_name=session.device_name,
            session_id=session.id,
        )


class PinService:
    @staticmethod
    def hash_pin(pin: str) -> str:
        return _pin_ctx.hash(pin)

    @staticmethod
    def check(pin: str, pin_hash: str | None) -> bool:
        return pin_hash is not None and _pin_ctx.verify(pin, pin_hash)

    @staticmethod
    async def set_pin(
        *, user: User, pin: str, current_pin: str | None, db: AsyncSession
    ) -> None:
        """Set or change. A change needs the current PIN — a stolen unlocked
        phone must not be able to lock the owner out of their own account."""
        if user.pin_hash is not None and not PinService.check(current_pin or "", user.pin_hash):
            raise PinError("pin_invalid")
        user.pin_hash = PinService.hash_pin(pin)
        user.pin_reset_at = None
        # Every live session was verified by the user who just typed the PIN.
        await db.execute(
            update(Session)
            .where(Session.user_id == user.id, Session.pin_verified_at.is_(None))
            .values(pin_verified_at=_now())
        )
        await db.flush()

    @staticmethod
    async def remove_pin(*, user: User, pin: str, db: AsyncSession) -> None:
        if user.pin_hash is None:
            raise PinError("pin_not_set")
        if not PinService.check(pin, user.pin_hash):
            raise PinError("pin_invalid")
        user.pin_hash = None
        user.pin_reset_at = None
        await db.execute(
            update(Session)
            .where(Session.user_id == user.id, Session.pin_verified_at.is_(None))
            .values(pin_verified_at=_now())
        )
        await db.flush()

    @staticmethod
    async def verify(
        *, user: User, pin: str, access_jti: str, redis: Redis, db: AsyncSession
    ) -> None:
        """Open the PIN gate for the session behind `access_jti`. Wrong
        attempts are capped per user per window (429 pin_too_many_attempts)."""
        if user.pin_hash is None:
            raise PinError("pin_not_set")
        key = pin_verify_attempts_key(user.id)
        attempts = int(await redis.get(key) or 0)
        if attempts >= RATE_LIMIT_PIN_VERIFY_PER_15_MIN:
            raise PinError("pin_too_many_attempts")
        if not PinService.check(pin, user.pin_hash):
            count = await redis.incr(key)
            if count == 1:
                await redis.expire(key, PIN_VERIFY_WINDOW_SEC)
            raise PinError("pin_invalid")
        await redis.delete(key)
        # Typing the right PIN cancels a forgot-PIN cooldown someone else may
        # have started from a stolen device.
        user.pin_reset_at = None
        row = await SessionService.by_access_jti(access_jti, db)
        if row is not None and row.pin_verified_at is None:
            row.pin_verified_at = _now()
        await db.flush()

    @staticmethod
    async def request_reset(*, user: User, db: AsyncSession) -> datetime:
        """Start (or report) the 7-day cooldown. Returns when the PIN clears."""
        if user.pin_hash is None:
            raise PinError("pin_not_set")
        if user.pin_reset_at is None:
            user.pin_reset_at = _now()
            await db.flush()
        return user.pin_reset_at + timedelta(seconds=PIN_RESET_COOLDOWN_SEC)

    @staticmethod
    async def complete_resets(db: AsyncSession) -> list[uuid.UUID]:
        """Loop job: clear PINs whose cooldown has lapsed and open every
        pending session gate. Returns the users affected."""
        cutoff = _now() - timedelta(seconds=PIN_RESET_COOLDOWN_SEC)
        rows = (
            await db.scalars(
                select(User).where(User.pin_hash.is_not(None), User.pin_reset_at <= cutoff)
            )
        ).all()
        cleared: list[uuid.UUID] = []
        for user in rows:
            user.pin_hash = None
            user.pin_reset_at = None
            await db.execute(
                update(Session)
                .where(Session.user_id == user.id, Session.pin_verified_at.is_(None))
                .values(pin_verified_at=_now())
            )
            await AuditService.log(
                db, user_id=user.id, action=AuditAction.PIN_RESET_COMPLETED, resource_type="user",
                resource_id=user.id,
            )
            cleared.append(user.id)
        if cleared:
            await db.flush()
        return cleared
