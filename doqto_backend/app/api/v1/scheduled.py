"""Scheduled messages (batch 7): cancel one of my own. The per-conversation
list lives on the conversations router; this router is mounted at the bare
/api/v1 prefix for `DELETE /scheduled/{id}`."""
from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import get_current_user
from app.core.enums import ScheduledMessageStatus
from app.core.rate_limit import enforce_rate_limit
from app.core.routes import ApiRoutes
from app.db.postgres import get_db
from app.models import ScheduledMessage, User
from app.schemas.common import OkResponse

router = APIRouter()


@router.delete(ApiRoutes.SCHEDULED_DETAIL, response_model=OkResponse)
async def cancel_scheduled(
    scheduled_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> OkResponse:
    """Delete a pending scheduled message of mine. Anyone else's, an unknown
    id, or one already sent → 404 (no oracle). The row — PHI — is removed,
    not marked."""
    await enforce_rate_limit(user.id, "scheduled_cancel")
    row = await db.get(ScheduledMessage, scheduled_id)
    if row is None or row.sender_id != user.id or row.status != ScheduledMessageStatus.PENDING:
        raise HTTPException(status.HTTP_404_NOT_FOUND, detail="scheduled_message_not_found")
    await db.delete(row)
    await db.commit()
    return OkResponse()
