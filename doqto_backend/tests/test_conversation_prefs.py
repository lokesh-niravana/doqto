"""Batch 3 — conversation preferences: pin (max 3), archive, mute (push
suppression for messages AND reactions, plus the user-level mute), mark
unread (cleared by reading), clear chat (seq cursor filters list / preview /
unread), delete chat (hidden until something new), badge count in every push
payload, unread-total endpoint, and the security negatives (outsider 404,
idempotency, self-only WS event, audit row with field names only).
"""
from __future__ import annotations

import asyncio
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy import select

import app.api.v1.conversations as conversations_module
from app.core.constants import MUTE_ALWAYS_UNTIL, PINNED_CONVERSATIONS_MAX
from app.core.enums import AuditAction, ConversationType, WsEventServer
from app.models import AuditLog, ConversationPref, Mute
from app.services import push_service
from app.services.push_service import PushResult, PushService, fcm_message
from tests import helpers

CONVS = "/api/v1/conversations"


class RecordingSender:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    async def send(self, *, token, title, body, data, collapse_key, badge=None, **_):
        self.calls.append(
            {"token": token, "body": body, "data": data, "collapse_key": collapse_key, "badge": badge}
        )
        return PushResult.SENT


@pytest.fixture
def fake_sender():
    fake = RecordingSender()
    push_service.sender_factory = lambda: fake
    yield fake
    push_service.sender_factory = push_service._default_sender


@pytest.fixture
def ws_events(monkeypatch):
    sent: list[tuple[set[uuid.UUID], WsEventServer, dict]] = []

    async def publish_to_users(user_ids, event, data):
        sent.append((set(user_ids), event, data))

    async def publish_org(org_id, event, data):
        pass

    monkeypatch.setattr(
        conversations_module,
        "ws_manager",
        SimpleNamespace(publish_to_users=publish_to_users, publish_org=publish_org),
    )
    return sent


async def _drain() -> None:
    pending = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)


async def _patch(client, conv_id, headers, **fields):
    return await client.patch(f"{CONVS}/{conv_id}/prefs", json=fields, headers=headers)


