from __future__ import annotations

import logging
import uuid

from fastapi import (
    APIRouter,
    Depends,
    File,
    Header,
    HTTPException,
    Query,
    Request,
    Response,
    UploadFile,
    status,
)
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import (
    AVATAR_ALLOWED_EXT,
    AVATAR_ALLOWED_MIME,
    AVATAR_MAX_BYTES,
    PRESENCE_QUERY_MAX_IDS,
    RATE_LIMIT_EXPORTS_PER_HOUR,
    RATE_LIMIT_NOTIFICATION_SETTINGS_PER_MINUTE,
    RATE_LIMIT_PHONE_CHANGES_PER_HOUR,
    RATE_LIMIT_PIN_WRITES_PER_MINUTE,
    RATE_LIMIT_PRIVACY_WRITES_PER_MINUTE,
    RATE_LIMIT_AVATAR_READS_PER_MINUTE,
    RATE_LIMIT_READS_PER_MINUTE,
    RATE_LIMIT_SESSION_WRITES_PER_MINUTE,
    RATE_LIMIT_STATUS_WRITES_PER_MINUTE,
)
from app.api.ws_manager import ws_manager
from app.core.dependencies import bearer_jti, get_current_user
from app.core.enums import AuditAction, InvitationStatus, WsEventServer
from app.core.permissions import (
    can_message,
    can_see_about,
    can_see_profile_photo,
    can_view_profile,
)
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.db.redis import get_redis
from app.models import Block, ConnectionInvitation, Session, User, UserPrivacySettings
from app.schemas.auth import LinkPhoneIn
from app.schemas.common import OkResponse
from app.schemas.people import PublicProfileOut, location_label
from app.schemas.privacy import PresenceOut, PrivacyOut, PrivacyPatch
from app.schemas.push import PushTokenDeleteIn, PushTokenIn
from app.schemas.settings import (
    ExportOut,
    NotificationSettingsOut,
    NotificationSettingsPatch,
    PinDeleteIn,
    PinSetIn,
    PinStatusOut,
    SessionOut,
    SessionRevokeOut,
    StatusOut,
    StatusPatch,
)
from app.schemas.user import UserOut, UserPatch, build_user_out, pin_clears_at
from app.services.account_deletion_service import AccountDeletionService
from app.services.auth_service import AuthError, AuthService, PhoneTaken, WrongAccount
from app.services.audit_service import AuditService
from app.services.file_service import FileService, avatar_response
from app.services.notification_settings_service import NotificationSettingsService
from app.services.presence_service import PresenceService
from app.services.push_service import PushService
from app.services.relationship_service import RelationshipService
from app.services.session_service import PinError, PinService, SessionService
from app.services.status_service import ExportService, StatusService
from app.services.stripe_client import StripeGateway, get_optional_stripe
from sqlalchemy import and_, or_, select

router = APIRouter()

_DEGREE_LABEL = {1: "1st", 2: "2nd", "3+": "3rd", "out": "out"}


async def _profile_audience(user_id: uuid.UUID, db: AsyncSession) -> list[uuid.UUID]:
    """Everyone who renders this user's profile from a cache: first-degree
    connections ∪ members of every org the user belongs to, minus the user."""
    return await PresenceService.audience(user_id, db)


async def _commit_and_publish_profile_updated(user: User, db: AsyncSession) -> None:
    """Commit the profile mutation, then fan `profile_updated` out to the
    audience. Strictly post-commit so nobody refetches a stale row."""
    await db.commit()
    recipients = await _profile_audience(user.id, db)
    if recipients:
        await ws_manager.publish_to_users(
            recipients, WsEventServer.PROFILE_UPDATED, {"user_id": str(user.id)}
        )


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


_PRIVACY_FIELDS = (
    "invite_policy",
    "dm_policy",
    "discoverability",
    "show_mutual_connections",
    "last_seen_visibility",
    "online_visibility",
    "profile_photo_visibility",
    "about_visibility",
    "read_receipts",
    "default_disappear_sec",
    "link_previews",
)


@router.patch(ApiRoutes.USERS_PRIVACY, response_model=PrivacyOut)
async def update_privacy(
    body: PrivacyPatch,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> PrivacyOut:
    await enforce_rate_limit(user.id, "update_privacy", RATE_LIMIT_PRIVACY_WRITES_PER_MINUTE)
    row = await _get_or_create_privacy(user.id, db)
    data = body.model_dump(exclude_unset=True)
    changed = {f: data[f] for f in _PRIVACY_FIELDS if f in data}
    for field, value in changed.items():
        setattr(row, field, value)
    if changed:
        # Settings names only — never PHI. Which toggles moved is useful when a
        # doctor asks why a colleague stopped seeing their read receipts.
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.PRIVACY_UPDATED,
            resource_type="user",
            resource_id=user.id,
            db=db,
            metadata={"fields": sorted(changed)},
        )
    await db.commit()
    await db.refresh(row)
    return PrivacyOut.model_validate(row)


