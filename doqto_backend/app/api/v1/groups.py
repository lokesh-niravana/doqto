from __future__ import annotations

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import GROUPS_PAGE_SIZE, RATE_LIMIT_READS_PER_MINUTE
from app.core.dependencies import get_current_user
from app.core.enums import GroupInviteState, GroupMemberState, GroupRole
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.models import (
    Group,
    GroupInvite,
    GroupMember,
    User,
)
from app.schemas.common import OkResponse
from app.schemas.group import (
    GroupCardOut,
    GroupCreateIn,
    GroupInviteOut,
    GroupMemberOut,
    GroupOut,
    GroupUpdateIn,
    InviteCreateIn,
    JoinResultOut,
    MemberRoleUpdateIn,
    TransferOwnershipIn,
)
from app.schemas.network import CursorPage
from app.services.group_service import GroupError, GroupService

router = APIRouter()


def _raise(e: GroupError) -> None:
    raise HTTPException(e.status_code, detail=e.code)


def _parse_cursor(cursor: str | None) -> datetime | None:
    if not cursor:
        return None
    try:
        return datetime.fromisoformat(cursor)
    except ValueError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="invalid_cursor") from e


async def _load_group(group_id: uuid.UUID, db: AsyncSession) -> Group:
    group = await db.scalar(select(Group).where(Group.id == group_id))
    if group is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="group_not_found")
    return group


async def _my_membership(
    group: Group, user_id: uuid.UUID, db: AsyncSession
) -> GroupMember | None:
    return await db.scalar(
        select(GroupMember).where(
            GroupMember.group_id == group.id, GroupMember.user_id == user_id
        )
    )


def _is_active(m: GroupMember | None) -> bool:
    return m is not None and m.state == GroupMemberState.ACTIVE


def _detail_out(group: Group, membership: GroupMember | None) -> GroupOut:
    out = GroupOut.model_validate(group)
    if membership is not None:
        out.my_role = GroupRole(membership.role)
        out.my_state = GroupMemberState(membership.state)
    # Only members and invitees ever reach a group, but an invitee has not
    # accepted yet — keep the description behind the door until they do.
    if not _is_active(membership):
        out.description = None
    return out


def _card_out(group: Group, membership: GroupMember | None) -> GroupCardOut:
    card = GroupCardOut(
        id=group.id,
        name=group.name,
        member_count=group.member_count,
        avatar_url=group.avatar_url,
    )
    if membership is not None:
        card.my_role = GroupRole(membership.role)
        card.my_state = GroupMemberState(membership.state)
    if _is_active(membership):
        card.description = group.description
    return card


