"""Compliance (batch 7): org policies, retention + legal hold, break-glass
access requests, the audit read API and org-scoped moderation.

Nothing here returns message bodies except `BreakGlassService.page()`, which
is the audited emergency-read path and the only reason this module imports
`MessageService.to_out`.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import and_, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    ACCESS_REQUEST_WINDOW_SEC,
    AUDIT_PAGE_SIZE,
    BREAK_GLASS_SYSTEM_TEXT,
    DISAPPEAR_OPTIONS_SEC,
    MESSAGES_PAGE_SIZE,
    ORG_POLICY_BOOL_KEYS,
    ORG_POLICY_DEFAULT_DISAPPEAR_SEC,
    ORG_POLICY_DEFAULTS,
    ORG_POLICY_LEGAL_HOLD,
    ORG_POLICY_RETENTION_DAYS,
    RETENTION_DAYS_MAX,
    RETENTION_DAYS_MIN,
)
from app.core.enums import AccessRequestStatus, AuditAction, OrgRole, ReportSubjectType
from app.models import (
    AccessRequest,
    AuditLog,
    Conversation,
    ConversationMember,
    Message,
    Organization,
    OrgMember,
    Report,
)
from app.services.audit_service import AuditService


class ComplianceError(Exception):
    pass


COMPLIANCE_ERROR_STATUS = {
    "org_not_found": 404,
    "conversation_not_found": 404,
    "access_request_not_found": 404,
    "report_not_found": 404,
    "self_approval_forbidden": 403,
    "not_requester": 403,
    "access_request_not_approved": 403,
    "access_request_expired": 403,
    "access_request_not_pending": 409,
    "access_request_pending_exists": 409,
    "invalid_policy_value": 422,
    "reason_required": 422,
}


def _now() -> datetime:
    return datetime.now(tz=timezone.utc)


# ------------------------------------------------------------------ policies --


def effective_policies(org: Organization | None) -> dict[str, Any]:
    """Every policy key with the default filled in."""
    return {**ORG_POLICY_DEFAULTS, **((org.policies if org is not None else None) or {})}


class PolicyService:
    @staticmethod
    def validate(changes: dict[str, Any]) -> dict[str, Any]:
        """Type-check a partial policy update; returns the cleaned dict."""
        clean: dict[str, Any] = {}
        for key, value in changes.items():
            if key not in ORG_POLICY_DEFAULTS:
                raise ComplianceError("invalid_policy_value")
            if key in ORG_POLICY_BOOL_KEYS:
                if not isinstance(value, bool):
                    raise ComplianceError("invalid_policy_value")
            elif key == ORG_POLICY_DEFAULT_DISAPPEAR_SEC:
                if value is not None and value not in DISAPPEAR_OPTIONS_SEC:
                    raise ComplianceError("invalid_policy_value")
            elif key == ORG_POLICY_RETENTION_DAYS:
                if value is not None and not (
                    isinstance(value, int) and RETENTION_DAYS_MIN <= value <= RETENTION_DAYS_MAX
                ):
                    raise ComplianceError("invalid_policy_value")
            clean[key] = value
        return clean

    @staticmethod
    async def apply(
        *,
        org: Organization,
        changes: dict[str, Any],
        admin_id: uuid.UUID,
        db: AsyncSession,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ) -> dict[str, Any]:
        """Merge validated changes into `org.policies` (copy-on-write so the
        JSONB column is marked dirty). Audited as ORG_POLICY_CHANGED with the
        keys that actually changed. Returns the diff."""
        current = dict(org.policies or {})
        effective = effective_policies(org)
        diff = {k: v for k, v in changes.items() if effective.get(k) != v}
        if not diff:
            return {}
        current.update(diff)
        org.policies = current
        await db.flush()
        await AuditService.log(
            db,
            user_id=admin_id,
            action=AuditAction.ORG_POLICY_CHANGED,
            resource_type="organization",
            resource_id=org.id,
            ip_address=ip_address,
            user_agent=user_agent,
            metadata=diff,
        )
        return diff

    @staticmethod
    async def default_disappear_for_org(org_id: uuid.UUID | None, db: AsyncSession) -> int | None:
        if org_id is None:
            return None
        org = await db.get(Organization, org_id)
        value = effective_policies(org).get(ORG_POLICY_DEFAULT_DISAPPEAR_SEC)
        return value if value in DISAPPEAR_OPTIONS_SEC else None

    @staticmethod
    async def banner_preview_default(user_id: uuid.UUID, db: AsyncSession) -> bool:
        """Effective default for a user's unset banner-preview toggles: on
        with no org; with orgs, on only if EVERY org allows it."""
        rows = (
            await db.execute(
                select(Organization.policies)
                .join(OrgMember, OrgMember.org_id == Organization.id)
                .where(OrgMember.user_id == user_id)
            )
        ).scalars().all()
        if not rows:
            return True
        key = "show_preview_in_banners_default"
        return all(bool((p or {}).get(key, ORG_POLICY_DEFAULTS[key])) for p in rows)


# ----------------------------------------------------- retention / legal hold --


def legal_hold_org_ids():
    """Subquery: ids of orgs whose `legal_hold` policy is on."""
    return select(Organization.id).where(
        Organization.policies[ORG_POLICY_LEGAL_HOLD].as_boolean().is_(True)
    )


def held_conversation_ids():
    """Subquery: conversations whose org is under legal hold. Shred paths
    (purge, delete-for-everyone, account deletion) exclude these."""
    return select(Conversation.id).where(Conversation.org_id.in_(legal_hold_org_ids()))


def not_under_legal_hold():
    """Filter clause for Message queries."""
    return Message.conversation_id.not_in(held_conversation_ids())


class RetentionService:
    @staticmethod
    async def is_held(conv: Conversation | None, db: AsyncSession) -> bool:
        if conv is None or conv.org_id is None:
            return False
        org = await db.get(Organization, conv.org_id)
        return bool(effective_policies(org).get(ORG_POLICY_LEGAL_HOLD))

    @staticmethod
    async def apply(db: AsyncSession) -> dict[uuid.UUID, int]:
        """Mark messages older than each org's `retention_days` as expired
        (hidden immediately; the content shred follows the normal 30-day
        grace in `purge_content`). Orgs under legal hold are skipped. Returns
        {org_id: rows} for the orgs that had any."""
        orgs = (
            await db.scalars(
                select(Organization).where(
                    Organization.policies[ORG_POLICY_RETENTION_DAYS].as_integer().is_not(None)
                )
            )
        ).all()
        touched: dict[uuid.UUID, int] = {}
        now = _now()
        for org in orgs:
            pol = effective_policies(org)
            days = pol.get(ORG_POLICY_RETENTION_DAYS)
            if not isinstance(days, int) or days < RETENTION_DAYS_MIN or pol.get(ORG_POLICY_LEGAL_HOLD):
                continue
            cutoff = now - timedelta(days=days)
            result = await db.execute(
                update(Message)
                .where(
                    Message.conversation_id.in_(
                        select(Conversation.id).where(Conversation.org_id == org.id)
                    ),
                    Message.is_deleted.is_(False),
                    Message.created_at < cutoff,
                )
                .values(
                    is_deleted=True,
                    expires_at=func.least(func.coalesce(Message.expires_at, now), now),
                )
            )
            if result.rowcount:
                touched[org.id] = result.rowcount
                await AuditService.log(
                    db,
                    user_id=None,
                    action=AuditAction.RETENTION_APPLIED,
                    resource_type="organization",
                    resource_id=org.id,
                    metadata={"retention_days": days, "messages": result.rowcount},
                )
        return touched


# --------------------------------------------------------------- break-glass --


class BreakGlassService:
    @staticmethod
    async def _org_admin_ids(org_id: uuid.UUID, db: AsyncSession) -> list[uuid.UUID]:
        rows = await db.scalars(
            select(OrgMember.user_id).where(
                OrgMember.org_id == org_id, OrgMember.org_role == OrgRole.ADMIN
            )
        )
        return list(rows.all())

    @staticmethod
    async def _conversation_involves_org(
        conversation_id: uuid.UUID, org_id: uuid.UUID, db: AsyncSession
    ) -> Conversation | None:
        """The conversation, if it is the org's own or has at least one org
        member in it; None otherwise (reported as 404 — no oracle)."""
        conv = await db.get(Conversation, conversation_id)
        if conv is None:
            return None
        if conv.org_id == org_id:
            return conv
        involved = await db.scalar(
            select(ConversationMember.user_id)
            .join(OrgMember, OrgMember.user_id == ConversationMember.user_id)
            .where(
                ConversationMember.conversation_id == conversation_id,
                OrgMember.org_id == org_id,
            )
            .limit(1)
        )
        return conv if involved is not None else None

    @staticmethod
    async def create(
        *,
        org_id: uuid.UUID,
        requester_id: uuid.UUID,
        conversation_id: uuid.UUID,
        reason: str,
        db: AsyncSession,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ) -> tuple[AccessRequest, list[uuid.UUID]]:
        """Returns (request, other admins to notify)."""
        reason = (reason or "").strip()
        if not reason:
            raise ComplianceError("reason_required")
        conv = await BreakGlassService._conversation_involves_org(conversation_id, org_id, db)
        if conv is None:
            raise ComplianceError("conversation_not_found")
        pending = await db.scalar(
            select(AccessRequest.id).where(
                AccessRequest.org_id == org_id,
                AccessRequest.requester_id == requester_id,
                AccessRequest.conversation_id == conversation_id,
                AccessRequest.status == AccessRequestStatus.PENDING,
            )
        )
        if pending is not None:
            raise ComplianceError("access_request_pending_exists")
        row = AccessRequest(
            org_id=org_id,
            conversation_id=conversation_id,
            requester_id=requester_id,
            reason=reason,
        )
        db.add(row)
        await db.flush()
        await AuditService.log(
            db,
            user_id=requester_id,
            action=AuditAction.ACCESS_REQUEST_CREATED,
            resource_type="access_request",
            resource_id=row.id,
            ip_address=ip_address,
            user_agent=user_agent,
            metadata={"org_id": str(org_id), "conversation_id": str(conversation_id)},
        )
        admins = [a for a in await BreakGlassService._org_admin_ids(org_id, db) if a != requester_id]
        return row, admins

    @staticmethod
    async def get(org_id: uuid.UUID, request_id: uuid.UUID, db: AsyncSession) -> AccessRequest:
        row = await db.get(AccessRequest, request_id)
        if row is None or row.org_id != org_id:
            raise ComplianceError("access_request_not_found")
        return row

    @staticmethod
    def effective_status(row: AccessRequest) -> AccessRequestStatus:
        """Approved-but-lapsed reads as expired before the job stamps it."""
        if (
            row.status == AccessRequestStatus.APPROVED
            and row.expires_at is not None
            and row.expires_at <= _now()
        ):
            return AccessRequestStatus.EXPIRED
        return AccessRequestStatus(row.status)

    @staticmethod
    async def decide(
        *,
        org_id: uuid.UUID,
        request_id: uuid.UUID,
        admin_id: uuid.UUID,
        approve: bool,
        db: AsyncSession,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ) -> AccessRequest:
        row = await BreakGlassService.get(org_id, request_id, db)
        if row.requester_id == admin_id:
            raise ComplianceError("self_approval_forbidden")
        if row.status != AccessRequestStatus.PENDING:
            raise ComplianceError("access_request_not_pending")
        now = _now()
        row.status = AccessRequestStatus.APPROVED if approve else AccessRequestStatus.REJECTED
        row.decided_by = admin_id
        row.decided_at = now
        row.expires_at = now + timedelta(seconds=ACCESS_REQUEST_WINDOW_SEC) if approve else None
        await db.flush()
        await AuditService.log(
            db,
            user_id=admin_id,
            action=(
                AuditAction.ACCESS_REQUEST_APPROVED if approve else AuditAction.ACCESS_REQUEST_REJECTED
            ),
            resource_type="access_request",
            resource_id=row.id,
            ip_address=ip_address,
            user_agent=user_agent,
            metadata={
                "org_id": str(org_id),
                "conversation_id": str(row.conversation_id),
                "requester_id": str(row.requester_id),
            },
        )
        return row

    @staticmethod
    async def list(
        *, org_id: uuid.UUID, db: AsyncSession, cursor: datetime | None, limit: int
    ) -> list[AccessRequest]:
        stmt = select(AccessRequest).where(AccessRequest.org_id == org_id)
        if cursor is not None:
            stmt = stmt.where(AccessRequest.created_at < cursor)
        rows = await db.scalars(stmt.order_by(AccessRequest.created_at.desc()).limit(limit))
        return list(rows.all())

    @staticmethod
    async def page(
        *,
        org_id: uuid.UUID,
        request_id: uuid.UUID,
        reader_id: uuid.UUID,
        before_seq: int | None,
        limit: int,
        db: AsyncSession,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ):
        """One page of the conversation, newest first, decrypted — including
        rows tombstoned under legal hold (content kept) but never rows the
        purge already shredded. Audited BREAK_GLASS_READ per page. Returns
        (messages, next_cursor, system_message_or_None): the first page ever
        read posts the policy line into the conversation."""
        from app.services.message_service import MessageService

        row = await BreakGlassService.get(org_id, request_id, db)
        if row.requester_id != reader_id:
            raise ComplianceError("not_requester")
        state = BreakGlassService.effective_status(row)
        if state == AccessRequestStatus.EXPIRED:
            raise ComplianceError("access_request_expired")
        if state != AccessRequestStatus.APPROVED:
            raise ComplianceError("access_request_not_approved")

        limit = min(limit, MESSAGES_PAGE_SIZE)
        stmt = select(Message).where(
            Message.conversation_id == row.conversation_id,
            Message.is_deleted.is_(False),
        )
        if before_seq is not None:
            stmt = stmt.where(Message.seq < before_seq)
        msgs = list(
            (await db.execute(stmt.order_by(Message.seq.desc()).limit(limit + 1))).scalars().all()
        )
        next_cursor = None
        if len(msgs) > limit:
            msgs = msgs[:limit]
            next_cursor = str(msgs[-1].seq)
        outs = [MessageService.to_out(m, reveal_deleted=True) for m in msgs]

        system_msg = None
        if row.first_read_at is None:
            row.first_read_at = _now()
            conv = await db.get(Conversation, row.conversation_id)
            system_msg = await MessageService.send_system(
                conv=conv, sender_id=reader_id, content=BREAK_GLASS_SYSTEM_TEXT, db=db
            )
        await AuditService.log(
            db,
            user_id=reader_id,
            action=AuditAction.BREAK_GLASS_READ,
            resource_type="conversation",
            resource_id=row.conversation_id,
            ip_address=ip_address,
            user_agent=user_agent,
            metadata={
                "access_request_id": str(row.id),
                "org_id": str(org_id),
                "before_seq": before_seq,
                "count": len(outs),
            },
        )
        return outs, next_cursor, system_msg

    @staticmethod
    async def expire(db: AsyncSession) -> list[AccessRequest]:
        """Job: stamp approved requests past their window as expired."""
        rows = (
            await db.scalars(
                select(AccessRequest).where(
                    AccessRequest.status == AccessRequestStatus.APPROVED,
                    AccessRequest.expires_at <= _now(),
                )
            )
        ).all()
        for r in rows:
            r.status = AccessRequestStatus.EXPIRED
        if rows:
            await db.flush()
        return list(rows)


# ------------------------------------------------------------------- audit --


class AuditQueryService:
    @staticmethod
    async def page(
        *,
        db: AsyncSession,
        user_id: uuid.UUID | None = None,
        action: str | None = None,
        since: datetime | None = None,
        until: datetime | None = None,
        cursor: int | None = None,
        limit: int = AUDIT_PAGE_SIZE,
        org_id: uuid.UUID | None = None,
    ) -> tuple[list[AuditLog], int | None]:
        """Newest first by `seq`; `cursor` is the last seq seen. With `org_id`
        the rows are restricted to the org's members acting on org-scoped
        resources (the org itself, its memberships, its conversations and
        their messages, its access requests)."""
        stmt = select(AuditLog).where(AuditLog.seq.is_not(None))
        if user_id is not None:
            stmt = stmt.where(AuditLog.user_id == user_id)
        if action is not None:
            stmt = stmt.where(AuditLog.action == action)
        if since is not None:
            stmt = stmt.where(AuditLog.created_at >= since)
        if until is not None:
            stmt = stmt.where(AuditLog.created_at < until)
        if cursor is not None:
            stmt = stmt.where(AuditLog.seq < cursor)
        if org_id is not None:
            members = select(OrgMember.user_id).where(OrgMember.org_id == org_id)
            org_convs = select(Conversation.id).where(Conversation.org_id == org_id)
            org_msgs = select(Message.id).where(Message.conversation_id.in_(org_convs))
            org_requests = select(AccessRequest.id).where(AccessRequest.org_id == org_id)
            stmt = stmt.where(
                AuditLog.user_id.in_(members),
                or_(
                    and_(
                        AuditLog.resource_type == "organization", AuditLog.resource_id == org_id
                    ),
                    and_(
                        AuditLog.resource_type == "org_member", AuditLog.resource_id.in_(members)
                    ),
                    and_(
                        AuditLog.resource_type == "conversation",
                        AuditLog.resource_id.in_(org_convs),
                    ),
                    and_(AuditLog.resource_type == "message", AuditLog.resource_id.in_(org_msgs)),
                    and_(
                        AuditLog.resource_type == "access_request",
                        AuditLog.resource_id.in_(org_requests),
                    ),
                ),
            )
        limit = min(limit, AUDIT_PAGE_SIZE)
        rows = list((await db.scalars(stmt.order_by(AuditLog.seq.desc()).limit(limit + 1))).all())
        next_cursor = None
        if len(rows) > limit:
            rows = rows[:limit]
            next_cursor = rows[-1].seq
        return rows, next_cursor


# ------------------------------------------------------------- org reports --


class OrgReportService:
    @staticmethod
    def _scope(org_id: uuid.UUID):
        members = select(OrgMember.user_id).where(OrgMember.org_id == org_id)
        member_messages = select(Message.id).where(Message.sender_id.in_(members))
        return or_(
            Report.reporter_id.in_(members),
            and_(
                Report.subject_type == ReportSubjectType.USER.value, Report.subject_id.in_(members)
            ),
            and_(
                Report.subject_type == ReportSubjectType.MESSAGE.value,
                Report.subject_id.in_(member_messages),
            ),
        )

    @staticmethod
    async def list(
        *,
        org_id: uuid.UUID,
        db: AsyncSession,
        status_filter: str,
        cursor: datetime | None,
        limit: int,
    ) -> list[Report]:
        stmt = select(Report).where(OrgReportService._scope(org_id))
        if status_filter != "all":
            stmt = stmt.where(Report.status == status_filter)
        if cursor is not None:
            stmt = stmt.where(Report.created_at < cursor)
        rows = await db.scalars(stmt.order_by(Report.created_at.desc()).limit(limit))
        return list(rows.all())

    @staticmethod
    async def get(*, org_id: uuid.UUID, report_id: uuid.UUID, db: AsyncSession) -> Report:
        row = await db.scalar(
            select(Report).where(Report.id == report_id, OrgReportService._scope(org_id))
        )
        if row is None:
            raise ComplianceError("report_not_found")
        return row

