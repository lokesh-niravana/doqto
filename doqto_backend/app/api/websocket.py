from __future__ import annotations

import asyncio
import logging
import time
import uuid

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from redis.asyncio import Redis
from sqlalchemy import select

from app.api.ws_manager import ws_manager
from app.core.constants import (
    PRESENCE_AWAY_TTL_SECONDS,
    PRESENCE_ONLINE_TTL_SECONDS,
    WS_HEARTBEAT_TIMEOUT_SECONDS,
)
from app.core.enums import JwtTokenType, PresenceStatus, WsEventClient, WsEventServer
from app.core.redis_keys import presence_key
from app.core.security import TokenError, decode_token
from app.db.postgres import SessionLocal
from app.db.redis import get_redis
from app.models import OrgMember, User
from app.services.message_service import MessageService
from app.services.presence_service import PresenceService

logger = logging.getLogger(__name__)

router = APIRouter()

# Typing fires per keystroke — cache conversation membership briefly so we
# don't hit Postgres on every event.
# ponytail: in-process TTL dict; move to Redis if membership churn matters.
_MEMBERS_TTL_SEC = 60
_members_cache: dict[str, tuple[float, list[uuid.UUID]]] = {}


async def _cached_member_ids(conversation_id: str) -> list[uuid.UUID]:
    hit = _members_cache.get(conversation_id)
    now = time.monotonic()
    if hit is not None and hit[0] > now:
        return hit[1]
    async with SessionLocal() as db:
        ids = await MessageService.member_ids(
            conversation_id=uuid.UUID(conversation_id), db=db
        )
    _members_cache[conversation_id] = (now + _MEMBERS_TTL_SEC, ids)
    return ids


async def _authorize(token: str) -> tuple[uuid.UUID, frozenset[uuid.UUID]]:
    """User-scoped auth (A1): the socket belongs to a user, not an org.

    Returns (user_id, active org ids) — the org snapshot routes org-wide
    (presence) broadcasts for this connection's lifetime."""
    payload = decode_token(token, JwtTokenType.ACCESS)
    user_id = uuid.UUID(payload["sub"])
    async with SessionLocal() as db:
        user = await db.scalar(select(User).where(User.id == user_id))
        if user is None:
            raise TokenError("user_not_found")
        rows = await db.execute(
            select(OrgMember.org_id).where(OrgMember.user_id == user_id)
        )
        org_ids = frozenset(rows.scalars().all())
    return user_id, org_ids


async def _run_socket(websocket: WebSocket) -> None:
    # Auth-frame only: the token must arrive in a first `auth` frame.
    # A `?token=` query string is never read (query strings end up in
    # proxy/access logs — M1).
    await websocket.accept()
    try:
        first = await asyncio.wait_for(websocket.receive_json(), timeout=5)
        if first.get("type") != "auth" or not isinstance(first.get("token"), str):
            raise TokenError("missing_auth_frame")
        user_id, org_ids = await _authorize(first["token"])
    except Exception:
        await websocket.close(code=4401)
        return
    await ws_manager.connect(user_id, websocket, org_ids)
    # Direct (no fanout): tells the client auth succeeded and the socket is
    # registered — the only frame an org-less user would otherwise never get.
    await websocket.send_json(
        {"type": WsEventServer.CONNECTED.value, "data": {"user_id": str(user_id)}}
    )
    redis: Redis = await get_redis()
    await redis.setex(presence_key(user_id), PRESENCE_ONLINE_TTL_SECONDS, PresenceStatus.ONLINE.value)
    # Durable last-seen stamp (throttled) + one presence event to the user's
    # audience: org colleagues AND first-degree connections, filtered by the
    # user's own visibility settings (batch 2).
    async with SessionLocal() as db:
        await PresenceService.touch_last_seen(user_id, db)
        await PresenceService.publish(user_id, PresenceStatus.ONLINE, db)

    try:
        while True:
            try:
                # Zombie reaper: a client silent past 2 missed heartbeats is dead.
                msg = await asyncio.wait_for(
                    websocket.receive_json(), timeout=WS_HEARTBEAT_TIMEOUT_SECONDS
                )
            except TimeoutError:
                try:
                    await websocket.close(code=1001)  # going away
                except Exception:
                    pass  # socket already dead
                break  # finally handles presence + cleanup
            msg_type = msg.get("type")
            if msg_type == WsEventClient.HEARTBEAT.value:
                await redis.setex(
                    presence_key(user_id), PRESENCE_ONLINE_TTL_SECONDS, PresenceStatus.ONLINE.value
                )
                async with SessionLocal() as db:
                    await PresenceService.touch_last_seen(user_id, db)
                # Direct ack (no fanout) — the client's liveness signal.
                await websocket.send_json(
                    {"type": WsEventServer.HEARTBEAT_ACK.value, "data": {}}
                )
            elif msg_type in (WsEventClient.TYPING_START.value, WsEventClient.TYPING_STOP.value):
                event = (
                    WsEventServer.TYPING_START
                    if msg_type == WsEventClient.TYPING_START.value
                    else WsEventServer.TYPING_STOP
                )
                conv_id = msg.get("conversation_id")
                if not isinstance(conv_id, str):
                    continue
                try:
                    recipients = await _cached_member_ids(conv_id)
                except Exception:
                    continue  # malformed/unknown conversation id
                if user_id not in recipients:
                    continue  # not a member: drop, don't leak typing signals
                await ws_manager.publish_to_users(
                    recipients,
                    event,
                    {"conversation_id": conv_id, "user_id": str(user_id)},
                )
    except WebSocketDisconnect:
        pass
    finally:
        await ws_manager.disconnect(user_id, websocket)
        await redis.setex(presence_key(user_id), PRESENCE_AWAY_TTL_SECONDS, PresenceStatus.AWAY.value)
        try:
            async with SessionLocal() as db:
                seen = await PresenceService.touch_last_seen(user_id, db, force=True)
                await PresenceService.publish(
                    user_id, PresenceStatus.AWAY, db, last_seen_at=seen
                )
        except Exception:
            logger.exception("presence disconnect bookkeeping failed")


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    """User-scoped socket (A1): any active user, org membership optional."""
    await _run_socket(websocket)


@router.websocket("/ws/{org_id}")
async def websocket_endpoint_org_alias(websocket: WebSocket, org_id: uuid.UUID) -> None:
    """Legacy alias for one release: the path org is ignored for auth/routing
    (logged only) — same user-scoped registry, presence for ALL the user's orgs."""
    logger.debug("legacy /ws/%s alias connection", org_id)
    await _run_socket(websocket)
