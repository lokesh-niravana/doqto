from __future__ import annotations

import uuid
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import ADMIN_LOGIN_MAX_ATTEMPTS, ADMIN_LOGIN_WINDOW_SECONDS
from app.core.dependencies import require_super_admin
from app.core.enums import OrgStatus
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.db.redis import get_redis
from app.models import Organization, User
from app.schemas.admin_auth import AdminLoginIn
from app.schemas.auth import TokenPair
from app.schemas.organization import OrgApproveIn, OrgOut, OrgRejectIn
from app.services.admin_auth_service import AdminAuthError, AdminAuthService
from app.api.v1.orgs import publish_org_updated
from app.services.org_service import OrgError, OrgService

router = APIRouter()


@router.post("/auth/login", response_model=TokenPair)
async def admin_login(
    body: AdminLoginIn,
    redis: Redis = Depends(get_redis),
    db: AsyncSession = Depends(get_db),
) -> TokenPair:
    # Lockout (M4): counted per email regardless of outcome.
    await enforce_rate_limit(
        body.email.lower().strip(),
        "admin_login",
        limit=ADMIN_LOGIN_MAX_ATTEMPTS,
        window_seconds=ADMIN_LOGIN_WINDOW_SECONDS,
    )
    try:
        return await AdminAuthService.login(
            email=body.email, password=body.password, redis=redis, db=db
        )
    except AdminAuthError as e:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, detail=str(e)) from e


async def _to_out(org: Organization, db: AsyncSession) -> OrgOut:
    count = await OrgService.member_count(org_id=org.id, db=db)
    out = OrgOut.model_validate(org)
    out.member_count = count
    return out


@router.get(ApiRoutes.ADMIN_ORGS, response_model=list[OrgOut])
async def list_orgs(
    status_filter: Literal["pending", "active", "suspended", "all"] = Query(
        default="pending", alias="status"
    ),
    _: User = Depends(require_super_admin),
    db: AsyncSession = Depends(get_db),
) -> list[OrgOut]:
    stmt = select(Organization).order_by(Organization.created_at.desc())
    if status_filter != "all":
        stmt = stmt.where(Organization.status == OrgStatus(status_filter))
    rows = await db.execute(stmt)
    return [await _to_out(o, db) for o in rows.scalars().all()]


# Back-compat shortcut.
@router.get("/orgs/pending", response_model=list[OrgOut])
async def list_pending(
    admin: User = Depends(require_super_admin), db: AsyncSession = Depends(get_db)
) -> list[OrgOut]:
    return await list_orgs(status_filter="pending", _=admin, db=db)  # type: ignore[arg-type]


@router.patch(ApiRoutes.ADMIN_VERIFY_ORG, response_model=OrgOut)
async def verify_org(
    org_id: uuid.UUID,
    body: OrgApproveIn | None = None,
    admin: User = Depends(require_super_admin),
    db: AsyncSession = Depends(get_db),
) -> OrgOut:
    try:
        org = await OrgService.verify(
            org_id=org_id,
            admin=admin,
            db=db,
            notes=(body.notes if body else None),
        )
    except OrgError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e
    await db.commit()
    await publish_org_updated(org.id, db)
    return await _to_out(org, db)


@router.patch(ApiRoutes.ADMIN_REJECT_ORG, response_model=OrgOut)
async def reject_org(
    org_id: uuid.UUID,
    body: OrgRejectIn,
    admin: User = Depends(require_super_admin),
    db: AsyncSession = Depends(get_db),
) -> OrgOut:
    try:
        org = await OrgService.reject(
            org_id=org_id, admin=admin, reason=body.reason, db=db
        )
    except OrgError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e
    await db.commit()
    await publish_org_updated(org.id, db)
    return await _to_out(org, db)
