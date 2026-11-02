"""M0 substrate — user-scoped realtime (A1), nullable conversation scope +
key-based direct dedup (A2), org networking policy + kill switch.

WS route tests use starlette's TestClient (portal thread) like test_ws_health.
Fanout semantics are exercised at the registry level (deliver_local) with fake
sockets on a fresh WsManager — the httpx/TestClient harness never runs the
lifespan, so the Redis subscriber isn't pumping.
"""
from __future__ import annotations

import uuid

import pytest
import sqlalchemy as sa
from sqlalchemy import select
from starlette.testclient import TestClient

import app.api.ws_manager as ws_manager_module
import app.db.redis as redis_mod
from app.api.ws_manager import WsManager, decode_envelope, ws_manager
from app.core.enums import (
    AuditAction,
    ConversationAccess,
    ConversationType,
    DirectoryVisibility,
    ExternalDmPolicy,
    PresenceStatus,
    WsEventServer,
)
from app.models import (
    AuditLog,
    Conversation,
    ConversationMember,
    DirectConversationKey,
    Organization,
)
from app.services.message_service import MessageService
from main import app
from tests import helpers


class FakeSocket:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def send_json(self, payload: dict) -> None:
        self.sent.append(payload)


# ------------------------------------------------- A2: conversation scope


async def test_nullable_org_conversation_round_trips(db):
    alice = await helpers.create_user(db, full_name="Dr Alice")
    bob = await helpers.create_user(db, full_name="Dr Bob")
    conv = Conversation(org_id=None, type=ConversationType.DIRECT, created_by=alice.id)
    db.add(conv)
    await db.flush()
    db.add(ConversationMember(conversation_id=conv.id, user_id=alice.id))
    db.add(ConversationMember(conversation_id=conv.id, user_id=bob.id))
    await db.commit()

    loaded = await db.scalar(select(Conversation).where(Conversation.id == conv.id))
    assert loaded is not None
    assert loaded.org_id is None
    assert loaded.is_network is True
    assert loaded.access == ConversationAccess.OPEN


async def test_direct_dedup_is_key_based(db):
    org = await helpers.create_org(db)
    alice = await helpers.create_user(db, full_name="Dr Alice")
    bob = await helpers.create_user(db, full_name="Dr Bob")
    conv1 = await MessageService.create_conversation(
        org_id=org.id,
        creator_id=alice.id,
        conv_type=ConversationType.DIRECT,
        name=None,
        member_ids=[bob.id],
        db=db,
    )
    await db.commit()
    conv2 = await MessageService.create_conversation(
        org_id=org.id,
        creator_id=bob.id,  # reversed direction — same pair, same conversation
        conv_type=ConversationType.DIRECT,
        name=None,
        member_ids=[alice.id],
        db=db,
    )
    assert conv2.id == conv1.id
    keys = (await db.execute(select(DirectConversationKey))).scalars().all()
    assert len(keys) == 1
    assert keys[0].user_lo < keys[0].user_hi


async def test_direct_create_race_yields_exactly_one_conversation(db, monkeypatch):
    """Simulated lost race: the dedup pre-check misses but the unique
    (user_lo, user_hi) key violation resolves to the existing conversation."""
    org = await helpers.create_org(db)
    alice = await helpers.create_user(db, full_name="Dr Alice")
    bob = await helpers.create_user(db, full_name="Dr Bob")
    conv1 = await MessageService.create_conversation(
        org_id=org.id,
        creator_id=alice.id,
        conv_type=ConversationType.DIRECT,
        name=None,
        member_ids=[bob.id],
        db=db,
    )
    await db.commit()
    conv1_id = conv1.id

    real = MessageService._direct_by_pair
    calls = {"n": 0}

    async def racy_lookup(*, user_lo, user_hi, db):
        calls["n"] += 1
        if calls["n"] == 1:
            return None  # concurrent creator hasn't committed yet, from our view
        return await real(user_lo=user_lo, user_hi=user_hi, db=db)

    monkeypatch.setattr(MessageService, "_direct_by_pair", staticmethod(racy_lookup))

    conv2 = await MessageService.create_conversation(
        org_id=org.id,
        creator_id=bob.id,
        conv_type=ConversationType.DIRECT,
        name=None,
        member_ids=[alice.id],
        db=db,
    )
    assert calls["n"] == 2  # miss, insert blew up on the key, re-selected
    assert conv2.id == conv1_id
    count = await db.scalar(
        sa.text("SELECT COUNT(*) FROM direct_conversation_keys")
    )
    assert count == 1
    convs = await db.scalar(
        select(sa.func.count()).select_from(Conversation).where(
            Conversation.type == ConversationType.DIRECT
        )
    )
    assert convs == 1


