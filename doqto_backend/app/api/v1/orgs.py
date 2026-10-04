from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import RATE_LIMIT_READS_PER_MINUTE
from app.core.dependencies import get_current_user, require_org_admin, require_org_member
from app.core.enums import AuditAction
from app.core.rate_limit import enforce_rate_limit
from app.core.redis_keys import presence_key
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.db.redis import get_redis
from app.models import OrgMember, Organization, User
from app.schemas.common import OkResponse
from app.schemas.organization import (
    DirectoryEntryOut,
    DirectoryOrgOut,
    DirectoryRefIn,
    MemberOut,
    OrgCreateIn,
    OrgJoinIn,
    OrgNetworkingSettingsIn,
    OrgNetworkingSettingsOut,
    OrgOut,
)
from app.services.audit_service import AuditService
from app.services.file_service import FileService
from app.services.org_directory_service import DirectoryHit, OrgDirectoryService
from app.services.org_service import ORG_ERROR_STATUS, OrgError, OrgService

router = APIRouter()


def _org_http_error(e: OrgError) -> HTTPException:
    code = str(e)
    return HTTPException(ORG_ERROR_STATUS.get(code, status.HTTP_400_BAD_REQUEST), detail=code)


def _hit_out(hit: DirectoryHit) -> DirectoryEntryOut:
    e = hit.entry
    return DirectoryEntryOut(
        source=e.source,
        source_id=e.source_id,
        name=e.display_name,
        legal_name=e.name,
        city=e.city,
        state=e.state,
        practice_type=e.practice_type,
        member_count=e.member_count,
        you_are_listed=hit.you_are_listed,
        doqto_org=(
            DirectoryOrgOut(id=hit.doqto_org.id, name=hit.doqto_org.name, status=hit.doqto_org.status)
            if hit.doqto_org
            else None
        ),
    )


async def _to_out(org: Organization, db: AsyncSession) -> OrgOut:
    count = await OrgService.member_count(org_id=org.id, db=db)
    out = OrgOut.model_validate(org)
    out.member_count = count
    return out


