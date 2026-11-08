from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    ADMIN_LOGIN_MAX_ATTEMPTS,
    ADMIN_LOGIN_WINDOW_SECONDS,
    REPORTS_PAGE_SIZE,
)
from app.core.dependencies import require_super_admin
from app.core.enums import AuditAction, OrgStatus, ReportStatus
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.db.redis import get_redis
from app.models import Organization, Report, User
from app.schemas.admin_auth import AdminLoginIn
from app.schemas.auth import TokenPair
from app.schemas.network import ReportOut, ReportStatusIn
from app.schemas.organization import OrgApproveIn, OrgOut, OrgRejectIn
from app.services.audit_service import AuditService
from app.services.admin_auth_service import AdminAuthError, AdminAuthService
from app.api.v1.orgs import effective_policies, publish_org_updated
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
    out.policies = effective_policies(org)
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


# --- Moderation queue (batch 4) ---------------------------------------------- #


@router.get(ApiRoutes.ADMIN_REPORTS, response_model=list[ReportOut])
async def list_reports(
    status_filter: Literal["open", "reviewing", "actioned", "dismissed", "all"] = Query(
        default="open", alias="status"
    ),
    cursor: datetime | None = Query(default=None),
    limit: int = Query(default=REPORTS_PAGE_SIZE, ge=1, le=REPORTS_PAGE_SIZE),
    _: User = Depends(require_super_admin),
    db: AsyncSession = Depends(get_db),
) -> list[ReportOut]:
    """Reports newest first. `status=` filters (default open; `all` for every
    status). Ids only — a moderator reads message bodies through the audited
    thread path, never from here."""
    stmt = select(Report)
    if status_filter != "all":
        stmt = stmt.where(Report.status == ReportStatus(status_filter))
    if cursor is not None:
        stmt = stmt.where(Report.created_at < cursor)
    rows = await db.scalars(stmt.order_by(Report.created_at.desc()).limit(limit))
    return [ReportOut.model_validate(r) for r in rows.all()]


@router.patch(ApiRoutes.ADMIN_REPORT_DETAIL, response_model=ReportOut)
async def set_report_status(
    report_id: uuid.UUID,
    body: ReportStatusIn,
    request: Request,
    admin: User = Depends(require_super_admin),
    db: AsyncSession = Depends(get_db),
) -> ReportOut:
    """Move a report through open → reviewing → actioned / dismissed. Any
    transition is allowed (a dismissed report can be reopened); each is audited."""
    report = await db.get(Report, report_id)
    if report is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="report_not_found")
    previous = report.status
    if previous != body.status:
        report.status = body.status
        if body.status in (ReportStatus.ACTIONED, ReportStatus.DISMISSED):
            report.resolved_by = admin.id
            report.resolved_at = datetime.now(tz=timezone.utc)
        else:
            report.resolved_by = None
            report.resolved_at = None
        await AuditService.log_request(
            request,
            user_id=admin.id,
            action=AuditAction.REPORT_STATUS_CHANGED,
            resource_type="report",
            resource_id=report.id,
            db=db,
            metadata={"from": str(previous), "to": str(body.status)},
        )
        await db.commit()
        await db.refresh(report)
    return ReportOut.model_validate(report)
