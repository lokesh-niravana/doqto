"""Client-detected events worth an audit row (batch 6).

iOS cannot block screenshots, only observe them
(`UIApplication.userDidTakeScreenshotNotification`); the app reports one here
with the conversation it was looking at so the trail exists. Android blocks
them behind the org policy `block_screenshots` instead and never calls this.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import RATE_LIMIT_SCREENSHOT_AUDITS_PER_MINUTE
from app.core.dependencies import get_current_user
from app.core.enums import AuditAction
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.models import User
from app.schemas.common import OkResponse
from app.schemas.settings import ScreenshotAuditIn
from app.services.audit_service import AuditService
from app.services.message_service import MessageService

router = APIRouter()


@router.post(ApiRoutes.AUDIT_SCREENSHOT, response_model=OkResponse)
async def screenshot_taken(
    body: ScreenshotAuditIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    """Record that the caller screenshotted a conversation they belong to.
    Outsiders get 404 (silence rule) — the row would be meaningless anyway."""
    await enforce_rate_limit(user.id, "audit_screenshot", RATE_LIMIT_SCREENSHOT_AUDITS_PER_MINUTE)
    members = await MessageService.member_ids(conversation_id=body.conversation_id, db=db)
    if user.id not in members:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="conversation_not_found")
    await AuditService.log_request(
        request,
        user_id=user.id,
        action=AuditAction.SCREENSHOT_TAKEN,
        resource_type="conversation",
        resource_id=body.conversation_id,
        db=db,
    )
    await db.commit()
    return OkResponse()
