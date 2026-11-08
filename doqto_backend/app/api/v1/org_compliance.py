"""Org-admin compliance surface (batch 7), mounted under /orgs like orgs.py:
policies, the org-scoped audit read, break-glass access requests and the
org moderation queue. Nothing here returns a message body except the
audited break-glass page."""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.constants import (
    ACCESS_REQUESTS_PAGE_SIZE,
    AUDIT_PAGE_SIZE,
    MESSAGES_PAGE_SIZE,
    RATE_LIMIT_ACCESS_REQUESTS_PER_MINUTE,
    RATE_LIMIT_AUDIT_READS_PER_MINUTE,
    RATE_LIMIT_POLICY_WRITES_PER_MINUTE,
    RATE_LIMIT_READS_PER_MINUTE,
    REPORTS_PAGE_SIZE,
)
from app.core.dependencies import require_org_admin, require_org_member
from app.core.enums import AuditAction, ReportStatus, WsEventServer
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.models import AccessRequest, OrgMember, Organization
from app.schemas.compliance import (
    AccessRequestCreateIn,
    AccessRequestOut,
    AccessRequestPage,
    AuditPage,
    AuditRowOut,
    BreakGlassPage,
    OrgPoliciesOut,
    OrgPoliciesPatch,
)
from app.schemas.network import ReportOut, ReportStatusIn
from app.services.audit_service import AuditService, request_meta
from app.services.compliance_service import (
    COMPLIANCE_ERROR_STATUS,
    AuditQueryService,
    BreakGlassService,
    ComplianceError,
    OrgReportService,
    PolicyService,
    effective_policies,
)
from app.services.message_service import MessageService
from app.services.notification_service import (
    TYPE_ACCESS_REQUEST_DECIDED,
    TYPE_ACCESS_REQUEST_PENDING,
    NotificationService,
)
from app.services.push_service import PushService

router = APIRouter()


def _http(e: ComplianceError) -> HTTPException:
    code = str(e)
    return HTTPException(COMPLIANCE_ERROR_STATUS.get(code, status.HTTP_400_BAD_REQUEST), detail=code)


async def _org(org_id: uuid.UUID, db: AsyncSession) -> Organization:
    org = await db.get(Organization, org_id)
    if org is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="org_not_found")
    return org


def _request_out(row: AccessRequest) -> AccessRequestOut:
    out = AccessRequestOut.model_validate(row)
    out.status = BreakGlassService.effective_status(row)
    return out


async def _publish_request(row: AccessRequest, recipients: list[uuid.UUID]) -> None:
    await ws_manager.publish_to_users(
        list({*recipients}),
        WsEventServer.ACCESS_REQUEST_UPDATED,
        {
            "org_id": str(row.org_id),
            "access_request_id": str(row.id),
            "status": BreakGlassService.effective_status(row).value,
        },
    )


# ----------------------------------------------------------------- policies --


@router.get(ApiRoutes.ORGS_POLICIES, response_model=OrgPoliciesOut)
async def get_policies(
    org_id: uuid.UUID,
    _: OrgMember = Depends(require_org_member),
    db: AsyncSession = Depends(get_db),
) -> OrgPoliciesOut:
    """Effective policies — any member may read them (the app shows a
    read-only "Your organisation's policies" page)."""
    return OrgPoliciesOut(**effective_policies(await _org(org_id, db)))


@router.patch(ApiRoutes.ORGS_POLICIES, response_model=OrgPoliciesOut)
async def patch_policies(
    org_id: uuid.UUID,
    body: OrgPoliciesPatch,
    request: Request,
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> OrgPoliciesOut:
    await enforce_rate_limit(admin.user_id, "org_policies", RATE_LIMIT_POLICY_WRITES_PER_MINUTE)
    org = await _org(org_id, db)
    try:
        changes = PolicyService.validate(body.changes())
        ip, ua = request_meta(request)
        diff = await PolicyService.apply(
            org=org, changes=changes, admin_id=admin.user_id, db=db, ip_address=ip, user_agent=ua
        )
    except ComplianceError as e:
        raise _http(e) from e
    if diff:
        await db.commit()
        from app.api.v1.orgs import publish_org_updated

        await publish_org_updated(org_id, db)
    return OrgPoliciesOut(**effective_policies(org))


# -------------------------------------------------------------------- audit --


@router.get(ApiRoutes.ORGS_AUDIT, response_model=AuditPage)
async def org_audit(
    org_id: uuid.UUID,
    request: Request,
    user_id: uuid.UUID | None = Query(default=None),
    action: str | None = Query(default=None, max_length=100),
    since: datetime | None = Query(default=None, alias="from"),
    until: datetime | None = Query(default=None, alias="to"),
    cursor: int | None = Query(default=None, ge=1),
    limit: int = Query(default=AUDIT_PAGE_SIZE, ge=1, le=AUDIT_PAGE_SIZE),
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> AuditPage:
    """Members' actions on org-scoped resources. No IP / user agent, never
    message bodies (the trail holds ids only)."""
    await enforce_rate_limit(admin.user_id, "org_audit", RATE_LIMIT_AUDIT_READS_PER_MINUTE)
    rows, next_cursor = await AuditQueryService.page(
        db=db,
        user_id=user_id,
        action=action,
        since=since,
        until=until,
        cursor=cursor,
        limit=limit,
        org_id=org_id,
    )
    await AuditService.log_request(
        request,
        user_id=admin.user_id,
        action=AuditAction.AUDIT_READ,
        resource_type="organization",
        resource_id=org_id,
        metadata={"scope": "org", "count": len(rows), "cursor": cursor},
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
                metadata=r.meta,
                prev_hash=r.prev_hash,
                hash=r.hash,
                created_at=r.created_at,
            )
            for r in rows
        ],
        next_cursor=next_cursor,
    )