@router.get(ApiRoutes.USERS_PRESENCE, response_model=list[PresenceOut])
async def presence(
    ids: str = Query(..., description="comma-separated user ids, max 50"),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[PresenceOut]:
    """Presence + last seen for up to 50 users, filtered by each target's
    last-seen / online visibility relative to the caller and by the reciprocal
    rule (a caller hiding their own last seen sees nobody's). A hidden target
    is indistinguishable from an offline stranger; unknown ids are omitted."""
    await enforce_rate_limit(user.id, "presence", RATE_LIMIT_READS_PER_MINUTE)
    raw = [part.strip() for part in ids.split(",") if part.strip()]
    if not raw or len(raw) > PRESENCE_QUERY_MAX_IDS:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, detail="presence_ids_invalid"
        )
    try:
        target_ids = list(dict.fromkeys(uuid.UUID(part) for part in raw))
    except ValueError as e:
        raise HTTPException(
            status.HTTP_422_UNPROCESSABLE_ENTITY, detail="presence_ids_invalid"
        ) from e
    return await PresenceService.snapshot_for(user.id, target_ids, db)


@router.get("/me", response_model=UserOut)
async def me(user: User = Depends(get_current_user)) -> UserOut:
    return await build_user_out(user)


@router.delete("/me", response_model=OkResponse, status_code=status.HTTP_200_OK)
async def delete_me(
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    stripe: StripeGateway | None = Depends(get_optional_stripe),
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
        stripe=stripe,
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
    await _commit_and_publish_profile_updated(user, db)
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
    if target is None or target.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="user_unavailable")

    ctx = await RelationshipService.load_context(user.id, user_id, db)
    # The blocker already knows they blocked this doctor, so showing THEM a
    # stripped card with an Unblock affordance leaks nothing. The blocked
    # party still gets the generic 404 (silence rule).
    blocked_by_me = ctx.is_blocked_either_way and (
        await db.scalar(
            select(Block.id).where(Block.blocker_id == user.id, Block.blocked_id == user_id)
        )
    ) is not None
    if blocked_by_me:
        return PublicProfileOut(
            id=target.id,
            full_name=target.full_name,
            headline=target.headline,
            specialty=target.specialty,
            location_label=location_label(target.city, target.state),
            avatar_color=target.avatar_color,
            degree="out",
            connection_state="blocked",
            can_message="denied",
        )
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

    # Field visibility (batch 2): photo and about are per-audience; the
    # avatar_color initials fallback is not a photo and always renders.
    show_photo = can_see_profile_photo(ctx)
    avatar_presigned = None
    if show_photo and target.avatar_url:
        avatar_presigned = await FileService.presigned_url(key=target.avatar_url)

    return PublicProfileOut(
        id=target.id,
        full_name=target.full_name,
        headline=target.headline,
        specialty=target.specialty,
        location_label=location_label(target.city, target.state),
        avatar_color=target.avatar_color,
        avatar_url=target.avatar_url if show_photo else None,
        avatar_presigned_url=avatar_presigned,
        about=target.bio if can_see_about(ctx) else None,
        years_of_experience=target.years_of_experience,
        skills=target.skills or [],
        degree=degree,
        connection_state=conn_state,
        mutual_count=mutual_count,
        can_message=msg_mode,
        context_label=context_label,
        is_colleague=bool(ctx.shared_org_ids),
        **StatusService.to_out(target).model_dump(),
    )


@router.get(ApiRoutes.USERS_AVATAR, response_class=Response)
async def get_user_avatar(
    user_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> Response:
    """A doctor's profile picture as bytes, under the same audience rule as
    the public profile (profile_photo_visibility, blocks, silence rule). The
    URL is stable, so the app caches it instead of chasing presigned links."""
    await enforce_rate_limit(user.id, "avatar_read", RATE_LIMIT_AVATAR_READS_PER_MINUTE)
    if user_id == user.id:
        return await avatar_response(request, key=user.avatar_url)
    target = await db.get(User, user_id)
    if target is None or target.deleted_at is not None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="user_unavailable")
    ctx = await RelationshipService.load_context(user.id, user_id, db)
    if ctx.is_blocked_either_way or not can_view_profile(ctx).allowed:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="user_unavailable")
    if not can_see_profile_photo(ctx):
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="avatar_not_found")
    return await avatar_response(request, key=target.avatar_url)


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
    await _commit_and_publish_profile_updated(user, db)
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


