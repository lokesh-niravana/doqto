"""Batch 2 — privacy screen fields, profile field visibility, presence + last
seen, read-receipt opt-out, default disappearing timer, blocked list.

Policy branches covered: owner hides → viewer gets null; the reciprocal rule;
connections-only vs org colleague vs stranger; blocked pairs; the blocker's
view of a blocked profile (the blocked party still gets 404).
"""
from __future__ import annotations

import asyncio
import uuid
from types import SimpleNamespace

import pytest
from sqlalchemy import select
from starlette.testclient import TestClient

import app.api.v1.conversations as conversations_module
import app.api.websocket as ws_module
import app.api.v1.messages as messages_module
import app.db.redis as redis_mod
import app.services.presence_service as presence_module
from app.core.constants import PRESENCE_ONLINE_TTL_SECONDS
from app.core.enums import (
    AuditAction,
    ConversationType,
    LastSeenVisibility,
    OnlineVisibility,
    PresenceStatus,
    ProfileFieldVisibility,
    WsEventServer,
)
from app.core.permissions import (
    PrivacySnapshot,
    RelationshipContext,
    can_see_about,
    can_see_last_seen,
    can_see_online,
    can_see_profile_photo,
)
from app.core.redis_keys import presence_key
from app.db.redis import get_redis
from app.models import AuditLog, Block, Conversation, User, UserPrivacySettings
from main import app
from tests import helpers

USERS = "/api/v1/users"
PRIVACY = f"{USERS}/me/privacy"
PRESENCE = f"{USERS}/presence"
CONVS = "/api/v1/conversations"
A, B, ORG = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
async def _user(db, org, name, **kw):
    u = await helpers.create_user(db, full_name=name, **kw)
    if org is not None:
        await helpers.add_org_member(db, org, u)
    return u, await helpers.auth_headers(u.id)


