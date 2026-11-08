"""Batch 4 message features: reply/quote, mentions (+ PHI-free push), forward
(copies, depth cap, org policy, destination gates), stars (private, purged
with the message), pins (roles, durations, auto-unpin), longer edit/delete
windows, admin delete with its system line, and jump-to-date paging."""
from __future__ import annotations

import asyncio
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import func, select, update

from app.api.ws_manager import ws_manager
from app.core.constants import (
    ADMIN_REMOVED_MESSAGE_TEXT,
    FORWARD_MAX_DEPTH,
    MESSAGE_DELETE_WINDOW_SEC,
    MESSAGE_EDIT_WINDOW_SEC,
    ORG_POLICY_ALLOW_FORWARD_OUTSIDE_ORG,
)
from app.core.enums import (
    AuditAction,
    ConversationType,
    GroupMemberState,
    GroupRole,
    OrgRole,
)
from app.models import (
    AuditLog,
    Block,
    Conversation,
    ConversationMember,
    Group,
    GroupMember,
    Message,
    MessageStar,
)
from app.services import push_service
from app.services.file_service import FileService
from app.services.message_service import MessageService
from app.services.push_service import PushResult, PushService
from tests import helpers

CONVS = "/api/v1/conversations"
MSGS = "/api/v1/messages"


# --------------------------------------------------------------------------- #
# fixtures / helpers
# --------------------------------------------------------------------------- #
class RecordingSender:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    async def send(self, *, token, title, body, data, collapse_key, badge=None, **_):
        self.calls.append(
            {"token": token, "title": title, "body": body, "data": data, "collapse_key": collapse_key, "badge": badge}
        )
        return PushResult.SENT


@pytest.fixture(autouse=True)
async def _drain_bg_tasks():
    yield
    pending = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)


async def _drain() -> None:
    pending = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)


@pytest.fixture
def fake_sender():
    fake = RecordingSender()
    push_service.sender_factory = lambda: fake
    yield fake
    push_service.sender_factory = push_service._default_sender


@pytest.fixture
def ws_events(monkeypatch):
    events: list[tuple[str, list, dict]] = []

    async def fake_publish(user_ids, event, data):
        events.append((str(event), list(user_ids), data))

    monkeypatch.setattr(ws_manager, "publish_to_users", fake_publish)
    return events


def _of(ws_events, name):
    return [(uids, d) for ev, uids, d in ws_events if ev == name]


