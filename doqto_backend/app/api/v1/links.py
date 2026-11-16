"""Link previews (batch 4): GET /link-preview?url= — server-side fetch behind
an SSRF guard, cached 24 h, honours the caller's privacy.link_previews."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import RATE_LIMIT_LINK_PREVIEWS_PER_MINUTE
from app.core.dependencies import get_current_user
from app.core.enums import AuditAction
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.models import User, UserPrivacySettings
from app.schemas.message import LinkPreviewOut
from app.services.audit_service import AuditService
from app.services.link_preview_service import LinkPreviewError, LinkPreviewService

router = APIRouter()

_STATUS = {
    "invalid_url": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "url_not_allowed": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "too_large": status.HTTP_422_UNPROCESSABLE_ENTITY,
    "not_html": status.HTTP_404_NOT_FOUND,
    "fetch_failed": status.HTTP_404_NOT_FOUND,
}


@router.get(ApiRoutes.LINK_PREVIEW, response_model=LinkPreviewOut)
async def link_preview(
    request: Request,
    url: str = Query(min_length=1, max_length=2048),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> LinkPreviewOut:
    """Title / description / small inlined image for a public http(s) URL.
    403 link_previews_disabled when the caller turned previews off; 422 for a
    URL we refuse to fetch (non-http, private/loopback host, too big); 404 when
    the page cannot be fetched or is not HTML."""
    await enforce_rate_limit(user.id, "link_preview", RATE_LIMIT_LINK_PREVIEWS_PER_MINUTE)
    enabled = await db.scalar(
        select(UserPrivacySettings.link_previews).where(UserPrivacySettings.user_id == user.id)
    )
    if enabled is False:
        raise HTTPException(status.HTTP_403_FORBIDDEN, detail="link_previews_disabled")
    try:
        out = await LinkPreviewService.preview(url)
    except LinkPreviewError as e:
        raise HTTPException(_STATUS.get(e.code, status.HTTP_404_NOT_FOUND), detail=e.code) from e
    # The server made an outbound request on the user's behalf: leave a trace
    # (host only — the full URL could carry a token).
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=AuditAction.LINK_PREVIEW_FETCHED,
        resource_type="link",
        db=db,
        metadata={"host": out.url.split("/")[2] if "//" in out.url else None},
    )
    await db.commit()
    return out