async def _set(client, headers, **fields):
    r = await client.patch(PRIVACY, json=fields, headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def _presence_of(client, headers, *ids):
    r = await client.get(PRESENCE, params={"ids": ",".join(str(i) for i in ids)}, headers=headers)
    assert r.status_code == 200, r.text
    return {row["user_id"]: row for row in r.json()}


async def _mark_online(user_id):
    redis = await get_redis()
    await redis.setex(presence_key(user_id), PRESENCE_ONLINE_TTL_SECONDS, PresenceStatus.ONLINE.value)


def _recorder(monkeypatch, module):
    sent: list[tuple[set[uuid.UUID], WsEventServer, dict]] = []

    async def publish_to_users(user_ids, event, data):
        sent.append((set(user_ids), event, data))

    async def publish_org(org_id, event, data):
        pass

    monkeypatch.setattr(
        module, "ws_manager", SimpleNamespace(publish_to_users=publish_to_users, publish_org=publish_org)
    )
    return sent


def _ctx(**kw) -> RelationshipContext:
    base = dict(viewer_id=A, target_id=B)
    base.update(kw)
    return RelationshipContext(**base)


# --------------------------------------------------------------------------- #
# Pure rules
# --------------------------------------------------------------------------- #
def test_last_seen_default_is_connections_and_colleagues_count():
    assert can_see_last_seen(_ctx(is_first_degree=True))
    assert can_see_last_seen(_ctx(shared_org_ids=frozenset({ORG})))
    assert not can_see_last_seen(_ctx())  # stranger


def test_last_seen_everyone_nobody_and_reciprocal():
    everyone = PrivacySnapshot(last_seen_visibility=LastSeenVisibility.EVERYONE)
    nobody = PrivacySnapshot(last_seen_visibility=LastSeenVisibility.NOBODY)
    assert can_see_last_seen(_ctx(target_privacy=everyone))
    assert not can_see_last_seen(_ctx(target_privacy=nobody, is_first_degree=True))
    # Reciprocal: hiding mine hides everyone else's from me.
    assert not can_see_last_seen(_ctx(viewer_privacy=nobody, target_privacy=everyone))
    assert not can_see_last_seen(_ctx(is_blocked_either_way=True, target_privacy=everyone))
    assert not can_see_last_seen(_ctx(target_id=A, is_first_degree=True))  # self


def test_online_follows_last_seen_unless_hidden():
    hidden = PrivacySnapshot(online_visibility=OnlineVisibility.NOBODY)
    assert can_see_online(_ctx(is_first_degree=True))
    assert not can_see_online(_ctx(is_first_degree=True, target_privacy=hidden))
    assert can_see_last_seen(_ctx(is_first_degree=True, target_privacy=hidden))


def test_photo_and_about_visibility():
    conn_only = PrivacySnapshot(
        profile_photo_visibility=ProfileFieldVisibility.CONNECTIONS,
        about_visibility=ProfileFieldVisibility.CONNECTIONS,
    )
    assert can_see_profile_photo(_ctx()) and can_see_about(_ctx())
    assert not can_see_profile_photo(_ctx(target_privacy=conn_only))
    assert not can_see_about(_ctx(target_privacy=conn_only))
    assert can_see_about(_ctx(target_privacy=conn_only, is_first_degree=True))
    assert can_see_profile_photo(_ctx(target_privacy=conn_only, shared_org_ids=frozenset({ORG})))
    assert not can_see_about(_ctx(is_blocked_either_way=True))


# --------------------------------------------------------------------------- #
# Settings endpoint
# --------------------------------------------------------------------------- #
async def test_privacy_defaults_patch_roundtrip_and_audit(client, db):
    alice, ah = await _user(db, None, "Dr Alice")
    r = await client.get(PRIVACY, headers=ah)
    assert r.status_code == 200
    body = r.json()
    assert body["last_seen_visibility"] == "connections"
    assert body["online_visibility"] == "same_as_last_seen"
    assert body["profile_photo_visibility"] == "everyone"
    assert body["about_visibility"] == "everyone"
    assert body["read_receipts"] is True
    assert body["default_disappear_sec"] is None
    assert body["link_previews"] is True

    out = await _set(
        client,
        ah,
        last_seen_visibility="nobody",
        online_visibility="nobody",
        about_visibility="connections",
        read_receipts=False,
        default_disappear_sec=86400,
        link_previews=False,
    )
    assert out["last_seen_visibility"] == "nobody"
    assert out["default_disappear_sec"] == 86400
    assert out["read_receipts"] is False and out["link_previews"] is False
    # Untouched fields keep their values on a partial patch.
    out = await _set(client, ah, default_disappear_sec=None)
    assert out["default_disappear_sec"] is None and out["last_seen_visibility"] == "nobody"

    rows = (
        await db.scalars(
            select(AuditLog).where(
                AuditLog.user_id == alice.id, AuditLog.action == AuditAction.PRIVACY_UPDATED.value
            )
        )
    ).all()
    assert len(rows) == 2
    assert "read_receipts" in rows[0].meta["fields"]


async def test_privacy_patch_rejects_unknown_timer_and_values(client, db):
    _, ah = await _user(db, None, "Dr Alice")
    r = await client.patch(PRIVACY, json={"default_disappear_sec": 12345}, headers=ah)
    assert r.status_code == 422
    r = await client.patch(PRIVACY, json={"last_seen_visibility": "friends"}, headers=ah)
    assert r.status_code == 422


# --------------------------------------------------------------------------- #
# Public profile field visibility
# --------------------------------------------------------------------------- #
@pytest.fixture
def presign(monkeypatch):
    from app.services.file_service import FileService

    async def fake(*, key):
        return f"https://cdn.test/{key}"

    monkeypatch.setattr(FileService, "presigned_url", staticmethod(fake))


async def test_profile_about_and_photo_per_audience(client, db, presign):
    org = await helpers.create_org(db)
    owner, oh = await _user(db, org, "Dr Owner")
    owner.bio = "Interventional cardiologist, 12 years"
    owner.avatar_url = "avatars/owner/pic.jpg"
    await db.commit()
    colleague, colh = await _user(db, org, "Dr Colleague")
    stranger, sh = await _user(db, None, "Dr Stranger")
    connection, conh = await _user(db, None, "Dr Connection")
    await helpers.connect_users(db, owner, connection)

    # Defaults (everyone): the stranger sees both.
    body = (await client.get(f"{USERS}/{owner.id}/profile", headers=sh)).json()
    assert body["about"] == owner.bio and body["avatar_presigned_url"]

    await _set(client, oh, about_visibility="connections", profile_photo_visibility="connections")
    body = (await client.get(f"{USERS}/{owner.id}/profile", headers=sh)).json()
    assert body["about"] is None
    assert body["avatar_url"] is None and body["avatar_presigned_url"] is None
    assert body["avatar_color"] == owner.avatar_color  # initials fallback stays
    for h in (colh, conh):
        body = (await client.get(f"{USERS}/{owner.id}/profile", headers=h)).json()
        assert body["about"] == owner.bio, "colleagues and connections keep seeing it"
        assert body["avatar_presigned_url"] == "https://cdn.test/avatars/owner/pic.jpg"


async def test_blocker_sees_card_with_unblock_state_blocked_sees_404(client, db):
    org = await helpers.create_org(db)
    blocker, bh = await _user(db, org, "Dr Blocker")
    blocked, blh = await _user(db, org, "Dr Blocked")
    blocked.bio = "secret"
    await db.commit()
    db.add(Block(blocker_id=blocker.id, blocked_id=blocked.id))
    await db.commit()

    r = await client.get(f"{USERS}/{blocked.id}/profile", headers=bh)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["connection_state"] == "blocked"
    assert body["can_message"] == "denied"
    assert body["about"] is None and body["avatar_presigned_url"] is None
    assert body["full_name"] == "Dr Blocked"

    r = await client.get(f"{USERS}/{blocker.id}/profile", headers=blh)
    assert r.status_code == 404 and r.json()["detail"] == "user_unavailable"


# --------------------------------------------------------------------------- #
# GET /users/presence
# --------------------------------------------------------------------------- #
async def test_presence_audience_matrix(client, db):
    org = await helpers.create_org(db)
    owner, oh = await _user(db, org, "Dr Owner")
    colleague, colh = await _user(db, org, "Dr Colleague")
    connection, conh = await _user(db, None, "Dr Connection")
    stranger, sh = await _user(db, None, "Dr Stranger")
    await helpers.connect_users(db, owner, connection)
    await _mark_online(owner.id)
    await presence_module.PresenceService.touch_last_seen(owner.id, db, force=True)

    # Default = connections: colleague + connection see online + last seen.
    for h in (colh, conh):
        row = (await _presence_of(client, h, owner.id))[str(owner.id)]
        assert row["status"] == "online" and row["last_seen_at"] is not None
    row = (await _presence_of(client, sh, owner.id))[str(owner.id)]
    assert row["status"] == "offline" and row["last_seen_at"] is None

    await _set(client, oh, last_seen_visibility="everyone")
    row = (await _presence_of(client, sh, owner.id))[str(owner.id)]
    assert row["status"] == "online" and row["last_seen_at"] is not None

    # Owner hides → every viewer gets offline/null, even a connection.
    await _set(client, oh, last_seen_visibility="nobody")
    for h in (colh, conh, sh):
        row = (await _presence_of(client, h, owner.id))[str(owner.id)]
        assert row == {
            "user_id": str(owner.id),
            "status": "offline",
            "last_seen_at": None,
            # Status under the name (batch 6) — none set here.
            "status_preset": None,
            "status_text": None,
            "status_expires_at": None,
        }


async def test_presence_reciprocal_rule(client, db):
    org = await helpers.create_org(db)
    owner, oh = await _user(db, org, "Dr Owner")
    viewer, vh = await _user(db, org, "Dr Viewer")
    await _mark_online(owner.id)
    await presence_module.PresenceService.touch_last_seen(owner.id, db, force=True)
    row = (await _presence_of(client, vh, owner.id))[str(owner.id)]
    assert row["status"] == "online"
    # The viewer hides their own last seen → sees nobody's.
    await _set(client, vh, last_seen_visibility="nobody")
    row = (await _presence_of(client, vh, owner.id))[str(owner.id)]
    assert row["status"] == "offline" and row["last_seen_at"] is None


async def test_presence_online_hidden_keeps_last_seen(client, db):
    org = await helpers.create_org(db)
    owner, oh = await _user(db, org, "Dr Owner")
    viewer, vh = await _user(db, org, "Dr Viewer")
    await _mark_online(owner.id)
    await presence_module.PresenceService.touch_last_seen(owner.id, db, force=True)
    await _set(client, oh, online_visibility="nobody")
    row = (await _presence_of(client, vh, owner.id))[str(owner.id)]
    assert row["status"] == "offline" and row["last_seen_at"] is not None


async def test_presence_blocked_unknown_and_limits(client, db):
    org = await helpers.create_org(db)
    owner, oh = await _user(db, org, "Dr Owner")
    viewer, vh = await _user(db, org, "Dr Viewer")
    await _mark_online(owner.id)
    db.add(Block(blocker_id=owner.id, blocked_id=viewer.id))
    await db.commit()
    rows = await _presence_of(client, vh, owner.id, uuid.uuid4())
    assert list(rows) == [str(owner.id)], "unknown ids are omitted"
    assert rows[str(owner.id)]["status"] == "offline"
    assert rows[str(owner.id)]["last_seen_at"] is None

    too_many = ",".join(str(uuid.uuid4()) for _ in range(51))
    r = await client.get(PRESENCE, params={"ids": too_many}, headers=vh)
    assert r.status_code == 422
    r = await client.get(PRESENCE, params={"ids": "not-a-uuid"}, headers=vh)
    assert r.status_code == 422


# --------------------------------------------------------------------------- #
# WS: last_seen_at bookkeeping + privacy-filtered fanout
# --------------------------------------------------------------------------- #
@pytest.fixture
async def ws_people(db):
    org = await helpers.create_org(db)
    me = await helpers.create_user(db, full_name="Dr Me")
    colleague = await helpers.create_user(db, full_name="Dr Colleague")
    hider = await helpers.create_user(db, full_name="Dr Hider")
    connection = await helpers.create_user(db, full_name="Dr Connection")
    stranger = await helpers.create_user(db, full_name="Dr Stranger")
    for u in (me, colleague, hider):
        await helpers.add_org_member(db, org, u)
    await helpers.connect_users(db, me, connection)
    redis_mod._redis = None
    yield SimpleNamespace(
        me=me, colleague=colleague, hider=hider, connection=connection, stranger=stranger
    )
    redis_mod._redis = None


async def _hide_last_seen(db, user_id):
    """Straight to Postgres: an httpx call here would bind the global Redis
    client to the test loop before the TestClient portal thread needs it."""
    db.add(UserPrivacySettings(user_id=user_id, last_seen_visibility=LastSeenVisibility.NOBODY))
    await db.commit()


async def test_ws_presence_goes_to_connections_and_colleagues_not_hiders(
    ws_people, db, monkeypatch
):
    """Connect → `online` to colleagues + connections (never the hider, never
    the stranger). The socket then goes silent past the heartbeat deadline:
    the server reaps it and the SAME finally-block as a client disconnect
    stamps last_seen_at and publishes `away` with it. (The TestClient cancels
    the handler on context exit, so a client close can't be observed here.)"""
    p = ws_people
    await _hide_last_seen(db, p.hider.id)
    sent = _recorder(monkeypatch, presence_module)
    monkeypatch.setattr(ws_module, "WS_HEARTBEAT_TIMEOUT_SECONDS", 1)
    redis_mod._redis = None
    tc = TestClient(app)
    with tc.websocket_connect("/ws") as ws:
        ws.send_json({"type": "auth", "token": helpers.access_token(p.me.id)})
        ws.receive_json()
        ws.send_json({"type": "heartbeat"})
        ws.receive_json()  # ack — the connect path fully ran
        for _ in range(100):
            if any(d["status"] == "away" for _, _, d in sent):
                break
            await asyncio.sleep(0.05)
    online = [(ids, d) for ids, ev, d in sent if d["status"] == "online"]
    away = [(ids, d) for ids, ev, d in sent if d["status"] == "away"]
    assert len(online) == 1 and len(away) == 1
    assert online[0][0] == {p.colleague.id, p.connection.id}
    assert away[0][0] == {p.colleague.id, p.connection.id}
    assert away[0][1]["last_seen_at"] is not None, "disconnect stamps last seen"
    assert all(ev == WsEventServer.PRESENCE_UPDATE for _, ev, _ in sent)
    assert await db.scalar(select(User.last_seen_at).where(User.id == p.me.id)) is not None


async def test_ws_presence_silent_when_owner_hides(ws_people, db, monkeypatch):
    p = ws_people
    me_id = p.me.id
    await _hide_last_seen(db, me_id)
    sent = _recorder(monkeypatch, presence_module)
    redis_mod._redis = None
    tc = TestClient(app)
    with tc.websocket_connect("/ws") as ws:
        ws.send_json({"type": "auth", "token": helpers.access_token(me_id)})
        ws.receive_json()
        ws.send_json({"type": "heartbeat"})
        ws.receive_json()  # ack — the connect path fully ran
    assert sent == []
    seen = await db.scalar(select(User.last_seen_at).where(User.id == me_id))
    assert seen is not None, "still recorded for the owner's own view"


async def test_last_seen_write_is_throttled(db):
    user = await helpers.create_user(db, full_name="Dr Throttle")
    svc = presence_module.PresenceService
    first = await svc.touch_last_seen(user.id, db)
    second = await svc.touch_last_seen(user.id, db)
    forced = await svc.touch_last_seen(user.id, db, force=True)
    assert first is not None and second is None and forced is not None


# --------------------------------------------------------------------------- #
# Read receipts opt-out (direct chats only)
# --------------------------------------------------------------------------- #
async def test_read_receipts_off_stops_event_and_hides_blue_ticks(client, chat, db, monkeypatch):
    conv_ws = _recorder(monkeypatch, conversations_module)
    msg_ws = _recorder(monkeypatch, messages_module)
    await _set(client, chat.bob_headers, read_receipts=False)

    r = await client.post(
        f"{CONVS}/{chat.conv.id}/messages", json={"content": "lab results in"}, headers=chat.alice_headers
    )
    assert r.status_code == 200, r.text
    mid = r.json()["id"]

    # Bob reads (both routes) — stored, not emitted.
    assert (await client.post(f"{CONVS}/{chat.conv.id}/read", headers=chat.bob_headers)).status_code == 200
    assert (await client.post(f"/api/v1/messages/{mid}/read", headers=chat.bob_headers)).status_code == 200
    assert not [1 for _, ev, _ in conv_ws if ev == WsEventServer.MESSAGE_READ]
    assert not [1 for _, ev, _ in msg_ws if ev == WsEventServer.MESSAGE_READ]

    msgs = (await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.alice_headers)).json()
    mine = next(m for m in msgs if m["id"] == mid)
    assert mine["read"] is False and mine["delivered"] is True
    receipts = (await client.get(f"/api/v1/messages/{mid}/receipts", headers=chat.alice_headers)).json()
    assert receipts[0]["read"] is False and receipts[0]["read_at"] is None
    assert receipts[0]["delivered"] is True

    # Bob turns them back on: the stored receipt surfaces at once.
    await _set(client, chat.bob_headers, read_receipts=True)
    msgs = (await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.alice_headers)).json()
    assert next(m for m in msgs if m["id"] == mid)["read"] is True
    receipts = (await client.get(f"/api/v1/messages/{mid}/receipts", headers=chat.alice_headers)).json()
    assert receipts[0]["read"] is True and receipts[0]["read_at"] is not None


