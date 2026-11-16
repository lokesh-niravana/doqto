from __future__ import annotations

import secrets
import string
import uuid
from datetime import datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import INVITE_CODE_DIGITS_LEN, INVITE_CODE_LETTERS_LEN
from app.core.enums import AuditAction, OrgRole, OrgStatus, UserRole
from app.models import OrgMember, Organization, User
from app.services.audit_service import AuditService
from app.services.org_directory_service import OrgDirectoryService


def _generate_invite_code() -> str:
    letters = "".join(secrets.choice(string.ascii_uppercase) for _ in range(INVITE_CODE_LETTERS_LEN))
    digits = "".join(secrets.choice(string.digits) for _ in range(INVITE_CODE_DIGITS_LEN))
    return f"{letters}·{digits}"


class OrgError(Exception):
    pass


# OrgError codes that are not a plain 400.
ORG_ERROR_STATUS = {
    "org_pending_exists": 409,
    "org_exists": 409,
    "npi_not_listed": 403,
    "org_not_found": 404,
}


class OrgService:
    @staticmethod
    async def create(
        *,
        user: User,
        name: str,
        address: str | None,
        city: str | None,
        state: str | None,
        practice_type: str | None,
        db: AsyncSession,
        directory_source: str | None = None,
        directory_id: str | None = None,
    ) -> Organization:
        # One pending org per creator while verification is manual.
        pending = await db.scalar(
            select(Organization.id)
            .join(OrgMember, OrgMember.org_id == Organization.id)
            .where(
                OrgMember.user_id == user.id,
                OrgMember.org_role == OrgRole.ADMIN,
                Organization.status == OrgStatus.PENDING,
            )
            .limit(1)
        )
        if pending is not None:
            raise OrgError("org_pending_exists")

        auto_verify = False
        if directory_source and directory_id:
            entry = await OrgDirectoryService.get(
                db=db, source=directory_source, source_id=directory_id
            )
            if entry is None:
                raise OrgError("directory_entry_not_found")
            if await db.scalar(
                select(Organization.id).where(
                    Organization.directory_source == directory_source,
                    Organization.directory_id == directory_id,
                )
            ):
                raise OrgError("org_exists")
            city = city or entry.city
            state = state or entry.state
            practice_type = practice_type or entry.practice_type
            # The creator's own NPI under that Medicare group is the proof
            # a reviewer would look for, so it verifies on the spot.
            auto_verify = await OrgDirectoryService.is_listed(
                db=db, source=directory_source, source_id=directory_id, npi=user.npi_number
            )
        else:
            directory_source = directory_id = None

        for _ in range(5):
            code = _generate_invite_code()
            if not await db.scalar(select(Organization).where(Organization.invite_code == code)):
                break
        else:
            raise OrgError("invite_code_generation_failed")

        org = Organization(
            name=name,
            address=address,
            city=city,
            state=state,
            practice_type=practice_type,
            invite_code=code,
            status=OrgStatus.ACTIVE if auto_verify else OrgStatus.PENDING,
            directory_source=directory_source,
            directory_id=directory_id,
        )
        if auto_verify:
            org.verified_at = datetime.now(tz=timezone.utc)
            org.review_notes = f"Auto-verified: creator's NPI is listed in CMS group {directory_id}."
        db.add(org)
        try:
            await db.flush()
        except IntegrityError as e:  # lost a race for the same directory entry
            raise OrgError("org_exists") from e
        db.add(OrgMember(org_id=org.id, user_id=user.id, org_role=OrgRole.ADMIN))
        await AuditService.log(
            db,
            user_id=user.id,
            action=AuditAction.ORG_CREATED,
            resource_type="organization",
            resource_id=org.id,
            metadata={"directory": f"{directory_source}:{directory_id}"} if directory_id else None,
        )
        if auto_verify:
            await AuditService.log(
                db,
                user_id=user.id,
                action=AuditAction.ORG_VERIFIED,
                resource_type="organization",
                resource_id=org.id,
                metadata={"decision": "auto", "basis": "creator_npi_in_cms_group"},
            )
        return org

    @staticmethod
    async def join_by_directory(
        *, user: User, directory_source: str, directory_id: str, db: AsyncSession
    ) -> Organization:
        """Join the Doqto org made from a directory entry, without an invite
        code, when CMS lists the user's NPI in that group."""
        org = await db.scalar(
            select(Organization).where(
                Organization.directory_source == directory_source,
                Organization.directory_id == directory_id,
            )
        )
        if org is None:
            raise OrgError("org_not_found")
        if org.status == OrgStatus.SUSPENDED:
            raise OrgError("org_suspended")
        if not await OrgDirectoryService.is_listed(
            db=db, source=directory_source, source_id=directory_id, npi=user.npi_number
        ):
            raise OrgError("npi_not_listed")
        if not await db.scalar(
            select(OrgMember.id).where(OrgMember.org_id == org.id, OrgMember.user_id == user.id)
        ):
            db.add(OrgMember(org_id=org.id, user_id=user.id, org_role=OrgRole.DOCTOR))
            await AuditService.log(
                db,
                user_id=user.id,
                action=AuditAction.ORG_JOINED,
                resource_type="organization",
                resource_id=org.id,
                metadata={"via": "directory"},
            )
        return org

    @staticmethod
    async def join(*, user: User, invite_code: str, db: AsyncSession) -> Organization:
        org = await db.scalar(select(Organization).where(Organization.invite_code == invite_code))
        if org is None:
            raise OrgError("invalid_invite_code")
        if org.status == OrgStatus.SUSPENDED:
            raise OrgError("org_suspended")
        existing = await db.scalar(
            select(OrgMember).where(OrgMember.org_id == org.id, OrgMember.user_id == user.id)
        )
        if existing is not None:
            return org
        db.add(OrgMember(org_id=org.id, user_id=user.id, org_role=OrgRole.DOCTOR))
        await AuditService.log(
            db,
            user_id=user.id,
            action=AuditAction.ORG_JOINED,
            resource_type="organization",
            resource_id=org.id,
        )
        return org

    @staticmethod
    async def verify(
        *,
        org_id: uuid.UUID,
        admin: User,
        db: AsyncSession,
        notes: str | None = None,
    ) -> Organization:
        if admin.role != UserRole.SUPER_ADMIN:
            raise OrgError("super_admin_required")
        org = await db.scalar(select(Organization).where(Organization.id == org_id))
        if org is None:
            raise OrgError("org_not_found")
        org.status = OrgStatus.ACTIVE
        org.verified_at = datetime.now(tz=timezone.utc)
        org.verified_by = admin.id
        if notes:
            org.review_notes = notes
        await AuditService.log(
            db,
            user_id=admin.id,
            action=AuditAction.ORG_VERIFIED,
            resource_type="organization",
            resource_id=org.id,
            metadata={"notes": notes} if notes else None,
        )
        return org

    @staticmethod
    async def reject(
        *,
        org_id: uuid.UUID,
        admin: User,
        reason: str,
        db: AsyncSession,
    ) -> Organization:
        if admin.role != UserRole.SUPER_ADMIN:
            raise OrgError("super_admin_required")
        if not reason or not reason.strip():
            raise OrgError("rejection_reason_required")
        org = await db.scalar(select(Organization).where(Organization.id == org_id))
        if org is None:
            raise OrgError("org_not_found")
        org.status = OrgStatus.SUSPENDED
        org.review_notes = reason.strip()
        org.verified_by = admin.id
        org.verified_at = datetime.now(tz=timezone.utc)
        await AuditService.log(
            db,
            user_id=admin.id,
            action=AuditAction.ORG_VERIFIED,  # reuse existing enum; metadata carries the decision
            resource_type="organization",
            resource_id=org.id,
            metadata={"decision": "rejected", "reason": reason.strip()},
        )
        return org

    @staticmethod
    async def member_count(*, org_id: uuid.UUID, db: AsyncSession) -> int:
        return int(
            await db.scalar(select(func.count()).select_from(OrgMember).where(OrgMember.org_id == org_id))
            or 0
        )

    @staticmethod
    async def members(*, org_id: uuid.UUID, db: AsyncSession) -> list[tuple[User, OrgMember]]:
        rows = await db.execute(
            select(User, OrgMember)
            .join(OrgMember, OrgMember.user_id == User.id)
            .where(OrgMember.org_id == org_id)
            .order_by(User.full_name)
        )
        return list(rows.all())  # type: ignore[return-value]

    @staticmethod
    async def remove_member(
        *, org_id: uuid.UUID, target_user_id: uuid.UUID, admin: User, db: AsyncSession
    ) -> None:
        member = await db.scalar(
            select(OrgMember).where(
                OrgMember.org_id == org_id, OrgMember.user_id == target_user_id
            )
        )
        if member is None:
            raise OrgError("member_not_found")
        await db.delete(member)
        await AuditService.log(
            db,
            user_id=admin.id,
            action=AuditAction.MEMBER_REMOVED,
            resource_type="org_member",
            resource_id=target_user_id,
        )