# ---------------------------------------------------------------------- #
# Create / my groups / detail / update
# ---------------------------------------------------------------------- #
@router.post(
    ApiRoutes.GROUPS_CREATE, response_model=GroupOut, status_code=status.HTTP_201_CREATED
)
async def create_group(
    body: GroupCreateIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> GroupOut:
    try:
        group = await GroupService.create(
            request=request,
            owner=user,
            name=body.name,
            description=body.description,
            post_policy=body.post_policy,
            member_dm_policy=body.member_dm_policy,
            org_id=body.org_id,
            db=db,
        )
    except GroupError as e:
        _raise(e)
    membership = await _my_membership(group, user.id, db)
    return _detail_out(group, membership)


@router.get(ApiRoutes.GROUPS_LIST, response_model=CursorPage)
async def list_groups(
    q: str | None = Query(default=None),
    cursor: str | None = Query(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> CursorPage:
    """My groups. Groups are invite-only and NOT discoverable — there is no
    browse mode: you are in a group or you have never heard of it."""
    await enforce_rate_limit(user.id, "list_groups", RATE_LIMIT_READS_PER_MINUTE)
    after = _parse_cursor(cursor)
    stmt = (
        select(Group, GroupMember)
        .join(GroupMember, GroupMember.group_id == Group.id)
        .where(
            GroupMember.user_id == user.id,
            GroupMember.state == GroupMemberState.ACTIVE,
        )
    )
    if q:
        stmt = stmt.where(Group.name.ilike(f"%{q}%"))
    if after is not None:
        stmt = stmt.where(Group.created_at < after)
    stmt = stmt.order_by(Group.created_at.desc()).limit(GROUPS_PAGE_SIZE + 1)
    rows = list((await db.execute(stmt)).all())
    next_cursor = None
    if len(rows) > GROUPS_PAGE_SIZE:
        rows = rows[:GROUPS_PAGE_SIZE]
        next_cursor = rows[-1][0].created_at.isoformat()
    data = [_card_out(g, m).model_dump(mode="json") for g, m in rows]
    return CursorPage(data=data, next_cursor=next_cursor)


@router.get(ApiRoutes.GROUPS_DETAIL, response_model=GroupOut)
async def get_group(
    group_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> GroupOut:
    group = await _load_group(group_id, db)
    membership = await _my_membership(group, user.id, db)
    # Groups are invite-only and undiscoverable: anyone who is neither a member
    # nor a pending invitee gets the same 404 as a group that does not exist.
    if not _is_active(membership):
        invited = await db.scalar(
            select(GroupInvite).where(
                GroupInvite.group_id == group.id,
                GroupInvite.invitee_id == user.id,
                GroupInvite.state == GroupInviteState.PENDING,
            )
        )
        if invited is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, detail="group_not_found")
    return _detail_out(group, membership)


@router.patch(ApiRoutes.GROUPS_DETAIL, response_model=GroupOut)
async def update_group(
    group_id: uuid.UUID,
    body: GroupUpdateIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> GroupOut:
    group = await _load_group(group_id, db)
    membership = await _my_membership(group, user.id, db)
    if not _is_active(membership) or membership.role not in (
        GroupRole.OWNER,
        GroupRole.ADMIN,
    ):
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="not_authorized")
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(group, field, value)
    await db.commit()
    await db.refresh(group)
    return _detail_out(group, membership)


# ---------------------------------------------------------------------- #
# Join + join requests
# ---------------------------------------------------------------------- #
@router.post(
    ApiRoutes.GROUPS_INVITES, response_model=GroupInviteOut, status_code=status.HTTP_201_CREATED
)
async def create_invite(
    group_id: uuid.UUID,
    body: InviteCreateIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> GroupInviteOut:
    group = await _load_group(group_id, db)
    try:
        if body.link:
            invite = await GroupService.create_link_invite(
                request=request,
                inviter=user,
                group=group,
                max_uses=body.max_uses,
                expires_at=body.expires_at,
                db=db,
            )
        elif body.user_id is not None:
            invite = await GroupService.create_direct_invite(
                request=request,
                inviter=user,
                group=group,
                invitee_id=body.user_id,
                db=db,
            )
        else:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST, detail="user_id_or_link_required"
            )
    except GroupError as e:
        _raise(e)
    return GroupInviteOut.model_validate(invite)


@router.post(ApiRoutes.GROUPS_INVITE_ACCEPT, response_model=OkResponse)
async def accept_invite(
    group_id: uuid.UUID,
    invite_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    group = await _load_group(group_id, db)
    try:
        await GroupService.accept_direct_invite(
            request=request, user=user, group=group, invite_id=invite_id, db=db
        )
    except GroupError as e:
        _raise(e)
    return OkResponse()


@router.post(ApiRoutes.GROUPS_INVITE_DECLINE, response_model=OkResponse)
async def decline_invite(
    group_id: uuid.UUID,
    invite_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    group = await _load_group(group_id, db)
    try:
        await GroupService.decline_invite(
            user=user, group=group, invite_id=invite_id, db=db
        )
    except GroupError as e:
        _raise(e)
    return OkResponse()


@router.delete(ApiRoutes.GROUPS_INVITE_DETAIL, response_model=OkResponse)
async def revoke_invite(
    group_id: uuid.UUID,
    invite_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    group = await _load_group(group_id, db)
    try:
        await GroupService.revoke_invite(
            actor=user, group=group, invite_id=invite_id, db=db
        )
    except GroupError as e:
        _raise(e)
    return OkResponse()


@router.post(ApiRoutes.GROUP_INVITE_TOKEN_ACCEPT, response_model=JoinResultOut)
async def accept_link_invite(
    token: str,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> JoinResultOut:
    try:
        group = await GroupService.accept_link_invite(
            request=request, user=user, token=token, db=db
        )
    except GroupError as e:
        _raise(e)
    return JoinResultOut(result="joined", group_id=group.id)


# ---------------------------------------------------------------------- #
# Members / roles / ownership
# ---------------------------------------------------------------------- #
@router.get(ApiRoutes.GROUPS_MEMBERS, response_model=list[GroupMemberOut])
async def list_members(
    group_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[GroupMemberOut]:
    group = await _load_group(group_id, db)
    membership = await _my_membership(group, user.id, db)
    if not _is_active(membership):
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="not_a_group_member")
    rows = await db.execute(
        select(GroupMember, User)
        .join(User, User.id == GroupMember.user_id)
        .where(
            GroupMember.group_id == group.id,
            GroupMember.state == GroupMemberState.ACTIVE,
        )
    )
    return [
        GroupMemberOut(
            user_id=u.id,
            full_name=u.full_name,
            role=m.role,
            state=m.state,
            specialty=u.specialty,
            avatar_color=u.avatar_color,
            avatar_url=u.avatar_url,
        )
        for m, u in rows.all()
    ]


@router.patch(ApiRoutes.GROUPS_MEMBER_DETAIL, response_model=OkResponse)
async def change_member_role(
    group_id: uuid.UUID,
    user_id: uuid.UUID,
    body: MemberRoleUpdateIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    group = await _load_group(group_id, db)
    try:
        await GroupService.change_role(
            request=request,
            actor=user,
            group=group,
            target_id=user_id,
            new_role=body.role,
            db=db,
        )
    except GroupError as e:
        _raise(e)
    return OkResponse()


@router.delete(ApiRoutes.GROUPS_MEMBER_DETAIL, response_model=OkResponse)
async def remove_member(
    group_id: uuid.UUID,
    user_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    group = await _load_group(group_id, db)
    try:
        await GroupService.remove_member(
            request=request, actor=user, group=group, target_id=user_id, db=db
        )
    except GroupError as e:
        _raise(e)
    return OkResponse()


@router.post(ApiRoutes.GROUPS_MEMBER_BAN, response_model=OkResponse)
async def ban_member(
    group_id: uuid.UUID,
    user_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    group = await _load_group(group_id, db)
    try:
        await GroupService.ban_member(
            request=request, actor=user, group=group, target_id=user_id, db=db
        )
    except GroupError as e:
        _raise(e)
    return OkResponse()


@router.post(ApiRoutes.GROUPS_TRANSFER_OWNERSHIP, response_model=OkResponse)
async def transfer_ownership(
    group_id: uuid.UUID,
    body: TransferOwnershipIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    group = await _load_group(group_id, db)
    try:
        await GroupService.transfer_ownership(
            request=request, actor=user, group=group, new_owner_id=body.user_id, db=db
        )
    except GroupError as e:
        _raise(e)
    return OkResponse()


# ---------------------------------------------------------------------- #
# My groups
# ---------------------------------------------------------------------- #
@router.get(ApiRoutes.ME_GROUPS, response_model=list[GroupCardOut])
async def my_groups(
    state: str = Query(default="member", pattern="^(member|invited)$"),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[GroupCardOut]:
    await enforce_rate_limit(user.id, "my_groups", RATE_LIMIT_READS_PER_MINUTE)
    if state == "member":
        rows = await db.execute(
            select(Group, GroupMember)
            .join(GroupMember, GroupMember.group_id == Group.id)
            .where(
                GroupMember.user_id == user.id,
                GroupMember.state == GroupMemberState.ACTIVE,
            )
            .order_by(Group.created_at.desc())
        )
        return [_card_out(g, m) for g, m in rows.all()]
    # invited
    rows = await db.execute(
        select(Group)
        .join(GroupInvite, GroupInvite.group_id == Group.id)
        .where(
            GroupInvite.invitee_id == user.id,
            GroupInvite.state == GroupInviteState.PENDING,
        )
        .order_by(Group.created_at.desc())
    )
    return [_card_out(g, None) for g in rows.scalars().all()]