# ------------------------------------------------- A1: user-scoped realtime


@pytest.fixture
async def ws_env(db):
    """Two orgs; Dr Multi belongs to both, Dr Lone belongs to none."""
    org_a = await helpers.create_org(db, name="Clinic A")
    org_b = await helpers.create_org(db, name="Clinic B")
    multi = await helpers.create_user(db, full_name="Dr Multi")
    lone = await helpers.create_user(db, full_name="Dr Lone")
    await helpers.add_org_member(db, org_a, multi)
    await helpers.add_org_member(db, org_b, multi)
    # The app runs in the TestClient's portal thread (its own event loop):
    # drop the loop-bound global Redis client so the portal builds its own.
    redis_mod._redis = None
    yield org_a, org_b, multi, lone
    redis_mod._redis = None


async def test_ws_authenticates_user_with_no_org_membership(ws_env):
    _, _, _, lone = ws_env
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        ws.send_json({"type": "auth", "token": helpers.access_token(lone.id)})
        assert ws.receive_json() == {
            "type": WsEventServer.CONNECTED.value,
            "data": {"user_id": str(lone.id)},
        }
        ws.send_json({"type": "heartbeat"})
        frame = ws.receive_json()
        assert frame == {"type": WsEventServer.HEARTBEAT_ACK.value, "data": {}}


async def test_ws_org_alias_registers_user_in_flat_registry(ws_env):
    org_a, _, multi, _ = ws_env
    client = TestClient(app)
    with client.websocket_connect(f"/ws/{org_a.id}") as ws:
        ws.send_json({"type": "auth", "token": helpers.access_token(multi.id)})
        assert ws.receive_json() == {
            "type": WsEventServer.CONNECTED.value,
            "data": {"user_id": str(multi.id)},
        }
        ws.send_json({"type": "heartbeat"})
        frame = ws.receive_json()
        assert frame == {"type": WsEventServer.HEARTBEAT_ACK.value, "data": {}}
        # The alias lands in the same user-scoped registry with the full
        # org snapshot — this is what makes fanout deliver to it.
        assert multi.id in ws_manager._by_user
        assert ws_manager._orgs_by_user[multi.id] >= {org_a.id}
    # cleanup happens in the portal thread on context exit


async def test_ws_connect_publishes_presence_per_org(ws_env, monkeypatch):
    org_a, org_b, multi, _ = ws_env
    published: list[tuple[uuid.UUID, str, dict]] = []

    async def record_publish_org(org_id, event, data):
        published.append((org_id, event.value, data))

    monkeypatch.setattr(ws_manager, "publish_org", record_publish_org)
    client = TestClient(app)
    with client.websocket_connect("/ws") as ws:
        ws.send_json({"type": "auth", "token": helpers.access_token(multi.id)})
        ws.receive_json()  # connected
        ws.send_json({"type": "heartbeat"})
        ws.receive_json()  # ack — connect path fully ran
        online = [
            (org, data)
            for org, event, data in published
            if event == WsEventServer.PRESENCE_UPDATE.value
            and data["status"] == PresenceStatus.ONLINE.value
        ]
        assert {org for org, _ in online} == {org_a.id, org_b.id}
        assert all(d["user_id"] == str(multi.id) for _, d in online)


async def test_publish_envelopes_use_new_recipient_shapes(monkeypatch):
    manager = WsManager()
    wire: list[str] = []

    class FakeRedis:
        async def publish(self, channel, payload):
            wire.append(payload)

    async def fake_get_redis():
        return FakeRedis()

    monkeypatch.setattr(ws_manager_module, "get_redis", fake_get_redis)

    uid = uuid.uuid4()
    org = uuid.uuid4()
    await manager.publish_to_users([uid], WsEventServer.NEW_MESSAGE, {"x": 1})
    await manager.publish_org(org, WsEventServer.PRESENCE_UPDATE, {"y": 2})

    users_env = decode_envelope(wire[0])
    assert users_env == {
        "type": "new_message",
        "data": {"x": 1},
        "recipients": [str(uid)],
    }
    org_env = decode_envelope(wire[1])
    assert org_env == {
        "type": "presence_update",
        "data": {"y": 2},
        "recipients": {"org_id": str(org)},
    }


async def test_deliver_local_user_list_hits_only_listed_users():
    manager = WsManager()
    org = uuid.uuid4()
    alice, bob, carol = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    socks = {u: FakeSocket() for u in (alice, bob, carol)}
    for u, s in socks.items():
        await manager.connect(u, s, frozenset({org}))

    await manager.deliver_local(
        {
            "type": "new_message",
            "data": {"n": 1},
            "recipients": [str(alice), str(bob)],
        }
    )
    assert socks[alice].sent == [{"type": "new_message", "data": {"n": 1}}]
    assert socks[bob].sent == [{"type": "new_message", "data": {"n": 1}}]
    assert socks[carol].sent == []


