from __future__ import annotations

import logging
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
    AUDIT_PAGE_SIZE,
    RATE_LIMIT_AUDIT_READS_PER_MINUTE,
    REPORTS_PAGE_SIZE,
)
from app.core.dependencies import require_super_admin
from app.core.enums import AuditAction, OrgStatus, ReportStatus, UserRole, WsEventServer
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.db.redis import get_redis
from app.models import Organization, Report, User
from app.schemas.admin_auth import AdminLoginIn
from app.schemas.compliance import AuditPage, AuditRowOut
from app.services.compliance_service import AuditQueryService
from app.schemas.auth import TokenPair
from app.schemas.network import ReportOut, ReportStatusIn
from app.schemas.organization import OrgApproveIn, OrgOut, OrgRejectIn
from app.services.audit_service import AuditService
from app.services.admin_auth_service import AdminAuthError, AdminAuthService
from app.api.v1.orgs import effective_policies, publish_org_updated
from app.services.org_service import OrgError, OrgService
from app.api.ws_manager import ws_manager
from app.schemas.message import MessageOut
from app.schemas.moderation import UserModerationOut, UserSuspendIn
from app.services.file_service import FileService
from app.services.message_service import MessageError, MessageService
from app.services.session_service import SessionService

logger = logging.getLogger("doqto.admin")

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


# --- Moderation actions (App Store 1.2: act on a report) --------------------- #


async def _moderation_target(user_id: uuid.UUID, db: AsyncSession) -> User:
    target = await db.get(User, user_id)
    if target is None or target.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="user_not_found")
    return target


def _moderation_out(target: User) -> UserModerationOut:
    return UserModerationOut(
        id=target.id,
        suspended_at=target.suspended_at,
        suspended_reason=target.suspended_reason,
    )


@router.post(ApiRoutes.ADMIN_USER_SUSPEND, response_model=UserModerationOut)
async def suspend_user(
    user_id: uuid.UUID,
    body: UserSuspendIn,
    request: Request,
    admin: User = Depends(require_super_admin),
    redis: Redis = Depends(get_redis),
    db: AsyncSession = Depends(get_db),
) -> UserModerationOut:
    """Lock an account: every device is signed out, and sign-in, the API and
    the socket answer `account_suspended` until it is lifted. Nothing is
    erased. Suspending an already-suspended account is a no-op."""
    target = await _moderation_target(user_id, db)
    if target.role == UserRole.SUPER_ADMIN:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="cannot_suspend_super_admin")
    if target.suspended_at is not None:
        return _moderation_out(target)
    target.suspended_at = datetime.now(tz=timezone.utc)
    target.suspended_reason = body.reason
    revoked = await SessionService.revoke_others(
        user_id=target.id, keep_jti=None, redis=redis, db=db
    )
    await AuditService.log_request(
        request,
        user_id=admin.id,
        action=AuditAction.USER_SUSPENDED,
        resource_type="user",
        resource_id=target.id,
        db=db,
        metadata={
            "admin_id": str(admin.id),
            "reason": body.reason,
            "sessions_revoked": len(revoked),
        },
    )
    out = _moderation_out(target)
    await db.commit()
    # Open apps hear it right away and return to sign-in.
    await SessionService.publish_revoked(target.id, [r.id for r in revoked])
    return out


@router.post(ApiRoutes.ADMIN_USER_UNSUSPEND, response_model=UserModerationOut)
async def unsuspend_user(
    user_id: uuid.UUID,
    request: Request,
    admin: User = Depends(require_super_admin),
    db: AsyncSession = Depends(get_db),
) -> UserModerationOut:
    """Lift a suspension. The user signs in again normally (their sessions
    were revoked when it was applied). A no-op when not suspended."""
    target = await _moderation_target(user_id, db)
    if target.suspended_at is None:
        return _moderation_out(target)
    previous_reason = target.suspended_reason
    target.suspended_at = None
    target.suspended_reason = None
    await AuditService.log_request(
        request,
        user_id=admin.id,
        action=AuditAction.USER_UNSUSPENDED,
        resource_type="user",
        resource_id=target.id,
        db=db,
        metadata={"admin_id": str(admin.id), "reason": previous_reason},
    )
    out = _moderation_out(target)
    await db.commit()
    return out


@router.post(ApiRoutes.ADMIN_MESSAGE_REMOVE, response_model=MessageOut)
async def remove_message(
    message_id: uuid.UUID,
    admin: User = Depends(require_super_admin),
    db: AsyncSession = Depends(get_db),
) -> MessageOut:
    """Remove a reported message for everyone: the same tombstone, realtime
    event and legal-hold behaviour as the sender's own delete, at any age.
    The response is the tombstone — never the body. Idempotent."""
    try:
        msg, s3_keys, removed = await MessageService.remove_message_as_operator(
            message_id=message_id, admin_id=admin.id, db=db
        )
    except MessageError as e:
        code = (
            status.HTTP_404_NOT_FOUND
            if str(e) == "message_not_found"
            else status.HTTP_409_CONFLICT
        )
        raise HTTPException(code, detail=str(e)) from e
    out = (await MessageService.outs_for([msg], db=db))[0]
    if not removed:
        return out
    recipients = await MessageService.member_ids(conversation_id=msg.conversation_id, db=db)
    await db.commit()
    await ws_manager.publish_to_users(
        recipients, WsEventServer.MESSAGE_DELETED, out.model_dump(mode="json")
    )
    for s3_key in s3_keys:
        # Best-effort, as in the sender's delete: the row is already shredded.
        try:
            await FileService.delete_object(key=s3_key)
        except Exception:
            logger.warning("s3 delete failed for %s", s3_key)
    return out


# --- Audit read (batch 7) ------------------------------------------------------ #


@router.get(ApiRoutes.ADMIN_AUDIT, response_model=AuditPage)
async def read_audit(
    request: Request,
    user_id: uuid.UUID | None = Query(default=None),
    action: str | None = Query(default=None, max_length=100),
    since: datetime | None = Query(default=None, alias="from"),
    until: datetime | None = Query(default=None, alias="to"),
    cursor: int | None = Query(default=None, ge=1),
    limit: int = Query(default=AUDIT_PAGE_SIZE, ge=1, le=AUDIT_PAGE_SIZE),
    admin: User = Depends(require_super_admin),
    db: AsyncSession = Depends(get_db),
) -> AuditPage:
    """The whole trail, newest first by `seq`; `cursor` = last seq seen.
    Rows hold ids and small metadata — never message bodies. Reading the
    trail is itself audited."""
    await enforce_rate_limit(admin.id, "admin_audit", RATE_LIMIT_AUDIT_READS_PER_MINUTE)
    rows, next_cursor = await AuditQueryService.page(
        db=db, user_id=user_id, action=action, since=since, until=until, cursor=cursor, limit=limit
    )
    await AuditService.log_request(
        request,
        user_id=admin.id,
        action=AuditAction.AUDIT_READ,
        metadata={
            "scope": "global",
            "count": len(rows),
            "cursor": cursor,
            "user_id": str(user_id) if user_id else None,
            "action": action,
        },
    )
    return AuditPage(
        data=[
            AuditRowOut(
                id=r.id,
                seq=r.seq,
                user_id=r.user_id,
                action=r.action,
                resource_type=r.resource_type,
                resource_id=r.resource_id,
                ip_address=str(r.ip_address) if r.ip_address else None,
                user_agent=r.user_agent,
                metadata=r.meta,
                prev_hash=r.prev_hash,
                hash=r.hash,
                created_at=r.created_at,
            )
            for r in rows
        ],
        next_cursor=next_cursor,
    )
