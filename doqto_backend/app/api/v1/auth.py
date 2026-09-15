from __future__ import annotations

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import get_current_user
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
from app.schemas.user import UserOut, build_user_out
from app.services.audit_service import request_meta
from app.services.auth_service import AuthError, AuthService, RateLimited

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
        )
    except RateLimited as e:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, detail=str(e)) from e
    except AuthError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail=str(e)) from e


@router.post(ApiRoutes.AUTH_REFRESH, response_model=TokenPair)
async def refresh(body: RefreshIn, redis: Redis = Depends(get_redis)) -> TokenPair:
    try:
        return await AuthService.refresh(refresh_token=body.refresh_token, redis=redis)
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
    return await build_user_out(updated)