async def test_deliver_local_org_broadcast_hits_only_that_orgs_members():
    manager = WsManager()
    org_a, org_b = uuid.uuid4(), uuid.uuid4()
    in_a, in_both, in_b = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    socks = {in_a: FakeSocket(), in_both: FakeSocket(), in_b: FakeSocket()}
    await manager.connect(in_a, socks[in_a], frozenset({org_a}))
    await manager.connect(in_both, socks[in_both], frozenset({org_a, org_b}))
    await manager.connect(in_b, socks[in_b], frozenset({org_b}))

    await manager.deliver_local(
        {
            "type": "presence_update",
            "data": {"s": "online"},
            "recipients": {"org_id": str(org_a)},
        }
    )
    assert len(socks[in_a].sent) == 1
    assert len(socks[in_both].sent) == 1
    assert socks[in_b].sent == []


async def test_deliver_local_tolerates_legacy_envelope_shapes():
    manager = WsManager()
    org = uuid.uuid4()
    alice, bob = uuid.uuid4(), uuid.uuid4()
    a_sock, b_sock = FakeSocket(), FakeSocket()
    await manager.connect(alice, a_sock, frozenset({org}))
    await manager.connect(bob, b_sock, frozenset())  # no org membership

    # Legacy user-list shape: top-level org_id + recipients list.
    await manager.deliver_local(
        {
            "org_id": str(org),
            "type": "new_message",
            "data": {"n": 1},
            "recipients": [str(bob)],
        }
    )
    assert b_sock.sent == [{"type": "new_message", "data": {"n": 1}}]
    assert a_sock.sent == []

    # Legacy org broadcast: top-level org_id, recipients=None.
    await manager.deliver_local(
        {
            "org_id": str(org),
            "type": "presence_update",
            "data": {"s": "away"},
            "recipients": None,
        }
    )
    assert a_sock.sent == [{"type": "presence_update", "data": {"s": "away"}}]
    assert len(b_sock.sent) == 1  # unchanged — not in the org


# ------------------------------------------------- kill switch endpoint


async def test_networking_settings_requires_org_admin(client, db):
    org = await helpers.create_org(db)
    doctor = await helpers.create_user(db, full_name="Dr Doctor")
    await helpers.add_org_member(db, org, doctor)  # plain doctor
    resp = await client.patch(
        f"/api/v1/orgs/{org.id}/settings/networking",
        json={"external_networking_enabled": False},
        headers=await helpers.auth_headers(doctor.id),
    )
    assert resp.status_code == 403


async def test_networking_settings_updates_and_audits(client, db):
    from app.core.enums import OrgRole

    org = await helpers.create_org(db)
    admin = await helpers.create_user(db, full_name="Dr Admin")
    await helpers.add_org_member(db, org, admin, role=OrgRole.ADMIN)
    resp = await client.patch(
        f"/api/v1/orgs/{org.id}/settings/networking",
        json={
            "external_networking_enabled": False,
            "external_dm_policy": "connections_only",
            "directory_visibility": "org_only",
        },
        headers=await helpers.auth_headers(admin.id),
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["external_networking_enabled"] is False
    assert body["external_dm_policy"] == ExternalDmPolicy.CONNECTIONS_ONLY.value
    assert body["directory_visibility"] == DirectoryVisibility.ORG_ONLY.value

    loaded = await db.scalar(select(Organization).where(Organization.id == org.id))
    await db.refresh(loaded)  # bypass this session's stale identity-map copy
    assert loaded.external_networking_enabled is False
    assert loaded.external_dm_policy == ExternalDmPolicy.CONNECTIONS_ONLY
    assert loaded.directory_visibility == DirectoryVisibility.ORG_ONLY

    audit = (
        await db.execute(
            select(AuditLog).where(
                AuditLog.action == AuditAction.ORG_POLICY_CHANGED.value
            )
        )
    ).scalars().all()
    assert len(audit) == 1
    assert audit[0].user_id == admin.id
    assert audit[0].resource_id == org.id
    assert audit[0].meta["external_networking_enabled"] is False


async def test_org_defaults_networking_on(db):
    org = await helpers.create_org(db)
    assert org.external_networking_enabled is True
    assert org.external_dm_policy == ExternalDmPolicy.CONNECTIONS_AND_REQUESTS
    assert org.directory_visibility == DirectoryVisibility.NETWORK