async def _send(client, conv_id, headers, text="hello"):
    r = await client.post(f"{CONVS}/{conv_id}/messages", json={"content": text}, headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def _list(client, headers):
    r = await client.get(CONVS, headers=headers)
    assert r.status_code == 200, r.text
    return {c["id"]: c for c in r.json()}


async def _register(db, user_id) -> str:
    token = f"tok-{uuid.uuid4().hex}"
    await PushService.register_token(user_id=user_id, token=token, platform="ios", db=db)
    await db.commit()
    return token


# --------------------------------------------------------------------------- #
# CRUD + inline prefs
# --------------------------------------------------------------------------- #
async def test_defaults_inline_and_partial_patch(client, chat):
    convs = await _list(client, chat.alice_headers)
    prefs = convs[str(chat.conv.id)]["prefs"]
    assert prefs == {
        "pinned_at": None,
        "archived": False,
        "muted_until": None,
        "custom_tone": None,
        "custom_vibrate": None,
        "theme": None,
        "wallpaper": None,
        "marked_unread": False,
        "cleared_before_seq": None,
        "hidden_until_seq": None,
    }
    r = await _patch(client, chat.conv.id, chat.alice_headers, pinned=True, theme="sage")
    assert r.status_code == 200, r.text
    assert r.json()["pinned_at"] is not None and r.json()["theme"] == "sage"
    # A later partial patch leaves untouched fields alone.
    r = await _patch(client, chat.conv.id, chat.alice_headers, archived=True)
    body = r.json()
    assert body["archived"] is True and body["pinned_at"] is not None and body["theme"] == "sage"
    # Inline on the list, and private: Bob still sees defaults.
    assert (await _list(client, chat.alice_headers))[str(chat.conv.id)]["prefs"]["archived"] is True
    assert (await _list(client, chat.bob_headers))[str(chat.conv.id)]["prefs"]["archived"] is False
    # Unpin / unarchive.
    r = await _patch(client, chat.conv.id, chat.alice_headers, pinned=False, archived=False)
    assert r.json()["pinned_at"] is None and r.json()["archived"] is False


async def test_outsider_and_unknown_get_404(client, chat, db):
    outsider = await helpers.create_user(db, full_name="Dr Out")
    h = await helpers.auth_headers(outsider.id)
    r = await _patch(client, chat.conv.id, h, pinned=True)
    assert r.status_code == 404 and r.json()["detail"] == "conversation_not_found"
    r = await _patch(client, uuid.uuid4(), chat.alice_headers, pinned=True)
    assert r.status_code == 404 and r.json()["detail"] == "conversation_not_found"
    assert (await db.scalar(select(ConversationPref))) is None


async def test_pin_limit_409(client, chat, db):
    others = []
    for i in range(PINNED_CONVERSATIONS_MAX):
        u = await helpers.create_user(db, full_name=f"Dr {i}")
        await helpers.add_org_member(db, chat.org, u)
        others.append(await helpers.create_conversation(db, chat.org, [chat.alice, u]))
    for c in others:
        assert (await _patch(client, c.id, chat.alice_headers, pinned=True)).status_code == 200
    r = await _patch(client, chat.conv.id, chat.alice_headers, pinned=True)
    assert r.status_code == 409 and r.json()["detail"] == "pin_limit"
    # Re-pinning an already pinned chat is not a 4th pin.
    assert (await _patch(client, others[0].id, chat.alice_headers, pinned=True)).status_code == 200
    # Unpin one → room again.
    await _patch(client, others[0].id, chat.alice_headers, pinned=False)
    assert (await _patch(client, chat.conv.id, chat.alice_headers, pinned=True)).status_code == 200


async def test_idempotent_patch_emits_once_to_self_only_and_audits(client, chat, db, ws_events):
    r = await _patch(client, chat.conv.id, chat.alice_headers, pinned=True)
    assert r.status_code == 200
    r = await _patch(client, chat.conv.id, chat.alice_headers, pinned=True)
    assert r.status_code == 200
    prefs_events = [e for e in ws_events if e[1] == WsEventServer.CONVERSATION_PREFS_UPDATED]
    assert len(prefs_events) == 1
    recipients, _, data = prefs_events[0]
    assert recipients == {chat.alice.id}  # never the other member
    assert data["conversation_id"] == str(chat.conv.id)
    assert data["prefs"]["pinned_at"] is not None
    rows = (
        await db.scalars(
            select(AuditLog).where(AuditLog.action == AuditAction.CONVERSATION_PREFS_UPDATED.value)
        )
    ).all()
    assert len(rows) == 1
    assert rows[0].user_id == chat.alice.id
    assert rows[0].meta["fields"] == ["pinned"]


async def test_expired_mute_reads_as_unmuted(client, chat):
    past = (datetime.now(tz=timezone.utc) - timedelta(hours=1)).isoformat()
    r = await _patch(client, chat.conv.id, chat.alice_headers, muted_until=past)
    assert r.status_code == 200 and r.json()["muted_until"] is None


# --------------------------------------------------------------------------- #
# Mute → no push (messages, reactions, user-level mute)
# --------------------------------------------------------------------------- #
async def test_muted_conversation_suppresses_message_push(client, chat, db, fake_sender):
    await _register(db, chat.bob.id)
    future = (datetime.now(tz=timezone.utc) + timedelta(hours=8)).isoformat()
    assert (await _patch(client, chat.conv.id, chat.bob_headers, muted_until=future)).status_code == 200
    await PushService._dispatch(
        conversation_id=chat.conv.id, recipient_ids=[chat.alice.id, chat.bob.id], sender_id=chat.alice.id
    )
    assert fake_sender.calls == []
    # Unmute → pushed again.
    await _patch(client, chat.conv.id, chat.bob_headers, muted_until=None)
    await PushService._dispatch(
        conversation_id=chat.conv.id, recipient_ids=[chat.alice.id, chat.bob.id], sender_id=chat.alice.id
    )
    assert len(fake_sender.calls) == 1


async def test_mute_always_and_user_level_mute_suppress_pushes(client, chat, db, fake_sender):
    await _register(db, chat.bob.id)
    assert (
        await _patch(client, chat.conv.id, chat.bob_headers, muted_until=MUTE_ALWAYS_UNTIL.isoformat())
    ).status_code == 200
    await PushService._dispatch(
        conversation_id=chat.conv.id, recipient_ids=[chat.alice.id, chat.bob.id], sender_id=chat.alice.id
    )
    assert fake_sender.calls == []
    await _patch(client, chat.conv.id, chat.bob_headers, muted_until=None)
    # Bob mutes Alice as a person (M1 mutes table) → still silent.
    db.add(Mute(user_id=chat.bob.id, muted_user_id=chat.alice.id))
    await db.commit()
    await PushService._dispatch(
        conversation_id=chat.conv.id, recipient_ids=[chat.alice.id, chat.bob.id], sender_id=chat.alice.id
    )
    assert fake_sender.calls == []


async def test_muted_conversation_suppresses_reaction_push(client, chat, db, fake_sender):
    await _register(db, chat.alice.id)
    msg = await _send(client, chat.conv.id, chat.alice_headers, "react to me")
    future = (datetime.now(tz=timezone.utc) + timedelta(days=7)).isoformat()
    await _patch(client, chat.conv.id, chat.alice_headers, muted_until=future)
    await PushService._dispatch_reaction(
        conversation_id=chat.conv.id,
        author_id=chat.alice.id,
        actor_id=chat.bob.id,
        emoji="👍",
    )
    assert fake_sender.calls == []
    await _patch(client, chat.conv.id, chat.alice_headers, muted_until=None)
    await PushService._dispatch_reaction(
        conversation_id=chat.conv.id, author_id=chat.alice.id, actor_id=chat.bob.id, emoji="👍"
    )
    assert len(fake_sender.calls) == 1
    assert fake_sender.calls[0]["data"]["type"] == "reaction"
    assert msg["id"]  # sanity


# --------------------------------------------------------------------------- #
# Badge count in payloads
# --------------------------------------------------------------------------- #
def test_fcm_message_carries_badge_only_when_given():
    base = dict(token="t", title="Doqto", body="b", data={}, collapse_key="c", now=0)
    assert fcm_message(**base)["apns"]["payload"]["aps"] == {"sound": "default"}
    assert fcm_message(**base, badge=4)["apns"]["payload"]["aps"]["badge"] == 4
    assert fcm_message(**base, badge=0)["apns"]["payload"]["aps"]["badge"] == 0


async def test_badge_is_total_unread_minus_muted_and_archived(client, chat, db, fake_sender):
    """Bob has three chats: this one (2 unread), an archived one (1 unread)
    and a muted one (1 unread). Only this chat counts → badge 2."""
    carol = await helpers.create_user(db, full_name="Dr Carol")
    dave = await helpers.create_user(db, full_name="Dr Dave")
    for u in (carol, dave):
        await helpers.add_org_member(db, chat.org, u)
    archived = await helpers.create_conversation(db, chat.org, [carol, chat.bob])
    muted = await helpers.create_conversation(db, chat.org, [dave, chat.bob])
    carol_h = await helpers.auth_headers(carol.id)
    dave_h = await helpers.auth_headers(dave.id)
    await _send(client, archived.id, carol_h)
    await _send(client, muted.id, dave_h)
    await _send(client, chat.conv.id, chat.alice_headers, "one")
    await _send(client, chat.conv.id, chat.alice_headers, "two")
    await _drain()
    await _patch(client, archived.id, chat.bob_headers, archived=True)
    await _patch(
        client, muted.id, chat.bob_headers, muted_until=MUTE_ALWAYS_UNTIL.isoformat()
    )
    r = await client.get(f"{CONVS}/unread-total", headers=chat.bob_headers)
    assert r.status_code == 200 and r.json() == {"total": 2}
    await _register(db, chat.bob.id)
    await PushService._dispatch(
        conversation_id=chat.conv.id, recipient_ids=[chat.alice.id, chat.bob.id], sender_id=chat.alice.id
    )
    assert len(fake_sender.calls) == 1
    assert fake_sender.calls[0]["badge"] == 2
    assert fake_sender.calls[0]["body"] == "Dr Alice sent you 2 new messages"
    # Invitation-style pushes carry it too.
    await PushService._dispatch_simple(
        recipient_id=chat.bob.id,
        title="Doqto",
        body="x wants to connect",
        data={"type": "invitation_received"},
        collapse_key="invite:1",
    )
    assert fake_sender.calls[-1]["badge"] == 2


async def test_marked_unread_adds_one_to_badge_and_reading_clears_it(client, chat, ws_events):
    r = await client.get(f"{CONVS}/unread-total", headers=chat.bob_headers)
    assert r.json()["total"] == 0
    await _patch(client, chat.conv.id, chat.bob_headers, marked_unread=True)
    r = await client.get(f"{CONVS}/unread-total", headers=chat.bob_headers)
    assert r.json()["total"] == 1
    assert (await _list(client, chat.bob_headers))[str(chat.conv.id)]["prefs"]["marked_unread"] is True
    ws_events.clear()
    r = await client.post(f"{CONVS}/{chat.conv.id}/read", headers=chat.bob_headers)
    assert r.status_code == 200
    assert (await _list(client, chat.bob_headers))[str(chat.conv.id)]["prefs"]["marked_unread"] is False
    prefs_events = [e for e in ws_events if e[1] == WsEventServer.CONVERSATION_PREFS_UPDATED]
    assert len(prefs_events) == 1 and prefs_events[0][0] == {chat.bob.id}
    assert prefs_events[0][2]["prefs"]["marked_unread"] is False


# --------------------------------------------------------------------------- #
# Clear chat / delete chat
# --------------------------------------------------------------------------- #
async def test_clear_chat_hides_history_for_me_only(client, chat):
    await _send(client, chat.conv.id, chat.alice_headers, "first")
    await _send(client, chat.conv.id, chat.alice_headers, "second")
    await _drain()
    before = await _list(client, chat.bob_headers)
    assert before[str(chat.conv.id)]["unread_count"] == 2
    r = await _patch(client, chat.conv.id, chat.bob_headers, clear_chat=True)
    assert r.status_code == 200 and r.json()["cleared_before_seq"] == 2
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    assert r.json() == []
    # Alice keeps everything.
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.alice_headers)
    assert len(r.json()) == 2
    after = await _list(client, chat.bob_headers)
    assert after[str(chat.conv.id)]["unread_count"] == 0
    assert after[str(chat.conv.id)]["last_message_preview"] is None
    # Catch-up paths respect the cursor too.
    r = await client.get(
        f"{CONVS}/{chat.conv.id}/messages", params={"after_seq": 0}, headers=chat.bob_headers
    )
    assert r.json() == []
    # New messages after the clear show up.
    await _send(client, chat.conv.id, chat.alice_headers, "third")
    await _drain()
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    assert [m["content"] for m in r.json()] == ["third"]
    assert (await _list(client, chat.bob_headers))[str(chat.conv.id)]["unread_count"] == 1
    # Clearing again at the same head is a no-op (idempotent).
    r = await _patch(client, chat.conv.id, chat.bob_headers, clear_chat=True)
    assert r.status_code == 200 and r.json()["cleared_before_seq"] == 3