async def test_read_receipts_off_applies_when_the_sender_opted_out(client, chat, db, monkeypatch):
    conv_ws = _recorder(monkeypatch, conversations_module)
    await _set(client, chat.alice_headers, read_receipts=False)  # the SENDER opts out
    r = await client.post(
        f"{CONVS}/{chat.conv.id}/messages", json={"content": "hi"}, headers=chat.alice_headers
    )
    mid = r.json()["id"]
    await client.post(f"{CONVS}/{chat.conv.id}/read", headers=chat.bob_headers)
    assert not [1 for _, ev, _ in conv_ws if ev == WsEventServer.MESSAGE_READ]
    msgs = (await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.alice_headers)).json()
    assert next(m for m in msgs if m["id"] == mid)["read"] is False


async def test_read_receipts_group_chats_always_on(client, db, monkeypatch):
    conv_ws = _recorder(monkeypatch, conversations_module)
    org = await helpers.create_org(db)
    alice, ah = await _user(db, org, "Dr Alice")
    bob, bh = await _user(db, org, "Dr Bob")
    conv = await helpers.create_conversation(
        db, org, [alice, bob], conv_type=ConversationType.GROUP, name="Rounds"
    )
    await _set(client, bh, read_receipts=False)
    r = await client.post(f"{CONVS}/{conv.id}/messages", json={"content": "hi"}, headers=ah)
    mid = r.json()["id"]
    await client.post(f"{CONVS}/{conv.id}/read", headers=bh)
    assert [1 for _, ev, _ in conv_ws if ev == WsEventServer.MESSAGE_READ]
    msgs = (await client.get(f"{CONVS}/{conv.id}/messages", headers=ah)).json()
    assert next(m for m in msgs if m["id"] == mid)["read"] is True


