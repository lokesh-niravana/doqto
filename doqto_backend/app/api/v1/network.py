from __future__ import annotations

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    MUTUAL_CONNECTIONS_DEFAULT_LIMIT,
    NETWORK_PAGE_SIZE,
    PEOPLE_SEARCH_MAX_LIMIT,
    RATE_LIMIT_READS_PER_MINUTE,
    SUGGEST_PAGE_SIZE,
)
from app.core.dependencies import get_current_user
from app.core.enums import InvitationStatus
from app.core.permissions import can_view_profile
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.models import (
    Block,
    Connection,
    ConnectionInvitation,
    Mute,
    SuggestionDismissal,
    User,
)
from app.schemas.common import OkResponse
from app.schemas.people import PeopleSearchPage
from app.schemas.network import (
    BlockOut,
    ConnectionCardOut,
    CursorPage,
    InvitationCreateIn,
    InvitationOut,
    InvitationPartyOut,
    InvitationSendResult,
    MutualConnectionOut,
    MuteOut,
    ReportCreateIn,
)
from app.services.connection_service import ConnectionError, ConnectionService
from app.services.file_service import FileService
from app.services.people_search_service import people_search
from app.services.relationship_service import RelationshipService

router = APIRouter()


def _raise(e: ConnectionError) -> None:
    headers = None
    if e.retry_after_days is not None:
        headers = {
            "Retry-After": str(e.retry_after_days * 86400),
            "X-Retry-After-Days": str(e.retry_after_days),
        }
    raise HTTPException(e.status_code, detail=e.code, headers=headers)


def _parse_cursor(cursor: str | None) -> datetime | None:
    if not cursor:
        return None
    try:
        return datetime.fromisoformat(cursor)
    except ValueError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="invalid_cursor") from e


async def _invitation_parties(
    rows: list[ConnectionInvitation], db: AsyncSession
) -> dict[uuid.UUID, InvitationPartyOut]:
    """Directory identities for every party in `rows`, keyed by user id.

    One query for the whole page — an invitation carrying only ids renders as
    a nameless, avatar-less card.
    """
    ids = {r.sender_id for r in rows} | {r.recipient_id for r in rows}
    if not ids:
        return {}
    users = (await db.scalars(select(User).where(User.id.in_(ids)))).all()
    return {
        u.id: InvitationPartyOut(
            id=u.id,
            full_name=u.full_name,
            headline=u.headline,
            specialty=u.specialty,
            avatar_color=u.avatar_color,
            avatar_url=u.avatar_url,
            avatar_presigned_url=(
                await FileService.presigned_url(key=u.avatar_url) if u.avatar_url else None
            ),
        )
        for u in users
    }