async def test_delete_direct_chat_hides_until_new_message(client, chat):
    await _send(client, chat.conv.id, chat.alice_headers, "hi")
    await _drain()
    await _patch(client, chat.conv.id, chat.bob_headers, pinned=True)
    r = await _patch(client, chat.conv.id, chat.bob_headers, delete_chat=True)
    assert r.status_code == 200
    body = r.json()
    assert body["hidden_until_seq"] == 1 and body["cleared_before_seq"] == 1
    assert body["pinned_at"] is None
    assert str(chat.conv.id) not in await _list(client, chat.bob_headers)
    assert str(chat.conv.id) in await _list(client, chat.alice_headers)  # Alice unaffected
    assert (await client.get(f"{CONVS}/unread-total", headers=chat.bob_headers)).json()["total"] == 0
    # Alice writes again → it is back, showing only the new message.
    await _send(client, chat.conv.id, chat.alice_headers, "again")
    await _drain()
    convs = await _list(client, chat.bob_headers)
    assert convs[str(chat.conv.id)]["unread_count"] == 1
    assert convs[str(chat.conv.id)]["last_message_preview"] == "again"
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    assert [m["content"] for m in r.json()] == ["again"]


async def test_delete_group_chat_rejected_use_leave(client, chat, db):
    group = await helpers.create_conversation(
        db, chat.org, [chat.alice, chat.bob], conv_type=ConversationType.GROUP, name="Rounds"
    )
    r = await _patch(client, group.id, chat.alice_headers, delete_chat=True)
    assert r.status_code == 400 and r.json()["detail"] == "delete_group_use_leave"
    # Clear chat still works on groups.
    r = await _patch(client, group.id, chat.alice_headers, clear_chat=True)
    assert r.status_code == 200


async def test_prefs_rate_limited(client, chat, monkeypatch):
    monkeypatch.setattr(conversations_module, "RATE_LIMIT_PREFS_WRITES_PER_MINUTE", 2)
    for _ in range(2):
        assert (await _patch(client, chat.conv.id, chat.alice_headers, theme="x")).status_code == 200
    r = await _patch(client, chat.conv.id, chat.alice_headers, theme="x")
    assert r.status_code == 429
