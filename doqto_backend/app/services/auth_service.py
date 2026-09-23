from __future__ import annotations

import secrets
import uuid
from datetime import datetime, timedelta, timezone

from fastapi.concurrency import run_in_threadpool
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.constants import (
    ACCESS_TOKEN_TTL_SECONDS,
    RATE_LIMIT_SIGNIN_PER_HOUR,
    REFRESH_TOKEN_TTL_SECONDS,
)
from app.core.enums import AuditAction, JwtTokenType, UserRole
from app.core.redis_keys import (
    rate_limit_key,
    refresh_session_key,
    session_key,
)
from app.core.security import TokenError, create_token, decode_token
from app.models import User
from app.schemas.auth import TokenPair
from app.services import firebase_auth
from app.services.audit_service import AuditService


class AuthError(Exception):
    pass


class RateLimited(AuthError):
    """Caller should surface 429, not 401."""


class WrongAccount(AuthError):
    """Caller should surface 403."""


class PhoneTaken(AuthError):
    """Caller should surface 409."""






class AuthService:
    @staticmethod
    async def sign_in_with_firebase(
        *,
        id_token: str,
        redis: Redis,
        db: AsyncSession,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ) -> TokenPair:
        """Exchange a Firebase ID token for a Doqto token pair.

        Every sign-in method arrives here. Firebase asserts the identity; this
        resolves it to a user row and mints our own tokens, so sessions, roles
        and the audit trail are unchanged by which button was tapped.
        """
        # Per-IP hourly cap. Guards the DB, not an SMS budget — Google pays for
        # the messages now.
        if ip_address:
            rl_key = rate_limit_key(f"ip:{ip_address}", "signin")
            count = int(await redis.get(rl_key) or 0)
            if count >= RATE_LIMIT_SIGNIN_PER_HOUR:
                raise RateLimited("signin_too_many_requests")
            if count == 0:
                await redis.setex(rl_key, 3600, 1)
            else:
                await redis.incr(rl_key)

        # google-auth is blocking (it fetches and caches Google's certs), so it
        # must not run on the event loop.
        try:
            identity = await run_in_threadpool(firebase_auth.verify_id_token, id_token)
        except firebase_auth.FirebaseAuthError as e:
            raise AuthError(str(e)) from e

        user = await db.scalar(select(User).where(User.firebase_uid == identity.uid))
        if user is None:
            user = await AuthService._adopt_or_create(identity=identity, db=db)

        # A deleted account is a scrubbed tombstone kept for HIPAA retention. It
        # must never come back to life, even if the provider account still exists.
        if user.deleted_at is not None:
            raise AuthError("account_deleted")

        is_registered = bool(user.full_name and not user.npi_number.startswith("PENDING"))
        user.last_seen_at = datetime.now(tz=timezone.utc)
        await AuditService.log(
            db,
            user_id=user.id,
            action=AuditAction.OTP_VERIFIED if identity.phone else AuditAction.SOCIAL_VERIFIED,
            ip_address=ip_address,
            user_agent=user_agent,
        )
        return await AuthService._issue_tokens(
            user=user,
            is_registered=is_registered,
            redis=redis,
            db=db,
            ip_address=ip_address,
            user_agent=user_agent,
        )

    @staticmethod
    async def _adopt_or_create(*, identity: firebase_auth.FirebaseIdentity, db: AsyncSession) -> User:
        """Find the row this identity belongs to, or start a new one.

        Adoption by phone/email is what makes brokering invisible to anyone who
        signed up before Firebase existed: their row simply gains a firebase_uid
        on next sign-in.
        """
        user = None
        if identity.phone:
            user = await db.scalar(select(User).where(User.phone == identity.phone))
        if user is None and identity.email:
            user = await db.scalar(select(User).where(User.email == identity.email))
        if user is None:
            user = User(
                phone=identity.phone,
                email=identity.email,
                full_name="",
                npi_number=f"PENDING{secrets.randbelow(100):02d}",
                role=UserRole.DOCTOR,
            )
            db.add(user)
        user.firebase_uid = identity.uid
        await db.flush()
        return user

    @staticmethod
    async def _issue_tokens(
        *,
        user: User,
        is_registered: bool,
        redis: Redis,
        db: AsyncSession,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ) -> TokenPair:
        access, jti = create_token(user.id, JwtTokenType.ACCESS)
        refresh, _ = create_token(user.id, JwtTokenType.REFRESH, jti=jti)
        # Each token gets its own session TTL (§164.312(a)(2)(iii)): a revoked
        # access token dies after 1h even though the refresh half lives 7d.
        await redis.setex(session_key(jti), ACCESS_TOKEN_TTL_SECONDS, str(user.id))
        await redis.setex(refresh_session_key(jti), REFRESH_TOKEN_TTL_SECONDS, str(user.id))
        if is_registered:
            await AuditService.log(
                db,
                user_id=user.id,
                action=AuditAction.LOGIN,
                ip_address=ip_address,
                user_agent=user_agent,
            )
        return TokenPair(access_token=access, refresh_token=refresh, is_registered=is_registered)

    @staticmethod
    async def link_phone(*, user: User, id_token: str, db: AsyncSession) -> User:
        """Attach a phone number the client proved through Firebase.

        Deliberately not a sign-in: signing in with a phone signs you in *as*
        whoever owns it, which mid-registration would swap accounts. The client
        links the number to its existing Firebase user instead, and the
        refreshed token carries the proof.
        """
        try:
            identity = await run_in_threadpool(firebase_auth.verify_id_token, id_token)
        except firebase_auth.FirebaseAuthError as e:
            raise AuthError(str(e)) from e

        # The token must belong to this account, or a borrowed one could move
        # someone else's number onto it.
        if not user.firebase_uid or identity.uid != user.firebase_uid:
            raise WrongAccount("firebase_uid_mismatch")
        # No phone claim means the link never happened.
        if not identity.phone:
            raise AuthError("phone_not_verified")

        dup = await db.scalar(
            select(User).where(User.phone == identity.phone, User.id != user.id)
        )
        if dup is not None:
            raise PhoneTaken("phone_already_registered")

        user.phone = identity.phone
        return user

    @staticmethod
    async def refresh(*, refresh_token: str, redis: Redis) -> TokenPair:
        try:
            payload = decode_token(refresh_token, JwtTokenType.REFRESH)
        except TokenError as e:
            raise AuthError(str(e)) from e
        jti = payload.get("jti")
        user_id = payload.get("sub")
        if not jti or not user_id or not await redis.exists(refresh_session_key(jti)):
            raise AuthError("session_revoked")

        access, new_jti = create_token(user_id, JwtTokenType.ACCESS)
        refresh, _ = create_token(user_id, JwtTokenType.REFRESH, jti=new_jti)
        await redis.delete(session_key(jti), refresh_session_key(jti))
        await redis.setex(session_key(new_jti), ACCESS_TOKEN_TTL_SECONDS, user_id)
        await redis.setex(refresh_session_key(new_jti), REFRESH_TOKEN_TTL_SECONDS, user_id)
        return TokenPair(access_token=access, refresh_token=refresh, is_registered=True)

    @staticmethod
    async def logout(*, access_token: str, redis: Redis, db: AsyncSession) -> None:
        try:
            payload = decode_token(access_token, JwtTokenType.ACCESS)
        except TokenError:
            return
        jti = payload.get("jti")
        user_id = payload.get("sub")
        if jti:
            await redis.delete(session_key(jti), refresh_session_key(jti))
        if user_id:
            await AuditService.log(db, user_id=uuid.UUID(user_id), action=AuditAction.LOGOUT)

    @staticmethod
    async def complete_registration(
        *, user: User, full_name: str, specialty: str | None, npi_number: str, db: AsyncSession
    ) -> User:
        dup = await db.scalar(select(User).where(User.npi_number == npi_number, User.id != user.id))
        if dup is not None:
            raise AuthError("npi_already_registered")
        user.full_name = full_name
        user.specialty = specialty
        user.npi_number = npi_number
        # The trial starts when registration finishes, not at the first
        # sign-in: a half-finished sign-up hasn't used any of it. Never reset
        # an existing one, or registering again would restart the clock.
        if user.trial_ends_at is None:
            user.trial_ends_at = datetime.now(tz=timezone.utc) + timedelta(
                days=settings.BILLING_TRIAL_DAYS
            )
        await AuditService.log(db, user_id=user.id, action=AuditAction.REGISTER)
        return user