# --------------------------------------------------------------------------- #
# Default disappearing timer
# --------------------------------------------------------------------------- #
async def test_default_disappear_applies_to_new_direct_chats_only(client, db):
    org = await helpers.create_org(db)
    alice, ah = await _user(db, org, "Dr Alice")
    bob, bh = await _user(db, org, "Dr Bob")
    carol, _ = await _user(db, org, "Dr Carol")
    # Existing thread with Bob (created before the default) — must not change.
    r = await client.post(CONVS, json={"type": "direct", "member_ids": [str(bob.id)]}, headers=ah)
    existing_id = r.json()["id"]
    await _set(client, ah, default_disappear_sec=604800)

    r = await client.post(CONVS, json={"type": "direct", "member_ids": [str(bob.id)]}, headers=ah)
    assert r.status_code == 200 and r.json()["id"] == existing_id
    assert r.json()["disappear_after_sec"] is None

    r = await client.post(CONVS, json={"type": "direct", "member_ids": [str(carol.id)]}, headers=ah)
    assert r.status_code == 200, r.text
    assert r.json()["disappear_after_sec"] == 604800
    conv = await db.get(Conversation, uuid.UUID(r.json()["id"]))
    assert conv.disappear_after_sec == 604800


# --------------------------------------------------------------------------- #
# Blocked list
# --------------------------------------------------------------------------- #
async def test_blocks_list_is_a_card_page(client, db):
    org = await helpers.create_org(db)
    me, mh = await _user(db, org, "Dr Me")
    other, _ = await _user(db, org, "Dr Other", specialty="Cardiology", city="Austin", state="TX")
    r = await client.post(f"/api/v1/network/blocks/{other.id}", headers=mh)
    assert r.status_code == 200, r.text
    r = await client.get("/api/v1/network/blocks", headers=mh)
    assert r.status_code == 200
    page = r.json()
    assert page["next_cursor"] is None
    [card] = page["data"]
    assert card["id"] == str(other.id) and card["blocked_id"] == str(other.id)
    assert card["full_name"] == "Dr Other" and card["location_label"] == "Austin, TX"
    assert {"phone", "email", "npi_number"}.isdisjoint(card)
    r = await client.delete(f"/api/v1/network/blocks/{other.id}", headers=mh)
    assert r.status_code == 200
    assert (await client.get("/api/v1/network/blocks", headers=mh)).json()["data"] == []
