from __future__ import annotations

import logging
import uuid

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    AVATAR_ALLOWED_EXT,
    AVATAR_ALLOWED_MIME,
    AVATAR_MAX_BYTES,
)
from app.core.dependencies import get_current_user
from app.core.enums import InvitationStatus
from app.core.permissions import can_message, can_view_profile
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.models import ConnectionInvitation, User, UserPrivacySettings
from app.schemas.auth import LinkPhoneIn
from app.schemas.common import OkResponse
from app.schemas.people import PublicProfileOut, location_label
from app.schemas.privacy import PrivacyOut, PrivacyPatch
from app.schemas.push import PushTokenDeleteIn, PushTokenIn
from app.schemas.user import UserOut, UserPatch, build_user_out
from app.services.account_deletion_service import AccountDeletionService
from app.services.auth_service import AuthError, AuthService, PhoneTaken, WrongAccount
from app.services.file_service import FileService
from app.services.push_service import PushService
from app.services.relationship_service import RelationshipService
from sqlalchemy import and_, or_, select

router = APIRouter()

_DEGREE_LABEL = {1: "1st", 2: "2nd", "3+": "3rd", "out": "out"}


async def _get_or_create_privacy(user_id, db: AsyncSession) -> UserPrivacySettings:
    row = await db.scalar(
        select(UserPrivacySettings).where(UserPrivacySettings.user_id == user_id)
    )
    if row is None:
        row = UserPrivacySettings(user_id=user_id)
        db.add(row)
        await db.flush()
    return row


@router.get(ApiRoutes.USERS_PRIVACY, response_model=PrivacyOut)
async def get_privacy(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> PrivacyOut:
    row = await _get_or_create_privacy(user.id, db)
    await db.commit()
    return PrivacyOut.model_validate(row)


@router.patch(ApiRoutes.USERS_PRIVACY, response_model=PrivacyOut)
async def update_privacy(
    body: PrivacyPatch,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> PrivacyOut:
    row = await _get_or_create_privacy(user.id, db)
    data = body.model_dump(exclude_unset=True)
    for field in ("invite_policy", "dm_policy", "discoverability", "show_mutual_connections"):
        if field in data:
            setattr(row, field, data[field])
    await db.commit()
    await db.refresh(row)
    return PrivacyOut.model_validate(row)


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)) -> UserOut:
    return await build_user_out(user)


