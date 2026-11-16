from __future__ import annotations

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import RATE_LIMIT_PIN_WRITES_PER_MINUTE
from app.core.dependencies import bearer_jti, get_current_user, get_current_user_pin_pending_ok
from app.core.enums import AuditAction
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.db.redis import get_redis
from app.models import User
from app.schemas.auth import (
    FirebaseSignInIn,
    RefreshIn,
    RegisterIn,
    TokenPair,
)
from app.schemas.common import OkResponse
from app.schemas.settings import PinStatusOut, PinVerifyIn
from app.schemas.user import UserOut, build_user_out, pin_clears_at
from app.services.audit_service import AuditService, request_meta
from app.services.auth_service import AuthError, AuthService, RateLimited
from app.services.invite_service import InviteService
from app.services.session_service import PinError, PinService

router = APIRouter()


@router.post(ApiRoutes.AUTH_FIREBASE, response_model=TokenPair)
async def sign_in_with_firebase(
    body: FirebaseSignInIn,
    request: Request,
    redis: Redis = Depends(get_redis),
    db: AsyncSession = Depends(get_db),
) -> TokenPair:
    """Every sign-in method lands here — phone, Google, Facebook and Apple all
    arrive as one Firebase ID token."""
    ip, user_agent = request_meta(request)
    try:
        return await AuthService.sign_in_with_firebase(
            id_token=body.id_token,
            redis=redis,
            db=db,
            ip_address=ip,
            user_agent=user_agent,
            device_name=body.device_name,
            platform=body.platform.value if body.platform else None,
            app_version=body.app_version,
        )
    except RateLimited as e:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, detail=str(e)) from e
    except AuthError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail=str(e)) from e


@router.post(ApiRoutes.AUTH_REFRESH, response_model=TokenPair)
async def refresh(
    body: RefreshIn,
    redis: Redis = Depends(get_redis),
    db: AsyncSession = Depends(get_db),
) -> TokenPair:
    try:
        return await AuthService.refresh(refresh_token=body.refresh_token, redis=redis, db=db)
    except AuthError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail=str(e)) from e


@router.post(ApiRoutes.AUTH_LOGOUT, response_model=OkResponse)
async def logout(
    authorization: str | None = Header(default=None),
    redis: Redis = Depends(get_redis),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    if authorization and authorization.lower().startswith("bearer "):
        await AuthService.logout(access_token=authorization.split(" ", 1)[1], redis=redis, db=db)
    return OkResponse()


@router.post(ApiRoutes.AUTH_REGISTER, response_model=UserOut)
async def register(
    body: RegisterIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> UserOut:
    try:
        updated = await AuthService.complete_registration(
            user=user,
            full_name=body.full_name,
            specialty=body.specialty,
            npi_number=body.npi_number,
            db=db,
        )
    except AuthError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e
    await InviteService.connect_inviters(user=updated, db=db)
    return await build_user_out(updated)


_PIN_STATUS = {
    "pin_invalid": status.HTTP_401_UNAUTHORIZED,
    "pin_not_set": status.HTTP_409_CONFLICT,
    "pin_too_many_attempts": status.HTTP_429_TOO_MANY_REQUESTS,
}


def pin_http_error(e: PinError) -> HTTPException:
    return HTTPException(_PIN_STATUS.get(str(e), status.HTTP_400_BAD_REQUEST), detail=str(e))


@router.post(ApiRoutes.AUTH_PIN_VERIFY, response_model=PinStatusOut)
async def verify_pin(
    body: PinVerifyIn,
    request: Request,
    authorization: str | None = Header(default=None),
    user: User = Depends(get_current_user_pin_pending_ok),
    redis: Redis = Depends(get_redis),
    db: AsyncSession = Depends(get_db),
) -> PinStatusOut:
    """Two-step PIN on a new device (batch 6). Opens the gate for THIS
    session only; 401 pin_invalid, 429 after 5 wrong tries in 15 minutes."""
    jti = bearer_jti(authorization) or ""
    try:
        await PinService.verify(user=user, pin=body.pin, access_jti=jti, redis=redis, db=db)
    except PinError as e:
        await db.commit()  # keep the attempt counter's side effects (Redis) — nothing in DB
        raise pin_http_error(e) from e
    await AuditService.log_request(
        request, user_id=user.id, action=AuditAction.PIN_VERIFIED, resource_type="user",
        resource_id=user.id, db=db,
    )
    await db.commit()
    return PinStatusOut(pin_enabled=True, pin_clears_at=None)


@router.post(ApiRoutes.AUTH_PIN_RESET_REQUEST, response_model=PinStatusOut)
async def request_pin_reset(
    request: Request,
    user: User = Depends(get_current_user_pin_pending_ok),
    db: AsyncSession = Depends(get_db),
) -> PinStatusOut:
    """Forgot PIN: start the 7-day cooldown after which the PIN clears
    itself. Idempotent — asking again reports the same instant. Typing the
    right PIN in the meantime cancels it."""
    await enforce_rate_limit(user.id, "pin_reset_request", RATE_LIMIT_PIN_WRITES_PER_MINUTE)
    try:
        clears_at = await PinService.request_reset(user=user, db=db)
    except PinError as e:
        raise pin_http_error(e) from e
    await AuditService.log_request(
        request, user_id=user.id, action=AuditAction.PIN_RESET_REQUESTED, resource_type="user",
        resource_id=user.id, db=db, metadata={"clears_at": clears_at.isoformat()},
    )
    await db.commit()
    return PinStatusOut(pin_enabled=True, pin_clears_at=pin_clears_at(user))