@router.post(ApiRoutes.ORGS_CREATE, response_model=OrgOut)
async def create_org(
    body: OrgCreateIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OrgOut:
    try:
        org = await OrgService.create(
            user=user,
            name=body.name,
            address=body.address,
            city=body.city,
            state=body.state,
            practice_type=body.practice_type.value if body.practice_type else None,
            directory_source=body.directory_source,
            directory_id=body.directory_id,
            db=db,
        )
    except OrgError as e:
        await db.rollback()
        raise _org_http_error(e) from e
    return await _to_out(org, db)


# Directory routes sit above /{org_id} so "directory" is never read as an id.
@router.get(ApiRoutes.ORGS_DIRECTORY_SEARCH, response_model=list[DirectoryEntryOut])
async def search_directory(
    q: str = Query(min_length=2, max_length=100),
    state: str | None = Query(default=None, min_length=2, max_length=2),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[DirectoryEntryOut]:
    await enforce_rate_limit(user.id, "org_directory_search", RATE_LIMIT_READS_PER_MINUTE)
    hits = await OrgDirectoryService.search(db=db, query=q, state=state, npi=user.npi_number)
    return [_hit_out(h) for h in hits]


@router.get(ApiRoutes.ORGS_DIRECTORY_SUGGESTED, response_model=list[DirectoryEntryOut])
async def suggested_directory(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[DirectoryEntryOut]:
    hits = await OrgDirectoryService.suggested(db=db, npi=user.npi_number)
    return [_hit_out(h) for h in hits]


@router.post(ApiRoutes.ORGS_DIRECTORY_JOIN, response_model=OrgOut)
async def join_by_directory(
    body: DirectoryRefIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OrgOut:
    try:
        org = await OrgService.join_by_directory(
            user=user,
            directory_source=body.directory_source,
            directory_id=body.directory_id,
            db=db,
        )
    except OrgError as e:
        raise _org_http_error(e) from e
    return await _to_out(org, db)


@router.get(ApiRoutes.ORGS_MINE, response_model=list[OrgOut])
async def my_orgs(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[OrgOut]:
    """Organizations the current user belongs to. Empty list = needs onboarding."""
    rows = await db.execute(
        select(Organization)
        .join(OrgMember, OrgMember.org_id == Organization.id)
        .where(OrgMember.user_id == user.id)
        .order_by(Organization.created_at.desc())
    )
    return [await _to_out(o, db) for o in rows.scalars().all()]


@router.post(ApiRoutes.ORGS_JOIN, response_model=OrgOut)
async def join_org(
    body: OrgJoinIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OrgOut:
    try:
        org = await OrgService.join(user=user, invite_code=body.invite_code, db=db)
    except OrgError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e
    return await _to_out(org, db)


@router.get(ApiRoutes.ORGS_DETAIL, response_model=OrgOut)
async def get_org(
    org_id: uuid.UUID,
    _: object = Depends(require_org_member),
    db: AsyncSession = Depends(get_db),
) -> OrgOut:
    org = await db.scalar(select(Organization).where(Organization.id == org_id))
    if org is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="org_not_found")
    return await _to_out(org, db)


@router.get(ApiRoutes.ORGS_MEMBERS, response_model=list[MemberOut])
async def list_members(
    org_id: uuid.UUID,
    member: OrgMember = Depends(require_org_member),
    db: AsyncSession = Depends(get_db),
    redis: Redis = Depends(get_redis),
) -> list[MemberOut]:
    await enforce_rate_limit(member.user_id, "list_members", RATE_LIMIT_READS_PER_MINUTE)
    rows = await OrgService.members(org_id=org_id, db=db)
    out: list[MemberOut] = []
    for user, m in rows:
        presence = await redis.get(presence_key(user.id))
        out.append(
            MemberOut(
                id=user.id,
                full_name=user.full_name,
                specialty=user.specialty,
                org_role=m.org_role,
                joined_at=m.joined_at,
                presence=presence,
                avatar_color=user.avatar_color,
                avatar_url=user.avatar_url,
                avatar_presigned_url=(
                    await FileService.presigned_url(key=user.avatar_url)
                    if user.avatar_url
                    else None
                ),
            )
        )
    return out


@router.delete(ApiRoutes.ORGS_MEMBER_DETAIL, response_model=OkResponse)
async def remove_member(
    org_id: uuid.UUID,
    user_id: uuid.UUID,
    admin_member=Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
    current: User = Depends(get_current_user),
) -> OkResponse:
    try:
        await OrgService.remove_member(
            org_id=org_id, target_user_id=user_id, admin=current, db=db
        )
    except OrgError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e
    return OkResponse()


@router.patch(ApiRoutes.ORGS_NETWORKING_SETTINGS, response_model=OrgNetworkingSettingsOut)
async def update_networking_settings(
    org_id: uuid.UUID,
    body: OrgNetworkingSettingsIn,
    request: Request,
    admin: OrgMember = Depends(require_org_admin),
    db: AsyncSession = Depends(get_db),
) -> OrgNetworkingSettingsOut:
    """Org networking kill switch + policy (admin only, audited)."""
    org = await db.scalar(select(Organization).where(Organization.id == org_id))
    if org is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="org_not_found")
    changes: dict[str, str | bool] = {}
    if body.external_networking_enabled is not None:
        org.external_networking_enabled = body.external_networking_enabled
        changes["external_networking_enabled"] = body.external_networking_enabled
    if body.external_dm_policy is not None:
        org.external_dm_policy = body.external_dm_policy
        changes["external_dm_policy"] = body.external_dm_policy.value
    if body.directory_visibility is not None:
        org.directory_visibility = body.directory_visibility
        changes["directory_visibility"] = body.directory_visibility.value
    if changes:
        await AuditService.log_request(
            request,
            user_id=admin.user_id,
            action=AuditAction.ORG_POLICY_CHANGED,
            resource_type="organization",
            resource_id=org_id,
            db=db,
            metadata=changes,
        )
        await db.commit()
        await db.refresh(org)
    return OrgNetworkingSettingsOut.model_validate(org)


@router.get(ApiRoutes.ORGS_INVITE_CODE)
async def get_invite_code(
    org_id: uuid.UUID,
    _: object = Depends(require_org_member),
    db: AsyncSession = Depends(get_db),
) -> dict:
    org = await db.scalar(select(Organization).where(Organization.id == org_id))
    if org is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="org_not_found")
    return {"invite_code": org.invite_code}
