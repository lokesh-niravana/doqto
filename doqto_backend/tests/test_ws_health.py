"""Workstream 4 — WS heartbeat ack + server-side zombie timeout.

Uses starlette's TestClient (portal thread) with WS_HEARTBEAT_TIMEOUT_SECONDS
monkeypatched tiny. The httpx harness never runs the lifespan, so the Redis
subscriber isn't pumping — heartbeat_ack is sent direct on the socket, which
is exactly what these tests exercise.
"""
from __future__ import annotations

import asyncio
import time

import pytest
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import app.api.websocket as ws_module
import app.db.redis as redis_mod
from app.core.enums import PresenceStatus, WsEventServer
from app.core.redis_keys import presence_key
from app.db.redis import get_redis
from main import app
from tests import helpers


@pytest.fixture
async def ws_user(db):
    org = await helpers.create_org(db)
    user = await helpers.create_user(db, full_name="Dr Socket")
    await helpers.add_org_member(db, org, user)
    # The app runs in the TestClient's portal thread (its own event loop):
    # drop the loop-bound global Redis client so the portal builds its own.
    redis_mod._redis = None
    yield org, user, helpers.access_token(user.id)
    redis_mod._redis = None


def _connected(user) -> dict:
    return {"type": WsEventServer.CONNECTED.value, "data": {"user_id": str(user.id)}}


async def test_heartbeat_gets_ack(ws_user, monkeypatch):
    monkeypatch.setattr(ws_module, "WS_HEARTBEAT_TIMEOUT_SECONDS", 2)
    org, user, token = ws_user
    client = TestClient(app)
    with client.websocket_connect(f"/ws/{org.id}") as ws:
        ws.send_json({"type": "auth", "token": token})
        assert ws.receive_json() == _connected(user)
        ws.send_json({"type": "heartbeat"})
        frame = ws.receive_json()
        assert frame == {"type": WsEventServer.HEARTBEAT_ACK.value, "data": {}}


# ------------------------------------------------ `connected` is the first frame
async def test_connected_is_first_frame_on_ws(ws_user):
    _, user, token = ws_user
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        ws.send_json({"type": "auth", "token": token})
        assert ws.receive_json() == _connected(user)


async def test_connected_is_first_frame_on_org_alias(ws_user):
    org, user, token = ws_user
    client = TestClient(app)
    with client.websocket_connect(f"/ws/{org.id}") as ws:
        ws.send_json({"type": "auth", "token": token})
        assert ws.receive_json() == _connected(user)


async def test_connected_arrives_for_user_with_no_org(db):
    lone = await helpers.create_user(db, full_name="Dr Lone")
    token = helpers.access_token(lone.id)
    redis_mod._redis = None
    try:
        client = TestClient(app)
        with client.websocket_connect("/ws") as ws:
            ws.send_json({"type": "auth", "token": token})
            # No org → no presence broadcast; this is the only frame they get.
            assert ws.receive_json() == _connected(lone)
    finally:
        redis_mod._redis = None


async def test_silent_socket_is_reaped_and_presence_goes_away(ws_user, monkeypatch):
    monkeypatch.setattr(ws_module, "WS_HEARTBEAT_TIMEOUT_SECONDS", 0.5)
    org, user, token = ws_user
    client = TestClient(app)
    with client.websocket_connect(f"/ws/{org.id}") as ws:
        ws.send_json({"type": "auth", "token": token})
        assert ws.receive_json() == _connected(user)
        # Send nothing more: server must close the connection after the timeout.
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()

    redis_mod._redis = None  # back on the test loop — fresh client
    redis = await get_redis()
    for _ in range(40):  # cleanup runs in the portal thread — poll briefly
        if await redis.get(presence_key(user.id)) == PresenceStatus.AWAY.value:
            break
        await asyncio.sleep(0.05)
    assert await redis.get(presence_key(user.id)) == PresenceStatus.AWAY.value


async def test_heartbeats_keep_socket_alive_past_timeout(ws_user, monkeypatch):
    monkeypatch.setattr(ws_module, "WS_HEARTBEAT_TIMEOUT_SECONDS", 0.6)
    org, user, token = ws_user
    client = TestClient(app)
    start = time.monotonic()
    with client.websocket_connect(f"/ws/{org.id}") as ws:
        ws.send_json({"type": "auth", "token": token})
        assert ws.receive_json() == _connected(user)
        # Heartbeat every ~0.3s until well past 1× the timeout.
        while time.monotonic() - start < 1.5:
            ws.send_json({"type": "heartbeat"})
            frame = ws.receive_json()
            assert frame["type"] == WsEventServer.HEARTBEAT_ACK.value
            time.sleep(0.3)
    assert time.monotonic() - start > 0.6  # survived beyond one timeout window