@router.patch(ApiRoutes.USERS_ME_PHONE, response_model=UserOut)
async def change_phone(
    body: LinkPhoneIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> UserOut:
    """Change number (batch 6). Firebase verified the NEW number on the device
    (`updatePhoneNumber` / link); the refreshed ID token's phone claim is the
    proof. Same ownership and uniqueness rules as linking; audited without
    either number in the row."""
    await enforce_rate_limit(
        user.id, "change_phone", RATE_LIMIT_PHONE_CHANGES_PER_HOUR, window_seconds=3600
    )
    try:
        updated = await AuthService.link_phone(user=user, id_token=body.id_token, db=db)
    except WrongAccount as e:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail=str(e)) from e
    except PhoneTaken as e:
        raise HTTPException(status.HTTP_409_CONFLICT, detail=str(e)) from e
    except AuthError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail=str(e)) from e
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=AuditAction.PHONE_CHANGED,
        resource_type="user",
        resource_id=user.id,
        db=db,
    )
    await db.commit()
    await db.refresh(updated)
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
    await _commit_and_publish_profile_updated(user, db)
    return await build_user_out(user)


# --------------------------------------------------------------------------- #
# Settings (batch 6)
# --------------------------------------------------------------------------- #
@router.get(ApiRoutes.USERS_NOTIFICATIONS, response_model=NotificationSettingsOut)
async def get_notification_settings(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> NotificationSettingsOut:
    return await NotificationSettingsService.effective(user.id, db)


@router.patch(ApiRoutes.USERS_NOTIFICATIONS, response_model=NotificationSettingsOut)
async def update_notification_settings(
    body: NotificationSettingsPatch,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> NotificationSettingsOut:
    """Partial update, or `reset: true` for the defaults. Fans
    `notification_settings_updated` out to the caller's own devices."""
    await enforce_rate_limit(
        user.id, "notification_settings", RATE_LIMIT_NOTIFICATION_SETTINGS_PER_MINUTE
    )
    out, changed = await NotificationSettingsService.update(user_id=user.id, body=body, db=db)
    if changed:
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.NOTIFICATION_SETTINGS_UPDATED,
            resource_type="user",
            resource_id=user.id,
            db=db,
            metadata={"fields": sorted(changed)},
        )
    await db.commit()
    if changed:
        await ws_manager.publish_to_users(
            [user.id], WsEventServer.NOTIFICATION_SETTINGS_UPDATED, out.model_dump(mode="json")
        )
    return out


def _session_out(row: Session, current_jti: str | None) -> SessionOut:
    return SessionOut(
        id=row.id,
        device_name=row.device_name,
        platform=row.platform,
        app_version=row.app_version,
        ip=str(row.ip) if row.ip else None,
        created_at=row.created_at,
        last_seen_at=row.last_seen_at,
        current=row.access_jti == current_jti,
    )


@router.get(ApiRoutes.USERS_SESSIONS, response_model=list[SessionOut])
async def list_sessions(
    authorization: str | None = Header(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> list[SessionOut]:
    """Linked devices: live sessions, newest activity first, with `current`
    on the one behind this request's token."""
    jti = bearer_jti(authorization)
    rows = await SessionService.list_active(user.id, db)
    return [_session_out(r, jti) for r in rows]


@router.delete(ApiRoutes.USERS_SESSION_DETAIL, response_model=OkResponse)
async def revoke_session(
    session_id: uuid.UUID,
    request: Request,
    user: User = Depends(get_current_user),
    redis: Redis = Depends(get_redis),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    """Sign one device out. Its next call answers 401 session_revoked and it
    hears `session_revoked` over WS right away. Revoking THIS device works
    too (same as logout). Someone else's session is a 404."""
    await enforce_rate_limit(user.id, "revoke_session", RATE_LIMIT_SESSION_WRITES_PER_MINUTE)
    row = await db.get(Session, session_id)
    if row is None or row.user_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="session_not_found")
    if row.revoked_at is None:
        await SessionService.revoke(row=row, redis=redis, db=db)
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.SESSION_REVOKED,
            resource_type="session",
            resource_id=row.id,
            db=db,
            metadata={"count": 1},
        )
        await db.commit()
        await SessionService.publish_revoked(user.id, [row.id])
    return OkResponse()


@router.post(ApiRoutes.USERS_SESSIONS_REVOKE_OTHERS, response_model=SessionRevokeOut)
async def revoke_other_sessions(
    request: Request,
    authorization: str | None = Header(default=None),
    user: User = Depends(get_current_user),
    redis: Redis = Depends(get_redis),
    db: AsyncSession = Depends(get_db),
) -> SessionRevokeOut:
    """"Sign out of all other devices." Keeps the session behind this token."""
    await enforce_rate_limit(user.id, "revoke_session", RATE_LIMIT_SESSION_WRITES_PER_MINUTE)
    revoked = await SessionService.revoke_others(
        user_id=user.id, keep_jti=bearer_jti(authorization), redis=redis, db=db
    )
    if revoked:
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.SESSION_REVOKED,
            resource_type="user",
            resource_id=user.id,
            db=db,
            metadata={"count": len(revoked), "session_ids": [str(r.id) for r in revoked]},
        )
        await db.commit()
        await SessionService.publish_revoked(user.id, [r.id for r in revoked])
    return SessionRevokeOut(revoked=len(revoked))


_PIN_STATUS = {
    "pin_invalid": status.HTTP_401_UNAUTHORIZED,
    "pin_not_set": status.HTTP_409_CONFLICT,
}


@router.put(ApiRoutes.USERS_PIN, response_model=PinStatusOut)
async def set_pin(
    body: PinSetIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> PinStatusOut:
    """Turn two-step verification on, or change the PIN (needs `current_pin`).
    New devices must then enter it after OTP until `/auth/pin/verify`."""
    await enforce_rate_limit(user.id, "pin_write", RATE_LIMIT_PIN_WRITES_PER_MINUTE)
    try:
        await PinService.set_pin(user=user, pin=body.pin, current_pin=body.current_pin, db=db)
    except PinError as e:
        raise HTTPException(_PIN_STATUS.get(str(e), 400), detail=str(e)) from e
    await AuditService.log_request(
        request, user_id=user.id, action=AuditAction.PIN_SET, resource_type="user",
        resource_id=user.id, db=db,
    )
    await db.commit()
    return PinStatusOut(pin_enabled=True)


@router.delete(ApiRoutes.USERS_PIN, response_model=PinStatusOut)
async def remove_pin(
    body: PinDeleteIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> PinStatusOut:
    """Turn two-step verification off. The current PIN is required."""
    await enforce_rate_limit(user.id, "pin_write", RATE_LIMIT_PIN_WRITES_PER_MINUTE)
    try:
        await PinService.remove_pin(user=user, pin=body.pin, db=db)
    except PinError as e:
        raise HTTPException(_PIN_STATUS.get(str(e), 400), detail=str(e)) from e
    await AuditService.log_request(
        request, user_id=user.id, action=AuditAction.PIN_REMOVED, resource_type="user",
        resource_id=user.id, db=db,
    )
    await db.commit()
    return PinStatusOut(pin_enabled=False)


@router.get(ApiRoutes.USERS_PIN, response_model=PinStatusOut)
async def pin_status(user: User = Depends(get_current_user)) -> PinStatusOut:
    return PinStatusOut(pin_enabled=user.pin_hash is not None, pin_clears_at=pin_clears_at(user))


@router.post(ApiRoutes.USERS_EXPORT, response_model=ExportOut)
async def export_account(
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> ExportOut:
    """Account info export: profile, settings, organizations, connections and
    groups — NO messages — as a JSON file behind a 10-minute presigned URL."""
    await enforce_rate_limit(
        user.id, "account_export", RATE_LIMIT_EXPORTS_PER_HOUR, window_seconds=3600
    )
    url, expires_at = await ExportService.upload(user=user, db=db)
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=AuditAction.ACCOUNT_EXPORTED,
        resource_type="user",
        resource_id=user.id,
        db=db,
    )
    await db.commit()
    return ExportOut(url=url, expires_at=expires_at)


@router.patch(ApiRoutes.USERS_STATUS, response_model=StatusOut)
async def update_status(
    body: StatusPatch,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> StatusOut:
    """Status under the name: a preset or custom text (≤ 40), with an expiry
    of 1h / 8h / 24h or never; `{}` clears it. The audience hears
    `profile_updated`. Audited with the preset name only, never custom text."""
    await enforce_rate_limit(user.id, "status", RATE_LIMIT_STATUS_WRITES_PER_MINUTE)
    changed = await StatusService.update(user=user, body=body, db=db)
    if changed:
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.STATUS_UPDATED,
            resource_type="user",
            resource_id=user.id,
            db=db,
            metadata={
                "preset": body.preset.value if body.preset else None,
                "custom": body.text is not None,
                "expires_in_sec": body.expires_in_sec,
            },
        )
    await db.commit()
    if changed:
        await StatusService.publish(user.id, db)
    return StatusService.to_out(user)
