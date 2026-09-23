from __future__ import annotations

import asyncio
import base64
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api import websocket as ws_router
from app.api.ws_manager import ws_manager
from app.api.v1 import (
    admin,
    auth,
    billing,
    conversations,
    groups,
    messages,
    network,
    notifications,
    orgs,
    people,
    users,
)
from app.core.config import settings
from app.core.constants import DISAPPEAR_PURGE_INTERVAL_SEC, SCHEDULED_SEND_INTERVAL_SEC
from app.core.redis_keys import purge_lock_key, scheduled_send_lock_key
from app.core.routes import ApiPrefix
from app.db.postgres import SessionLocal
from app.db.redis import close_redis, get_redis
from app.services.file_service import FileService
from app.services.message_service import MessageService

# App loggers (doqto.*) have no handler under uvicorn's default config — give them one.
logging.basicConfig(level=logging.INFO)

logger = logging.getLogger("doqto")


async def _purge_expired_loop() -> None:
    """Soft-delete disappearing messages past their expiry, forever.

    Same pass also crypto-shreds content past the 30-day grace period
    (PURGE_CONTENT_GRACE_SEC) and deletes the backing S3 objects."""
    while True:
        try:
            # Redis NX lock: with N replicas only one runs each purge tick.
            redis = await get_redis()
            got_lock = await redis.set(
                purge_lock_key(), "1", nx=True, ex=DISAPPEAR_PURGE_INTERVAL_SEC - 5
            )
            if got_lock:
                async with SessionLocal() as db:
                    purged = await MessageService.purge_expired(db)
                    purged_keys = await MessageService.purge_content(db)
                    await db.commit()
                    if purged:
                        logger.info("purged %d expired messages", purged)
                # S3 disposal is best-effort per key; a failed delete only
                # orphans an unreferenced, SSE-encrypted object.
                for key in purged_keys:
                    try:
                        await FileService.delete_object(key=key)
                    except Exception:
                        logger.warning("purge: S3 delete failed for %s", key)
                if purged_keys:
                    logger.info("hard-purged content incl. %d S3 objects", len(purged_keys))
        except Exception:
            logger.exception("purge_expired failed")
        await asyncio.sleep(DISAPPEAR_PURGE_INTERVAL_SEC)


async def _scheduled_send_loop() -> None:
    """Deliver due scheduled messages, forever.

    Each due row goes through the same MessageService.send_text pipeline as a
    live send (encryption, seq, audit, request guards), then the standard
    NEW_MESSAGE fanout + push. Failures mark the row failed — never retried,
    so a permanently-blocked conversation can't wedge the loop."""
    from datetime import datetime, timezone

    from sqlalchemy import select

    from app.core.enums import ScheduledMessageStatus, WsEventServer
    from app.core.security import decrypt_message
    from app.models import ScheduledMessage
    from app.services.message_service import MessageError
    from app.services.push_service import PushService

    while True:
        try:
            redis = await get_redis()
            got_lock = await redis.set(
                scheduled_send_lock_key(), "1", nx=True, ex=SCHEDULED_SEND_INTERVAL_SEC - 2
            )
            if got_lock:
                async with SessionLocal() as db:
                    due = (
                        await db.scalars(
                            select(ScheduledMessage)
                            .where(
                                ScheduledMessage.status == ScheduledMessageStatus.PENDING,
                                ScheduledMessage.scheduled_at <= datetime.now(tz=timezone.utc),
                            )
                            .order_by(ScheduledMessage.scheduled_at)
                            .limit(100)
                        )
                    ).all()
                    for row in due:
                        try:
                            msg = await MessageService.send_text(
                                conversation_id=row.conversation_id,
                                sender_id=row.sender_id,
                                content=decrypt_message(row.content_encrypted),
                                db=db,
                            )
                            row.status = ScheduledMessageStatus.SENT
                            out = MessageService.to_out(msg)
                            recipients = await MessageService.member_ids(
                                conversation_id=row.conversation_id, db=db
                            )
                            await db.commit()
                            await ws_manager.publish_to_users(
                                recipients,
                                WsEventServer.NEW_MESSAGE,
                                out.model_dump(mode="json"),
                            )
                            PushService.notify_new_message(
                                conversation_id=row.conversation_id,
                                recipient_ids=recipients,
                                sender_id=row.sender_id,
                            )
                        except MessageError as e:
                            await db.rollback()
                            row.status = ScheduledMessageStatus.FAILED
                            row.error = str(e)[:100]
                            await db.commit()
                            logger.warning("scheduled send %s failed: %s", row.id, e)
        except Exception:
            logger.exception("scheduled_send failed")
        await asyncio.sleep(SCHEDULED_SEND_INTERVAL_SEC)


def verify_boot_secrets(s=settings) -> None:
    """Refuse to boot outside local with placeholder or malformed secrets.

    The weak-key fallback in app/core/security.py is local-only; this guard
    ensures non-local always has a real base64 32-byte MESSAGE_ENCRYPTION_KEY.
    """
    if s.is_local:
        return
    if s.JWT_SECRET.startswith("change-me") or s.MESSAGE_ENCRYPTION_KEY.startswith("change-me"):
        raise RuntimeError(
            "placeholder 'change-me' secrets are not allowed outside ENVIRONMENT=local"
        )
    try:
        key = base64.b64decode(s.MESSAGE_ENCRYPTION_KEY, validate=True)
    except Exception as e:
        raise RuntimeError("MESSAGE_ENCRYPTION_KEY must be valid base64") from e
    if len(key) != 32:
        raise RuntimeError("MESSAGE_ENCRYPTION_KEY must base64-decode to exactly 32 bytes")


@asynccontextmanager
async def lifespan(_: FastAPI):
    verify_boot_secrets()
    purge_task = asyncio.create_task(_purge_expired_loop())
    scheduled_task = asyncio.create_task(_scheduled_send_loop())
    # Pumps Redis pub/sub → this instance's sockets (multi-worker fanout).
    subscriber_task = asyncio.create_task(ws_manager.run_subscriber())
    yield
    purge_task.cancel()
    scheduled_task.cancel()
    subscriber_task.cancel()
    await close_redis()


app = FastAPI(title="Doqto API", version="1.0.0", lifespan=lifespan)

# Wildcard origins + credentials is never acceptable outside local dev.
if not settings.allowed_origins_list and settings.ENVIRONMENT != "local":
    raise RuntimeError("ALLOWED_ORIGINS must be set outside local environment")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins_list or ["*"],  # "*" only in local
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router, prefix=ApiPrefix.AUTH, tags=["auth"])
app.include_router(users.router, prefix=ApiPrefix.USERS, tags=["users"])
app.include_router(orgs.router, prefix=ApiPrefix.ORGS, tags=["orgs"])
app.include_router(conversations.router, prefix=ApiPrefix.CONVERSATIONS, tags=["conversations"])
app.include_router(messages.router, prefix=ApiPrefix.MESSAGES, tags=["messages"])
app.include_router(admin.router, prefix=ApiPrefix.ADMIN, tags=["admin"])
app.include_router(network.router, prefix=ApiPrefix.NETWORK, tags=["network"])
app.include_router(people.router, prefix=ApiPrefix.PEOPLE, tags=["people"])
app.include_router(groups.router, prefix=ApiPrefix.GROUPS, tags=["groups"])
app.include_router(billing.router, prefix=ApiPrefix.BILLING, tags=["billing"])
app.include_router(
    notifications.router, prefix=ApiPrefix.NOTIFICATIONS, tags=["notifications"]
)
app.include_router(ws_router.router)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "env": settings.ENVIRONMENT}