@router.delete("/me", response_model=OkResponse, status_code=status.HTTP_200_OK)
async def delete_me(
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    """App Store 5.1.1(v): account deletion initiated from inside the app.

    Irreversible. Scrubs identity, destroys authored content and the social
    graph, and leaves an audit tombstone (HIPAA retention).
    """
    await AccountDeletionService.delete_account(
        user=user,
        db=db,
        ip_address=request.client.host if request.client else None,
        user_agent=request.headers.get("user-agent"),
    )
    return OkResponse()


@router.patch("/me", response_model=UserOut)
async def update_me(
    body: UserPatch,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> UserOut:
    data = body.model_dump(exclude_unset=True)
    if "handle" in data and data["handle"] is not None:
        # Globally unique, case-sensitive slug. Pre-check for a friendly 409
        # (the DB unique constraint is the ultimate guard).
        taken = await db.scalar(
            select(User.id).where(User.handle == data["handle"], User.id != user.id)
        )
        if taken is not None:
            raise HTTPException(status.HTTP_409_CONFLICT, detail="handle_taken")
    for field in (
        "full_name",
        "email",
        "handle",
        "headline",
        "specialty",
        "bio",
        "city",
        "state",
        "years_of_experience",
        "skills",
    ):
        if field in data:
            setattr(user, field, data[field])
    await db.flush()
    await db.refresh(user)
    return await build_user_out(user)


async def _connection_state(
    viewer_id: uuid.UUID, target_id: uuid.UUID, is_first_degree: bool, db: AsyncSession
) -> str:
    if is_first_degree:
        return "connected"
    row = await db.scalar(
        select(ConnectionInvitation.sender_id).where(
            ConnectionInvitation.status == InvitationStatus.PENDING,
            or_(
                and_(
                    ConnectionInvitation.sender_id == viewer_id,
                    ConnectionInvitation.recipient_id == target_id,
                ),
                and_(
                    ConnectionInvitation.sender_id == target_id,
                    ConnectionInvitation.recipient_id == viewer_id,
                ),
            ),
        )
    )
    if row is None:
        return "none"
    return "pending_outgoing" if row == viewer_id else "pending_incoming"


@router.get(ApiRoutes.USERS_PROFILE, response_model=PublicProfileOut)
async def get_public_profile(
    user_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> PublicProfileOut:
    """Public professional profile (M2). Directory data only — NO phone/email/
    NPI, ever. No audit (not PHI content — avoids audit flood). A blocked or
    non-existent / non-viewable target returns a generic 404 (silence rule)."""
    target = await db.get(User, user_id)
    if target is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="user_unavailable")

    ctx = await RelationshipService.load_context(user.id, user_id, db)
    if not can_view_profile(ctx).allowed:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="user_unavailable")

    degree = _DEGREE_LABEL[await RelationshipService.degree_of(user.id, user_id, db)]
    conn_state = await _connection_state(user.id, user_id, ctx.is_first_degree, db)
    msg_mode = can_message(ctx).mode

    # Mutuals gated by the target's show_mutual_connections privacy toggle.
    mutual_count = 0
    context_label: str | None = None
    if ctx.target_privacy.show_mutual_connections:
        mutuals = await RelationshipService.mutual_connections(user.id, user_id, db)
        mutual_count = len(mutuals)
    if mutual_count == 1:
        context_label = "1 mutual connection"
    elif mutual_count > 1:
        context_label = f"{mutual_count} mutual connections"
    elif ctx.shared_org_ids:
        context_label = "You share an organization"

    avatar_presigned = None
    if target.avatar_url:
        avatar_presigned = await FileService.presigned_url(key=target.avatar_url)

    return PublicProfileOut(
        id=target.id,
        full_name=target.full_name,
        headline=target.headline,
        specialty=target.specialty,
        location_label=location_label(target.city, target.state),
        avatar_color=target.avatar_color,
        avatar_url=target.avatar_url,
        avatar_presigned_url=avatar_presigned,
        about=target.bio,
        years_of_experience=target.years_of_experience,
        skills=target.skills or [],
        degree=degree,
        connection_state=conn_state,
        mutual_count=mutual_count,
        can_message=msg_mode,
        context_label=context_label,
        is_colleague=bool(ctx.shared_org_ids),
    )


@router.post("/me/avatar", response_model=UserOut)
async def upload_avatar(
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> UserOut:
    if file.content_type not in AVATAR_ALLOWED_MIME:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="avatar_unsupported_type")
    data = await file.read()
    if len(data) > AVATAR_MAX_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="avatar_too_large")
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="avatar_empty")
    ext = AVATAR_ALLOWED_EXT[file.content_type]
    key = f"avatars/{user.id}/{uuid.uuid4()}.{ext}"
    await FileService.upload_bytes(key=key, data=data, content_type=file.content_type)
    user.avatar_url = key
    await db.flush()
    await db.refresh(user)
    return await build_user_out(user)


@router.post(ApiRoutes.USERS_ME_PHONE, response_model=UserOut)
async def link_phone(
    body: LinkPhoneIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> UserOut:
    """Attach an optional phone number to an account that signed in another way."""
    try:
        updated = await AuthService.link_phone(user=user, id_token=body.id_token, db=db)
    except WrongAccount as e:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail=str(e)) from e
    except PhoneTaken as e:
        raise HTTPException(status.HTTP_409_CONFLICT, detail=str(e)) from e
    except AuthError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e
    return await build_user_out(updated)


@router.post(ApiRoutes.USERS_PUSH_TOKENS, response_model=OkResponse)
async def register_push_token(
    body: PushTokenIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    await PushService.register_token(
        user_id=user.id, token=body.token, platform=body.platform.value, db=db
    )
    return OkResponse()


@router.delete(ApiRoutes.USERS_PUSH_TOKENS, response_model=OkResponse)
async def unregister_push_token(
    body: PushTokenDeleteIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    await PushService.unregister_token(user_id=user.id, token=body.token, db=db)
    return OkResponse()


@router.delete("/me/avatar", response_model=UserOut)
async def delete_avatar(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> UserOut:
    # Disposal: remove the S3 object too (avatar_url stores the S3 key).
    # Best-effort — the DB pointer is cleared regardless.
    if user.avatar_url:
        try:
            await FileService.delete_object(key=user.avatar_url)
        except Exception:
            logging.getLogger("doqto.users").warning(
                "avatar S3 delete failed for key %s", user.avatar_url
            )
    user.avatar_url = None
    await db.flush()
    await db.refresh(user)
    return await build_user_out(user)