async def _send(client, conv_id, headers, content="hello", **extra):
    resp = await client.post(
        f"{CONVS}/{conv_id}/messages",
        json={"type": "text", "content": content, **extra},
        headers=headers,
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


async def _page(client, conv_id, headers, **params):
    resp = await client.get(f"{CONVS}/{conv_id}/messages", headers=headers, params=params)
    assert resp.status_code == 200, resp.text
    return resp.json()


async def _backdate(db, message_id: str, seconds: int) -> None:
    await db.execute(
        update(Message)
        .where(Message.id == uuid.UUID(message_id))
        .values(created_at=datetime.now(tz=timezone.utc) - timedelta(seconds=seconds))
    )
    await db.commit()


async def _group(client, db, owner, members, **overrides):
    """A network group via the API (owner) + members added directly."""
    body = {"name": "Cardiology Rounds", "post_policy": "all_members", "member_dm_policy": "request"}
    body.update(overrides)
    r = await client.post("/api/v1/groups", json=body, headers=await helpers.auth_headers(owner.id))
    assert r.status_code == 201, r.text
    group = await db.scalar(select(Group).where(Group.id == uuid.UUID(r.json()["id"])))
    for u in members:
        db.add(
            GroupMember(
                group_id=group.id, user_id=u.id, role=GroupRole.MEMBER, state=GroupMemberState.ACTIVE
            )
        )
        db.add(ConversationMember(conversation_id=group.conversation_id, user_id=u.id))
    await db.commit()
    return group


# --------------------------------------------------------------------------- #
# A. Reply / quote
# --------------------------------------------------------------------------- #
async def test_reply_carries_live_quote_and_tracks_target_state(client, chat, db, ws_events):
    original = await _send(client, chat.conv.id, chat.alice_headers, "Can you cover Tuesday?")
    reply = await _send(
        client, chat.conv.id, chat.bob_headers, "Yes", reply_to_id=original["id"]
    )
    assert reply["reply_to_id"] == original["id"]
    assert reply["reply_to"] == {
        "id": original["id"],
        "sender_id": str(chat.alice.id),
        "type": "text",
        "preview": "Can you cover Tuesday?",
    }
    # The quote travels in the fan-out too.
    (_, payload), = [e for e in _of(ws_events, "new_message") if e[1]["id"] == reply["id"]]
    assert payload["reply_to"]["preview"] == "Can you cover Tuesday?"

    # Target edited → quote follows the current body.
    r = await client.patch(
        f"{MSGS}/{original['id']}", json={"content": "Can you cover Wednesday?"},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200
    page = await _page(client, chat.conv.id, chat.bob_headers)
    quoted = next(m for m in page if m["id"] == reply["id"])
    assert quoted["reply_to"]["preview"] == "Can you cover Wednesday?"

    # Target deleted for everyone → "Message deleted".
    r = await client.delete(f"{MSGS}/{original['id']}", headers=chat.alice_headers)
    assert r.status_code == 200
    page = await _page(client, chat.conv.id, chat.bob_headers)
    quoted = next(m for m in page if m["id"] == reply["id"])
    assert quoted["reply_to"]["preview"] == "Message deleted"

    # Target expired → the quote is gone (null), the reply itself stays.
    await db.execute(
        update(Message)
        .where(Message.id == uuid.UUID(original["id"]))
        .values(expires_at=datetime.now(tz=timezone.utc) - timedelta(seconds=1))
    )
    await db.commit()
    page = await _page(client, chat.conv.id, chat.bob_headers)
    quoted = next(m for m in page if m["id"] == reply["id"])
    assert quoted["reply_to"] is None and quoted["reply_to_id"] == original["id"]


async def test_reply_target_must_be_live_and_in_same_conversation(client, chat, db):
    other = await helpers.create_user(db, full_name="Dr Other")
    await helpers.add_org_member(db, chat.org, other)
    other_conv = await helpers.create_conversation(db, chat.org, [chat.alice, other])
    elsewhere = await _send(client, other_conv.id, chat.alice_headers, "elsewhere")

    r = await client.post(
        f"{CONVS}/{chat.conv.id}/messages",
        json={"content": "x", "reply_to_id": elsewhere["id"]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 422 and r.json()["detail"] == "reply_target_invalid"
    r = await client.post(
        f"{CONVS}/{chat.conv.id}/messages",
        json={"content": "x", "reply_to_id": str(uuid.uuid4())},
        headers=chat.alice_headers,
    )
    assert r.status_code == 422
    # A tombstone cannot be quoted either.
    gone = await _send(client, chat.conv.id, chat.alice_headers, "gone")
    await client.delete(f"{MSGS}/{gone['id']}", headers=chat.alice_headers)
    r = await client.post(
        f"{CONVS}/{chat.conv.id}/messages",
        json={"content": "x", "reply_to_id": gone["id"]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 422


# --------------------------------------------------------------------------- #
# H. Mentions
# --------------------------------------------------------------------------- #
def test_parse_mentions_dedupes_and_ignores_junk():
    a, b = uuid.uuid4(), uuid.uuid4()
    text = f"@[{a}] hi @[{b}] and again @[{a}] but not @[nope] or @someone"
    assert MessageService.parse_mentions(text) == [a, b]
    assert MessageService.parse_mentions("") == []


async def test_mentions_validated_stored_and_pushed_without_content(
    client, db, fake_sender, ws_events
):
    owner = await helpers.create_user(db, full_name="Dr Owner")
    carol = await helpers.create_user(db, full_name="Dr Carol")
    dave = await helpers.create_user(db, full_name="Dr Dave")
    group = await _group(client, db, owner, [carol, dave])
    conv_id = group.conversation_id
    carol_token = f"tok-{uuid.uuid4().hex}"
    dave_token = f"tok-{uuid.uuid4().hex}"
    await PushService.register_token(user_id=carol.id, token=carol_token, platform="ios", db=db)
    await PushService.register_token(user_id=dave.id, token=dave_token, platform="ios", db=db)
    await db.commit()

    secret = "patient in bed 4 is coding"
    msg = await _send(
        client, conv_id, await helpers.auth_headers(owner.id), f"@[{carol.id}] {secret}"
    )
    assert msg["mentions"] == [str(carol.id)]
    await _drain()

    by_token = {c["token"]: c for c in fake_sender.calls}
    # Carol gets the mention push (names only), Dave the plain new-message one.
    assert by_token[carol_token]["body"] == "Dr Owner mentioned you in Cardiology Rounds"
    assert by_token[carol_token]["data"] == {"type": "mention", "conversation_id": str(conv_id)}
    assert by_token[dave_token]["data"]["type"] == "new_message"
    # Exactly one push per person — the mention REPLACES the generic banner.
    assert [c["token"] for c in fake_sender.calls].count(carol_token) == 1
    for c in fake_sender.calls:
        assert secret not in c["body"] and secret not in str(c["data"])

    # A non-member cannot be mentioned.
    outsider = await helpers.create_user(db, full_name="Dr Out")
    r = await client.post(
        f"{CONVS}/{conv_id}/messages",
        json={"content": f"@[{outsider.id}] hey"},
        headers=await helpers.auth_headers(owner.id),
    )
    assert r.status_code == 422 and r.json()["detail"] == "mention_not_member"


# --------------------------------------------------------------------------- #
# B. Forward
# --------------------------------------------------------------------------- #
async def test_forward_text_creates_independent_copies_with_depth(client, chat, db, ws_events):
    carol = await helpers.create_user(db, full_name="Dr Carol")
    await helpers.add_org_member(db, chat.org, carol)
    dm_ac = await helpers.create_conversation(db, chat.org, [chat.alice, carol])
    group = await helpers.create_conversation(
        db, chat.org, [chat.alice, chat.bob, carol], conv_type=ConversationType.GROUP, name="Team"
    )
    src = await _send(client, chat.conv.id, chat.bob_headers, "lab results attached")

    r = await client.post(
        f"{MSGS}/{src['id']}/forward",
        json={"conversation_ids": [str(dm_ac.id), str(group.id), str(dm_ac.id)]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200, r.text
    copies = r.json()
    # Duplicated destination collapsed; one copy per conversation.
    assert {c["conversation_id"] for c in copies} == {str(dm_ac.id), str(group.id)}
    for c in copies:
        assert c["forwarded"] is True and c["forward_depth"] == 1
        assert c["content"] == "lab results attached"
        assert c["sender_id"] == str(chat.alice.id)  # the forwarder is the sender
        assert c["id"] != src["id"] and c["reply_to"] is None
    # Each destination got its own new_message fan-out.
    fanned = {d["conversation_id"] for _, d in _of(ws_events, "new_message")}
    assert {str(dm_ac.id), str(group.id)} <= fanned
    # Source untouched.
    page = await _page(client, chat.conv.id, chat.bob_headers)
    assert next(m for m in page if m["id"] == src["id"])["forwarded"] is False
    # Audit: one MESSAGE_FORWARDED with source + destinations.
    row = await db.scalar(
        select(AuditLog).where(AuditLog.action == AuditAction.MESSAGE_FORWARDED.value)
    )
    assert row.meta["source_id"] == src["id"]
    assert set(row.meta["destinations"]) == {str(dm_ac.id), str(group.id)}

    # Forwarding a copy bumps depth; at the cap it is refused.
    copy = next(c for c in copies if c["conversation_id"] == str(dm_ac.id))
    await db.execute(
        update(Message)
        .where(Message.id == uuid.UUID(copy["id"]))
        .values(forward_depth=FORWARD_MAX_DEPTH)
    )
    await db.commit()
    r = await client.post(
        f"{MSGS}/{copy['id']}/forward",
        json={"conversation_ids": [str(group.id)]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 422 and r.json()["detail"] == "forward_limit"


async def test_forward_copies_media_object_instead_of_sharing_key(client, chat, db, monkeypatch):
    carol = await helpers.create_user(db, full_name="Dr Carol")
    await helpers.add_org_member(db, chat.org, carol)
    dest = await helpers.create_conversation(db, chat.org, [chat.alice, carol])
    # A stored image message (bypass the upload path: no S3 in tests).
    img = Message(
        conversation_id=chat.conv.id,
        sender_id=chat.bob.id,
        type="image",
        seq=await MessageService.next_seq(conversation_id=chat.conv.id, db=db),
        s3_key=f"files/{chat.org.id}/{uuid.uuid4()}/scan.png",
        file_name="scan.png",
        file_size_bytes=1234,
    )
    db.add(img)
    await db.commit()
    copied: list[tuple[str, str]] = []

    async def fake_copy(*, src_key, dst_key):
        copied.append((src_key, dst_key))

    monkeypatch.setattr(FileService, "copy_object", fake_copy)
    r = await client.post(
        f"{MSGS}/{img.id}/forward",
        json={"conversation_ids": [str(dest.id)]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200, r.text
    (copy,) = r.json()
    assert copy["type"] == "image" and copy["file_name"] == "scan.png"
    assert copy["s3_key"] != img.s3_key and copy["id"] in copy["s3_key"]
    assert copied == [(img.s3_key, copy["s3_key"])]


async def test_forward_gates_outsider_blocked_and_limits(client, chat, db):
    outsider = await helpers.create_user(db, full_name="Dr Outsider")
    out_h = await helpers.auth_headers(outsider.id)
    src = await _send(client, chat.conv.id, chat.alice_headers, "x")

    # Not a member of the source → same 404 as a missing id.
    r = await client.post(
        f"{MSGS}/{src['id']}/forward", json={"conversation_ids": [str(chat.conv.id)]}, headers=out_h
    )
    assert r.status_code == 404 and r.json()["detail"] == "message_not_found"
    # Destination I'm not in → 404 too (no oracle).
    other = await helpers.create_user(db, full_name="Dr Other")
    await helpers.add_org_member(db, chat.org, other)
    not_mine = await helpers.create_conversation(db, chat.org, [chat.bob, other])
    r = await client.post(
        f"{MSGS}/{src['id']}/forward",
        json={"conversation_ids": [str(not_mine.id)]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 404 and r.json()["detail"] == "conversation_not_found"
    # Too many destinations → 422 from validation.
    r = await client.post(
        f"{MSGS}/{src['id']}/forward",
        json={"conversation_ids": [str(uuid.uuid4()) for _ in range(6)]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 422
    # A system message cannot be forwarded.
    conv = await db.get(Conversation, chat.conv.id)
    sys_msg = await MessageService.send_system(conv=conv, sender_id=chat.alice.id, content="s", db=db)
    await db.commit()
    r = await client.post(
        f"{MSGS}/{sys_msg.id}/forward",
        json={"conversation_ids": [str(chat.conv.id)]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 409 and r.json()["detail"] == "message_not_forwardable"

    # Blocked: Bob blocked Alice → Alice forwarding into their DM is refused
    # with the generic reason (a block is never observable).
    db.add(Block(blocker_id=chat.bob.id, blocked_id=chat.alice.id))
    await db.commit()
    r = await client.post(
        f"{MSGS}/{src['id']}/forward",
        json={"conversation_ids": [str(chat.conv.id)]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 403 and r.json()["detail"] == "not_reachable"


async def test_forward_respects_org_policy_allow_forward_outside_org(client, chat, db):
    """Source in an org group chat; the org forbids forwarding out → copies may
    stay inside the org (another org conversation) but not leave it."""
    carol = await helpers.create_user(db, full_name="Dr Carol")
    await helpers.add_org_member(db, chat.org, carol)
    org_group = await helpers.create_conversation(
        db, chat.org, [chat.alice, chat.bob, carol], conv_type=ConversationType.GROUP, name="Ward"
    )
    org_group_2 = await helpers.create_conversation(
        db, chat.org, [chat.alice, carol], conv_type=ConversationType.GROUP, name="Ward 2"
    )
    # A network DM (org_id NULL) is "outside the org".
    stranger = await helpers.create_user(db, full_name="Dr Stranger")
    await helpers.connect_users(db, chat.alice, stranger)
    r = await client.post(
        CONVS, json={"type": "direct", "member_ids": [str(stranger.id)]}, headers=chat.alice_headers
    )
    assert r.status_code == 200, r.text
    network_dm = r.json()["id"]
    src = await _send(client, org_group.id, chat.bob_headers, "internal protocol")

    # Default policy (true): allowed everywhere.
    r = await client.post(
        f"{MSGS}/{src['id']}/forward",
        json={"conversation_ids": [network_dm]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200, r.text

    # Admin flips the policy off.
    await helpers.add_org_member(db, chat.org, await helpers.create_user(db, full_name="Dr Admin"), role=OrgRole.ADMIN)
    admin = await db.scalar(select(helpers.User).where(helpers.User.full_name == "Dr Admin"))
    r = await client.patch(
        f"/api/v1/orgs/{chat.org.id}/settings/networking",
        json={ORG_POLICY_ALLOW_FORWARD_OUTSIDE_ORG: False},
        headers=await helpers.auth_headers(admin.id),
    )
    assert r.status_code == 200, r.text
    assert r.json()["policies"][ORG_POLICY_ALLOW_FORWARD_OUTSIDE_ORG] is False
    # Visible to members through /orgs/mine.
    mine = await client.get("/api/v1/orgs/mine", headers=chat.alice_headers)
    assert mine.json()[0]["policies"] == {
        ORG_POLICY_ALLOW_FORWARD_OUTSIDE_ORG: False,
        "allow_copy": True,
        "allow_media_export": False,  # batch 5 default
        "block_screenshots": False,  # batch 6 default
    }

    src2 = await _send(client, org_group.id, chat.bob_headers, "internal protocol v2")
    r = await client.post(
        f"{MSGS}/{src2['id']}/forward",
        json={"conversation_ids": [str(org_group_2.id), network_dm]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 403 and r.json()["detail"] == "forward_blocked_by_org"
    # All-or-nothing: nothing landed in the in-org destination either.
    assert await _page(client, org_group_2.id, chat.alice_headers) == []
    r = await client.post(
        f"{MSGS}/{src2['id']}/forward",
        json={"conversation_ids": [str(org_group_2.id)]},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200


# --------------------------------------------------------------------------- #
# C. Stars
# --------------------------------------------------------------------------- #
async def test_star_is_private_idempotent_and_listed_across_chats(client, chat, db, ws_events):
    carol = await helpers.create_user(db, full_name="Dr Carol")
    await helpers.add_org_member(db, chat.org, carol)
    dm_ac = await helpers.create_conversation(db, chat.org, [chat.alice, carol])
    m1 = await _send(client, chat.conv.id, chat.bob_headers, "first")
    m2 = await _send(client, dm_ac.id, chat.alice_headers, "second")

    r = await client.put(f"{MSGS}/{m1['id']}/star", headers=chat.alice_headers)
    assert r.status_code == 200 and r.json()["starred"] is True
    r = await client.put(f"{MSGS}/{m2['id']}/star", headers=chat.alice_headers)
    assert r.status_code == 200
    # Idempotent: a second star is a no-op (no extra event).
    r = await client.put(f"{MSGS}/{m1['id']}/star", headers=chat.alice_headers)
    assert r.status_code == 200 and r.json()["starred"] is True
    starred_events = _of(ws_events, "message_starred")
    assert len(starred_events) == 2
    # Only Alice's own devices hear about it.
    assert all(uids == [chat.alice.id] for uids, _ in starred_events)
    assert starred_events[0][1] == {
        "conversation_id": str(chat.conv.id), "message_id": m1["id"], "starred": True
    }

    # Visible in MY thread page, invisible in Bob's.
    mine = await _page(client, chat.conv.id, chat.alice_headers)
    assert next(m for m in mine if m["id"] == m1["id"])["starred"] is True
    theirs = await _page(client, chat.conv.id, chat.bob_headers)
    assert next(m for m in theirs if m["id"] == m1["id"])["starred"] is False

    # Starred list: newest star first, across conversations, named.
    r = await client.get(f"{MSGS}/starred", headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    rows = r.json()["data"]
    assert [x["message"]["id"] for x in rows] == [m2["id"], m1["id"]]
    assert rows[0]["conversation_name"] == "Dr Carol" and rows[1]["conversation_name"] == "Dr Bob"
    assert rows[0]["message"]["starred"] is True
    # Paging.
    r = await client.get(f"{MSGS}/starred", params={"limit": 1}, headers=chat.alice_headers)
    body = r.json()
    assert len(body["data"]) == 1 and body["next_cursor"]
    r = await client.get(
        f"{MSGS}/starred", params={"limit": 1, "cursor": body["next_cursor"]}, headers=chat.alice_headers
    )
    assert [x["message"]["id"] for x in r.json()["data"]] == [m1["id"]] and r.json()["next_cursor"] is None
    # Reading starred bodies is audited.
    n = await db.scalar(
        select(func.count()).select_from(AuditLog).where(
            AuditLog.action == AuditAction.STARRED_MESSAGES_READ.value
        )
    )
    assert n == 3

    # Unstar; double unstar is a no-op.
    r = await client.delete(f"{MSGS}/{m1['id']}/star", headers=chat.alice_headers)
    assert r.status_code == 200 and r.json()["starred"] is False
    r = await client.delete(f"{MSGS}/{m1['id']}/star", headers=chat.alice_headers)
    assert r.status_code == 200
    assert len(_of(ws_events, "message_starred")) == 3
    assert (await client.get(f"{MSGS}/starred", headers=chat.alice_headers)).json()["data"][0][
        "message"
    ]["id"] == m2["id"]


async def test_star_security_and_purge(client, chat, db):
    outsider = await helpers.create_user(db, full_name="Dr Outsider")
    msg = await _send(client, chat.conv.id, chat.bob_headers, "keep this")
    r = await client.put(f"{MSGS}/{msg['id']}/star", headers=await helpers.auth_headers(outsider.id))
    assert r.status_code == 404 and r.json()["detail"] == "message_not_found"
    r = await client.put(f"{MSGS}/{uuid.uuid4()}/star", headers=chat.alice_headers)
    assert r.status_code == 404

    # Star, then the sender deletes for everyone → star gone, list empty.
    assert (await client.put(f"{MSGS}/{msg['id']}/star", headers=chat.alice_headers)).status_code == 200
    assert (await client.delete(f"{MSGS}/{msg['id']}", headers=chat.bob_headers)).status_code == 200
    assert await db.scalar(select(func.count()).select_from(MessageStar)) == 0
    assert (await client.get(f"{MSGS}/starred", headers=chat.alice_headers)).json()["data"] == []
    # Tombstones can't be starred.
    r = await client.put(f"{MSGS}/{msg['id']}/star", headers=chat.alice_headers)
    assert r.status_code == 409 and r.json()["detail"] == "message_deleted"

    # Expired message: the star does not extend retention — the purge job drops it.
    m2 = await _send(client, chat.conv.id, chat.bob_headers, "vanishing")
    assert (await client.put(f"{MSGS}/{m2['id']}/star", headers=chat.alice_headers)).status_code == 200
    await db.execute(
        update(Message)
        .where(Message.id == uuid.UUID(m2["id"]))
        .values(expires_at=datetime.now(tz=timezone.utc) - timedelta(seconds=1))
    )
    await db.commit()
    assert (await client.get(f"{MSGS}/starred", headers=chat.alice_headers)).json()["data"] == []
    assert await MessageService.purge_orphan_stars(db) == 1
    await db.commit()
    assert await db.scalar(select(func.count()).select_from(MessageStar)) == 0


# --------------------------------------------------------------------------- #
# D. Pin
# --------------------------------------------------------------------------- #
async def test_pin_direct_either_member_durations_and_unpin(client, chat, db, ws_events):
    msg = await _send(client, chat.conv.id, chat.alice_headers, "On call: Dr Bob")
    r = await client.put(
        f"{CONVS}/{chat.conv.id}/pin",
        json={"message_id": msg["id"], "duration_sec": 7 * 86400},
        headers=chat.bob_headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["pinned_message_id"] == msg["id"]
    until = datetime.fromisoformat(r.json()["pinned_until"])
    assert timedelta(days=6, hours=23) < until - datetime.now(tz=timezone.utc) <= timedelta(days=7)
    (uids, data), = _of(ws_events, "message_pinned")
    assert set(uids) == {chat.alice.id, chat.bob.id}
    assert data["message_id"] == msg["id"] and data["actor_id"] == str(chat.bob.id)
    assert data["pinned_until"] is not None

    # Chat list carries the pin.
    convs = (await client.get(CONVS, headers=chat.alice_headers)).json()
    assert next(c for c in convs if c["id"] == str(chat.conv.id))["pinned_message_id"] == msg["id"]

    # Bad duration / foreign message / outsider.
    r = await client.put(
        f"{CONVS}/{chat.conv.id}/pin", json={"message_id": msg["id"], "duration_sec": 60},
        headers=chat.alice_headers,
    )
    assert r.status_code == 422 and r.json()["detail"] == "invalid_pin_duration"
    carol = await helpers.create_user(db, full_name="Dr Carol")
    await helpers.add_org_member(db, chat.org, carol)
    other = await helpers.create_conversation(db, chat.org, [chat.alice, carol])
    elsewhere = await _send(client, other.id, chat.alice_headers, "elsewhere")
    r = await client.put(
        f"{CONVS}/{chat.conv.id}/pin", json={"message_id": elsewhere["id"]}, headers=chat.alice_headers
    )
    assert r.status_code == 404
    r = await client.put(
        f"{CONVS}/{chat.conv.id}/pin", json={"message_id": msg["id"]},
        headers=await helpers.auth_headers(carol.id),
    )
    assert r.status_code == 403

    # Unpin; second unpin is a silent no-op.
    r = await client.delete(f"{CONVS}/{chat.conv.id}/pin", headers=chat.alice_headers)
    assert r.status_code == 200 and r.json()["pinned_message_id"] is None
    (uids, data), = _of(ws_events, "message_unpinned")
    assert data["message_id"] == msg["id"] and data["pinned_until"] is None
    r = await client.delete(f"{CONVS}/{chat.conv.id}/pin", headers=chat.alice_headers)
    assert r.status_code == 200 and len(_of(ws_events, "message_unpinned")) == 1


async def test_pin_group_admin_only_and_auto_unpin(client, db, ws_events):
    owner = await helpers.create_user(db, full_name="Dr Owner")
    member = await helpers.create_user(db, full_name="Dr Member")
    group = await _group(client, db, owner, [member])
    conv_id = group.conversation_id
    owner_h, member_h = await helpers.auth_headers(owner.id), await helpers.auth_headers(member.id)
    msg = await _send(client, conv_id, member_h, "Rota for next week")

    r = await client.put(f"{CONVS}/{conv_id}/pin", json={"message_id": msg["id"]}, headers=member_h)
    assert r.status_code == 403 and r.json()["detail"] == "not_authorized"
    r = await client.put(f"{CONVS}/{conv_id}/pin", json={"message_id": msg["id"]}, headers=owner_h)
    assert r.status_code == 200, r.text
    assert r.json()["pinned_until"] is not None  # default: the longest option (30d)
    r = await client.delete(f"{CONVS}/{conv_id}/pin", headers=member_h)
    assert r.status_code == 403

    # Past pinned_until the pin reads as cleared even before the job runs…
    await db.execute(
        update(Conversation)
        .where(Conversation.id == conv_id)
        .values(pinned_until=datetime.now(tz=timezone.utc) - timedelta(seconds=1))
    )
    await db.commit()
    convs = (await client.get(CONVS, headers=member_h)).json()
    assert next(c for c in convs if c["id"] == str(conv_id))["pinned_message_id"] is None
    # …and the job clears it for real and reports what to announce.
    cleared = await MessageService.expire_pins(db)
    await db.commit()
    assert cleared == [(conv_id, uuid.UUID(msg["id"]))]
    conv = await db.get(Conversation, conv_id)
    assert conv.pinned_message_id is None and conv.pinned_by is None

    # Deleting the pinned message clears the pin.
    msg2 = await _send(client, conv_id, owner_h, "pin me then delete me")
    assert (
        await client.put(f"{CONVS}/{conv_id}/pin", json={"message_id": msg2["id"]}, headers=owner_h)
    ).status_code == 200
    assert (await client.delete(f"{MSGS}/{msg2['id']}", headers=owner_h)).status_code == 200
    await db.refresh(conv)
    assert conv.pinned_message_id is None


# --------------------------------------------------------------------------- #
# F/G. Windows + admin delete
# --------------------------------------------------------------------------- #
def test_windows_are_15_minutes_and_48_hours():
    assert MESSAGE_EDIT_WINDOW_SEC == 15 * 60
    assert MESSAGE_DELETE_WINDOW_SEC == 48 * 3600


async def test_edit_allowed_at_14_minutes_delete_allowed_at_47_hours(client, chat, db):
    msg = await _send(client, chat.conv.id, chat.alice_headers, "typo")
    await _backdate(db, msg["id"], 14 * 60)
    r = await client.patch(f"{MSGS}/{msg['id']}", json={"content": "fixed"}, headers=chat.alice_headers)
    assert r.status_code == 200 and r.json()["content"] == "fixed"
    await _backdate(db, msg["id"], 47 * 3600)
    r = await client.patch(f"{MSGS}/{msg['id']}", json={"content": "late"}, headers=chat.alice_headers)
    assert r.status_code == 409 and r.json()["detail"] == "edit_window_closed"
    r = await client.delete(f"{MSGS}/{msg['id']}", headers=chat.alice_headers)
    assert r.status_code == 200 and r.json()["deleted_at"] is not None


async def test_group_admin_deletes_members_message_with_system_line(client, db, ws_events):
    owner = await helpers.create_user(db, full_name="Dr Owner")
    member = await helpers.create_user(db, full_name="Dr Member")
    other = await helpers.create_user(db, full_name="Dr Other")
    group = await _group(client, db, owner, [member, other])
    conv_id = group.conversation_id
    owner_h = await helpers.auth_headers(owner.id)
    member_h = await helpers.auth_headers(member.id)
    other_h = await helpers.auth_headers(other.id)

    msg = await _send(client, conv_id, member_h, "inappropriate")
    # Another plain member cannot.
    r = await client.delete(f"{MSGS}/{msg['id']}", headers=other_h)
    assert r.status_code == 403 and r.json()["detail"] == "not_message_sender"
    # The admin can, at any age.
    await _backdate(db, msg["id"], MESSAGE_DELETE_WINDOW_SEC * 3)
    r = await client.delete(f"{MSGS}/{msg['id']}", headers=owner_h)
    assert r.status_code == 200, r.text
    assert r.json()["deleted_at"] is not None and r.json()["content"] is None

    page = await _page(client, conv_id, other_h)
    assert page[0]["type"] == "system" and page[0]["content"] == ADMIN_REMOVED_MESSAGE_TEXT
    assert page[1]["id"] == msg["id"] and page[1]["deleted_at"] is not None
    # Fan-out: the tombstone AND the system line.
    assert any(d["id"] == msg["id"] for _, d in _of(ws_events, "message_deleted"))
    assert any(d["content"] == ADMIN_REMOVED_MESSAGE_TEXT for _, d in _of(ws_events, "new_message"))
    # Audited as an admin action.
    row = await db.scalar(
        select(AuditLog).where(
            AuditLog.action == AuditAction.MESSAGE_DELETED.value, AuditLog.user_id == owner.id
        )
    )
    assert row.meta == {"by_admin": True, "sender_id": str(member.id)}

    # Direct chats have no moderator.
    org = await helpers.create_org(db)
    await helpers.add_org_member(db, org, owner, role=OrgRole.ADMIN)
    await helpers.add_org_member(db, org, member)
    dm = await helpers.create_conversation(db, org, [owner, member])
    theirs = await _send(client, dm.id, member_h, "mine")
    r = await client.delete(f"{MSGS}/{theirs['id']}", headers=owner_h)
    assert r.status_code == 403


async def test_legacy_org_group_chat_org_admin_can_delete(client, db):
    org = await helpers.create_org(db)
    admin = await helpers.create_user(db, full_name="Dr Admin")
    doc = await helpers.create_user(db, full_name="Dr Doc")
    await helpers.add_org_member(db, org, admin, role=OrgRole.ADMIN)
    await helpers.add_org_member(db, org, doc)
    conv = await helpers.create_conversation(
        db, org, [admin, doc], conv_type=ConversationType.GROUP, name="Legacy"
    )
    msg = await _send(client, conv.id, await helpers.auth_headers(doc.id), "x")
    r = await client.delete(f"{MSGS}/{msg['id']}", headers=await helpers.auth_headers(admin.id))
    assert r.status_code == 200


# --------------------------------------------------------------------------- #
# K. Jump to date
# --------------------------------------------------------------------------- #
async def test_before_date_pages_from_end_of_that_day(client, chat, db):
    old = await _send(client, chat.conv.id, chat.alice_headers, "old")
    new = await _send(client, chat.conv.id, chat.alice_headers, "new")
    await _backdate(db, old["id"], 5 * 86400)
    day = (datetime.now(tz=timezone.utc) - timedelta(days=5)).date().isoformat()
    page = await _page(client, chat.conv.id, chat.bob_headers, before_date=day)
    assert [m["id"] for m in page] == [old["id"]]
    page = await _page(client, chat.conv.id, chat.bob_headers)
    assert [m["id"] for m in page] == [new["id"], old["id"]]
    r = await client.get(
        f"{CONVS}/{chat.conv.id}/messages",
        params={"before_date": day, "before": datetime.now(tz=timezone.utc).isoformat()},
        headers=chat.bob_headers,
    )
    assert r.status_code == 400