# ---------------------------------------------------------------------- #
# Invitations
# ---------------------------------------------------------------------- #
@router.post(
    ApiRoutes.NETWORK_INVITATIONS,
    response_model=InvitationSendResult,
    status_code=status.HTTP_201_CREATED,
)
async def send_invitation(
    body: InvitationCreateIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> InvitationSendResult:
    try:
        outcome, obj = await ConnectionService.invite(
            request=request,
            sender=user,
            recipient_id=body.recipient_id,
            message=body.message,
            db=db,
        )
    except ConnectionError as e:
        _raise(e)
    if outcome == "connected":
        return InvitationSendResult(result="connected", connected_user_id=body.recipient_id)
    return InvitationSendResult(result="invited", invitation=InvitationOut.model_validate(obj))


@router.get(ApiRoutes.NETWORK_INVITATIONS, response_model=CursorPage)
async def list_invitations(
    direction: str = Query(default="received", pattern="^(received|sent)$"),
    status_filter: InvitationStatus | None = Query(default=None, alias="status"),
    cursor: str | None = Query(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> CursorPage:
    await enforce_rate_limit(user.id, "list_invitations", RATE_LIMIT_READS_PER_MINUTE)
    stmt = select(ConnectionInvitation)
    if direction == "received":
        stmt = stmt.where(ConnectionInvitation.recipient_id == user.id)
    else:
        stmt = stmt.where(ConnectionInvitation.sender_id == user.id)
    if status_filter is not None:
        stmt = stmt.where(ConnectionInvitation.status == status_filter)
    elif direction == "received":
        # Received default view = actionable (pending) only.
        stmt = stmt.where(ConnectionInvitation.status == InvitationStatus.PENDING)
    after = _parse_cursor(cursor)
    if after is not None:
        stmt = stmt.where(ConnectionInvitation.created_at < after)
    stmt = stmt.order_by(ConnectionInvitation.created_at.desc()).limit(NETWORK_PAGE_SIZE + 1)
    rows = list((await db.scalars(stmt)).all())
    next_cursor = None
    if len(rows) > NETWORK_PAGE_SIZE:
        rows = rows[:NETWORK_PAGE_SIZE]
        next_cursor = rows[-1].created_at.isoformat()
    parties = await _invitation_parties(rows, db)
    return CursorPage(
        data=[
            InvitationOut.model_validate(r)
            .model_copy(
                update={
                    "sender": parties.get(r.sender_id),
                    "recipient": parties.get(r.recipient_id),
                }
            )
            .model_dump(mode="json")
            for r in rows
        ],
        next_cursor=next_cursor,
    )


@router.post(ApiRoutes.NETWORK_INVITATION_ACCEPT, response_model=OkResponse)
async def accept_invitation(
    invitation_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    try:
        await ConnectionService.accept(
            request=request, user=user, invitation_id=invitation_id, db=db
        )
    except ConnectionError as e:
        _raise(e)
    return OkResponse()


@router.post(ApiRoutes.NETWORK_INVITATION_IGNORE, response_model=OkResponse)
async def ignore_invitation(
    invitation_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    try:
        await ConnectionService.ignore(
            request=request, user=user, invitation_id=invitation_id, db=db
        )
    except ConnectionError as e:
        _raise(e)
    return OkResponse()


@router.delete(ApiRoutes.NETWORK_INVITATION_DETAIL, response_model=OkResponse)
async def withdraw_invitation(
    invitation_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    try:
        await ConnectionService.withdraw(
            request=request, user=user, invitation_id=invitation_id, db=db
        )
    except ConnectionError as e:
        _raise(e)
    return OkResponse()


# ---------------------------------------------------------------------- #
# Connections
# ---------------------------------------------------------------------- #
@router.get(ApiRoutes.NETWORK_CONNECTIONS, response_model=CursorPage)
async def list_connections(
    q: str | None = Query(default=None),
    cursor: str | None = Query(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> CursorPage:
    await enforce_rate_limit(user.id, "list_connections", RATE_LIMIT_READS_PER_MINUTE)
    stmt = (
        select(Connection, User)
        .join(User, User.id == Connection.connected_user_id)
        .where(Connection.user_id == user.id)
    )
    if q:
        stmt = stmt.where(User.full_name.ilike(f"%{q}%"))
    after = _parse_cursor(cursor)
    if after is not None:
        stmt = stmt.where(Connection.created_at < after)
    stmt = stmt.order_by(Connection.created_at.desc()).limit(NETWORK_PAGE_SIZE + 1)
    rows = list((await db.execute(stmt)).all())
    next_cursor = None
    if len(rows) > NETWORK_PAGE_SIZE:
        rows = rows[:NETWORK_PAGE_SIZE]
        next_cursor = rows[-1][0].created_at.isoformat()
    data = [
        ConnectionCardOut(
            id=other.id,
            full_name=other.full_name,
            specialty=other.specialty,
            avatar_color=other.avatar_color,
            avatar_url=other.avatar_url,
            avatar_presigned_url=(
                await FileService.presigned_url(key=other.avatar_url)
                if other.avatar_url
                else None
            ),
            connected_at=conn.created_at,
        ).model_dump(mode="json")
        for conn, other in rows
    ]
    return CursorPage(data=data, next_cursor=next_cursor)


@router.delete(ApiRoutes.NETWORK_CONNECTION_DETAIL, response_model=OkResponse)
async def remove_connection(
    user_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    try:
        await ConnectionService.remove_connection(
            request=request, user=user, other_id=user_id, db=db
        )
    except ConnectionError as e:
        _raise(e)
    return OkResponse()


@router.get(ApiRoutes.NETWORK_CONNECTIONS_MUTUAL, response_model=list[MutualConnectionOut])
async def mutual_connections(
    user_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[MutualConnectionOut]:
    await enforce_rate_limit(user.id, "mutual_connections", RATE_LIMIT_READS_PER_MINUTE)
    # Gated by the target's show_mutual_connections + profile visibility.
    ctx = await RelationshipService.load_context(user.id, user_id, db)
    if not can_view_profile(ctx).allowed or not ctx.target_privacy.show_mutual_connections:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="user_unavailable")
    ids = await RelationshipService.mutual_connections(
        user.id, user_id, db, limit=MUTUAL_CONNECTIONS_DEFAULT_LIMIT
    )
    if not ids:
        return []
    rows = (await db.scalars(select(User).where(User.id.in_(ids)))).all()
    return [
        MutualConnectionOut(
            user_id=u.id,
            full_name=u.full_name,
            avatar_color=u.avatar_color,
            avatar_url=u.avatar_url,
        )
        for u in rows
    ]


# ---------------------------------------------------------------------- #
# Recommended for you


@router.get(ApiRoutes.NETWORK_SUGGESTIONS, response_model=PeopleSearchPage)
async def suggestions(
    cursor: str | None = Query(default=None),
    limit: int = Query(default=SUGGEST_PAGE_SIZE, ge=1, le=PEOPLE_SEARCH_MAX_LIMIT),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> PeopleSearchPage:
    await enforce_rate_limit(user.id, "network_suggestions", RATE_LIMIT_READS_PER_MINUTE)
    cards, next_cursor = await people_search.suggestions(
        viewer_id=user.id, cursor=cursor, limit=limit, db=db
    )
    return PeopleSearchPage(data=cards, next_cursor=next_cursor)


@router.post(ApiRoutes.NETWORK_SUGGESTION_DISMISS, response_model=OkResponse)
async def dismiss_suggestion(
    user_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    if user_id == user.id or await db.get(User, user_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="user_unavailable")
    await db.execute(
        insert(SuggestionDismissal)
        .values(user_id=user.id, dismissed_user_id=user_id)
        .on_conflict_do_nothing()
    )
    await db.commit()
    return OkResponse()


# ---------------------------------------------------------------------- #
# Blocks
# ---------------------------------------------------------------------- #
@router.get(ApiRoutes.NETWORK_BLOCKS, response_model=list[BlockOut])
async def list_blocks(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[BlockOut]:
    rows = (
        await db.scalars(select(Block).where(Block.blocker_id == user.id))
    ).all()
    return [BlockOut(blocked_id=b.blocked_id, created_at=b.created_at) for b in rows]


@router.post(ApiRoutes.NETWORK_BLOCK_DETAIL, response_model=OkResponse)
async def block_user(
    user_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    try:
        await ConnectionService.block(
            request=request, user=user, target_id=user_id, db=db
        )
    except ConnectionError as e:
        _raise(e)
    return OkResponse()


@router.delete(ApiRoutes.NETWORK_BLOCK_DETAIL, response_model=OkResponse)
async def unblock_user(
    user_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    try:
        await ConnectionService.unblock(
            request=request, user=user, target_id=user_id, db=db
        )
    except ConnectionError as e:
        _raise(e)
    return OkResponse()


# ---------------------------------------------------------------------- #
# Mutes
# ---------------------------------------------------------------------- #
@router.get(ApiRoutes.NETWORK_MUTES, response_model=list[MuteOut])
async def list_mutes(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[MuteOut]:
    rows = (await db.scalars(select(Mute).where(Mute.user_id == user.id))).all()
    return [MuteOut(muted_user_id=m.muted_user_id, created_at=m.created_at) for m in rows]


@router.post(ApiRoutes.NETWORK_MUTE_DETAIL, response_model=OkResponse)
async def mute_user(
    user_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    try:
        await ConnectionService.mute(user=user, target_id=user_id, db=db)
    except ConnectionError as e:
        _raise(e)
    return OkResponse()


@router.delete(ApiRoutes.NETWORK_MUTE_DETAIL, response_model=OkResponse)
async def unmute_user(
    user_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    await ConnectionService.unmute(user=user, target_id=user_id, db=db)
    return OkResponse()


# ---------------------------------------------------------------------- #
# Reports
# ---------------------------------------------------------------------- #
@router.post(
    ApiRoutes.NETWORK_REPORTS, response_model=OkResponse, status_code=status.HTTP_201_CREATED
)
async def file_report(
    body: ReportCreateIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    await ConnectionService.report(
        request=request,
        user=user,
        subject_type=body.subject_type,
        subject_id=body.subject_id,
        reason=body.reason,
        details=body.details,
        db=db,
    )
    return OkResponse()
