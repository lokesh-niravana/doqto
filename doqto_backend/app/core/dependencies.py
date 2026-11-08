from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import Depends, Header, HTTPException, status
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.enums import JwtTokenType, OrgRole, UserRole
from app.core.redis_keys import session_key
from app.core.security import TokenError, decode_token
from app.db.postgres import get_db
from app.db.redis import get_redis
from app.models import OrgMember, Session, User


def bearer_jti(authorization: str | None) -> str | None:
    """The access jti behind an Authorization header, or None. Used by the
    sessions routes to tell "this device" apart; auth itself is get_current_user."""
    if not authorization or not authorization.lower().startswith("bearer "):
        return None
    try:
        return decode_token(authorization.split(" ", 1)[1].strip(), JwtTokenType.ACCESS).get("jti")
    except TokenError:
        return None


async def pin_pending(user: User, jti: str, db: AsyncSession) -> bool:
    """Two-step PIN (batch 6): the session behind `jti` still owes the PIN.
    Only users with a PIN pay the extra query."""
    if user.pin_hash is None:
        return False
    row = await db.execute(
        select(Session.id, Session.pin_verified_at).where(Session.access_jti == jti)
    )
    hit = row.first()
    # Legacy tokens without a row predate the PIN — treat as verified.
    return hit is not None and hit.pin_verified_at is None


async def _user_from_token(
    authorization: str | None,
    db: AsyncSession,
    redis: Redis,
    *,
    allow_pin_pending: bool = False,
) -> User:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="missing_authorization")
    token = authorization.split(" ", 1)[1].strip()
    try:
        payload = decode_token(token, JwtTokenType.ACCESS)
    except TokenError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail=str(e)) from e

    jti = payload.get("jti")
    if not jti or not await redis.exists(session_key(jti)):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="session_revoked")

    user_id = uuid.UUID(payload["sub"])
    user = await db.scalar(select(User).where(User.id == user_id))
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="user_not_found")
    # Deleted accounts keep a tombstone row, so an unexpired token would still
    # resolve. Refuse it here rather than at each call site.
    if user.deleted_at is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail="account_deleted")
    if not allow_pin_pending and await pin_pending(user, jti, db):
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="pin_required")
    return user


async def get_current_user(
    authorization: Annotated[str | None, Header()] = None,
    db: AsyncSession = Depends(get_db),
    redis: Redis = Depends(get_redis),
) -> User:
    return await _user_from_token(authorization, db, redis)


async def get_current_user_pin_pending_ok(
    authorization: Annotated[str | None, Header()] = None,
    db: AsyncSession = Depends(get_db),
    redis: Redis = Depends(get_redis),
) -> User:
    """Same as get_current_user but lets a device that still owes its PIN
    through — ONLY for /auth/pin/verify and /auth/pin/reset-request."""
    return await _user_from_token(authorization, db, redis, allow_pin_pending=True)


async def require_super_admin(user: User = Depends(get_current_user)) -> User:
    if user.role != UserRole.SUPER_ADMIN:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="super_admin_required")
    return user


async def require_org_member(
    org_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OrgMember:
    member = await db.scalar(
        select(OrgMember).where(OrgMember.org_id == org_id, OrgMember.user_id == user.id)
    )
    if member is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="not_an_org_member")
    return member


async def require_org_admin(
    org_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OrgMember:
    member = await db.scalar(
        select(OrgMember).where(OrgMember.org_id == org_id, OrgMember.user_id == user.id)
    )
    if member is None or member.org_role != OrgRole.ADMIN:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="org_admin_required")
    return member