# ------------------------------------------------------------ break-glass --


@router.get(ApiRoutes.ORGS_ACCESS_REQUESTS, response_model=AccessRequestPage)
async def list_access_requests(
    org_id: uuid.UUID,
    cursor: datetime | None = Query(default=None),
    limit: int = Query(default=ACCESS_REQUESTS_PAGE_SIZE, ge=1, le=ACCESS_REQUESTS_PAGE_SIZE),
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> AccessRequestPage:
    await enforce_rate_limit(admin.user_id, "access_requests_list", RATE_LIMIT_READS_PER_MINUTE)
    rows = await BreakGlassService.list(org_id=org_id, db=db, cursor=cursor, limit=limit)
    return AccessRequestPage(
        data=[_request_out(r) for r in rows],
        next_cursor=rows[-1].created_at if len(rows) == limit else None,
    )


@router.post(
    ApiRoutes.ORGS_ACCESS_REQUESTS,
    response_model=AccessRequestOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_access_request(
    org_id: uuid.UUID,
    body: AccessRequestCreateIn,
    request: Request,
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> AccessRequestOut:
    """An org admin asks to read a conversation that involves their members.
    Every OTHER admin of the org is notified (feed + WS + PHI-free push)."""
    await enforce_rate_limit(
        admin.user_id, "access_requests_create", RATE_LIMIT_ACCESS_REQUESTS_PER_MINUTE
    )
    ip, ua = request_meta(request)
    try:
        row, others = await BreakGlassService.create(
            org_id=org_id,
            requester_id=admin.user_id,
            conversation_id=body.conversation_id,
            reason=body.reason,
            db=db,
            ip_address=ip,
            user_agent=ua,
        )
    except ComplianceError as e:
        raise _http(e) from e
    notes = [
        await NotificationService.create(
            db=db,
            user_id=uid,
            type=TYPE_ACCESS_REQUEST_PENDING,
            actor_id=admin.user_id,
            subject_type="access_request",
            subject_id=row.id,
            payload={"org_id": str(org_id)},
        )
        for uid in others
    ]
    await db.commit()
    for n in notes:
        await NotificationService.publish(
            notification=n, unread_count=await NotificationService.unread_count(db=db, user_id=n.user_id)
        )
        PushService.notify_access_request(recipient_id=n.user_id, request_id=row.id, pending=True)
    await _publish_request(row, [*others, admin.user_id])
    return _request_out(row)


async def _decide(
    org_id: uuid.UUID,
    request_id: uuid.UUID,
    request: Request,
    admin: OrgMember,
    db: AsyncSession,
    *,
    approve: bool,
) -> AccessRequestOut:
    ip, ua = request_meta(request)
    try:
        row = await BreakGlassService.decide(
            org_id=org_id,
            request_id=request_id,
            admin_id=admin.user_id,
            approve=approve,
            db=db,
            ip_address=ip,
            user_agent=ua,
        )
    except ComplianceError as e:
        raise _http(e) from e
    note = await NotificationService.create(
        db=db,
        user_id=row.requester_id,
        type=TYPE_ACCESS_REQUEST_DECIDED,
        actor_id=admin.user_id,
        subject_type="access_request",
        subject_id=row.id,
        payload={"org_id": str(org_id), "approved": approve},
    )
    await db.commit()
    await NotificationService.publish(
        notification=note,
        unread_count=await NotificationService.unread_count(db=db, user_id=row.requester_id),
    )
    PushService.notify_access_request(
        recipient_id=row.requester_id, request_id=row.id, pending=False, approved=approve
    )
    await _publish_request(row, [row.requester_id, admin.user_id])
    return _request_out(row)


@router.post(ApiRoutes.ORGS_ACCESS_REQUEST_APPROVE, response_model=AccessRequestOut)
async def approve_access_request(
    org_id: uuid.UUID,
    request_id: uuid.UUID,
    request: Request,
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> AccessRequestOut:
    """A different org admin opens the 24 h window. Self-approval is 403."""
    await enforce_rate_limit(
        admin.user_id, "access_requests_decide", RATE_LIMIT_ACCESS_REQUESTS_PER_MINUTE
    )
    return await _decide(org_id, request_id, request, admin, db, approve=True)


@router.post(ApiRoutes.ORGS_ACCESS_REQUEST_REJECT, response_model=AccessRequestOut)
async def reject_access_request(
    org_id: uuid.UUID,
    request_id: uuid.UUID,
    request: Request,
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> AccessRequestOut:
    await enforce_rate_limit(
        admin.user_id, "access_requests_decide", RATE_LIMIT_ACCESS_REQUESTS_PER_MINUTE
    )
    return await _decide(org_id, request_id, request, admin, db, approve=False)


@router.get(ApiRoutes.ORGS_ACCESS_REQUEST_MESSAGES, response_model=BreakGlassPage)
async def read_access_request_messages(
    org_id: uuid.UUID,
    request_id: uuid.UUID,
    request: Request,
    cursor: int | None = Query(default=None, ge=1),
    limit: int = Query(default=MESSAGES_PAGE_SIZE, ge=1, le=MESSAGES_PAGE_SIZE),
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> BreakGlassPage:
    """The requester's time-boxed, page-audited read. The first page posts
    the policy line into the conversation for its members."""
    await enforce_rate_limit(admin.user_id, "break_glass_read", RATE_LIMIT_READS_PER_MINUTE)
    ip, ua = request_meta(request)
    try:
        outs, next_cursor, system_msg = await BreakGlassService.page(
            org_id=org_id,
            request_id=request_id,
            reader_id=admin.user_id,
            before_seq=cursor,
            limit=limit,
            db=db,
            ip_address=ip,
            user_agent=ua,
        )
    except ComplianceError as e:
        raise _http(e) from e
    recipients: list[uuid.UUID] = []
    sys_out = None
    if system_msg is not None:
        sys_out = MessageService.to_out(system_msg)
        recipients = await MessageService.member_ids(conversation_id=system_msg.conversation_id, db=db)
    await db.commit()
    if sys_out is not None:
        await ws_manager.publish_to_users(
            recipients, WsEventServer.NEW_MESSAGE, sys_out.model_dump(mode="json")
        )
    return BreakGlassPage(data=outs, next_cursor=next_cursor)


# ----------------------------------------------------------------- reports --


@router.get(ApiRoutes.ORGS_REPORTS, response_model=list[ReportOut])
async def list_org_reports(
    org_id: uuid.UUID,
    status_filter: Literal["open", "reviewing", "actioned", "dismissed", "all"] = Query(
        default="open", alias="status"
    ),
    cursor: datetime | None = Query(default=None),
    limit: int = Query(default=REPORTS_PAGE_SIZE, ge=1, le=REPORTS_PAGE_SIZE),
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> list[ReportOut]:
    """Reports whose reporter or subject (a member, or a member's message)
    belongs to the org. Ids + reason + details only — never bodies."""
    await enforce_rate_limit(admin.user_id, "org_reports", RATE_LIMIT_READS_PER_MINUTE)
    rows = await OrgReportService.list(
        org_id=org_id, db=db, status_filter=status_filter, cursor=cursor, limit=limit
    )
    return [ReportOut.model_validate(r) for r in rows]


@router.patch(ApiRoutes.ORGS_REPORT_DETAIL, response_model=ReportOut)
async def set_org_report_status(
    org_id: uuid.UUID,
    report_id: uuid.UUID,
    body: ReportStatusIn,
    request: Request,
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> ReportOut:
    await enforce_rate_limit(admin.user_id, "org_reports_write", RATE_LIMIT_POLICY_WRITES_PER_MINUTE)
    try:
        report = await OrgReportService.get(org_id=org_id, report_id=report_id, db=db)
    except ComplianceError as e:
        raise _http(e) from e
    previous = report.status
    if previous != body.status:
        report.status = body.status
        if body.status in (ReportStatus.ACTIONED, ReportStatus.DISMISSED):
            report.resolved_by = admin.user_id
            report.resolved_at = datetime.now(tz=timezone.utc)
        else:
            report.resolved_by = None
            report.resolved_at = None
        await AuditService.log_request(
            request,
            user_id=admin.user_id,
            action=AuditAction.REPORT_STATUS_CHANGED,
            resource_type="report",
            resource_id=report.id,
            metadata={"from": str(previous), "to": str(body.status), "org_id": str(org_id)},
        )
        await db.commit()
        await db.refresh(report)
    return ReportOut.model_validate(report)

