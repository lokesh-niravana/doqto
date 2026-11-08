"""Message reactions: one emoji per member per message, live fan-out,
changed_since catch-up, author-only PHI-free push."""
from __future__ import annotations

import asyncio
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import func, select, update

from app.api.ws_manager import ws_manager
from app.core.enums import ConversationType
from app.models import Block, Message, MessageReaction
from app.services import push_service
from app.services.message_service import MessageService
from app.services.push_service import PushResult, PushService
from tests import helpers


class RecordingSender:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    async def send(self, *, token, title, body, data, collapse_key, badge=None, **_):
        self.calls.append(
            {"token": token, "body": body, "data": data, "collapse_key": collapse_key}
        )
        return PushResult.SENT


@pytest.fixture(autouse=True)
async def _drain_bg_tasks():
    """Reaction pushes are fire-and-forget tasks with their own DB session;
    drain them before the loop closes (see test_m1_graph)."""
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


async def _send(client, chat, content="hello", headers=None):
    resp = await client.post(
        f"/api/v1/conversations/{chat.conv.id}/messages",
        json={"type": "text", "content": content},
        headers=headers or chat.alice_headers,
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _url(mid: str) -> str:
    return f"/api/v1/messages/{mid}/reaction"


def _reacted(ws_events):
    return [(uids, d) for ev, uids, d in ws_events if ev == "message_reacted"]


async def test_set_reaction_returns_summary_and_fans_out(client, chat, ws_events):
    msg = await _send(client, chat)
    resp = await client.put(_url(msg["id"]), json={"emoji": "👍"}, headers=chat.bob_headers)
    assert resp.status_code == 200, resp.text
    out = resp.json()
    assert out["reactions"] == [{"emoji": "👍", "count": 1, "user_ids": [str(chat.bob.id)]}]
    assert out["changed_at"] is not None

    reacted = _reacted(ws_events)
    assert len(reacted) == 1
    uids, data = reacted[0]
    # Every member, the actor included (their other devices).
    assert set(map(str, uids)) == {str(chat.alice.id), str(chat.bob.id)}
    assert data["message_id"] == msg["id"]
    assert data["actor_id"] == str(chat.bob.id)
    assert data["emoji"] == "👍"
    assert data["reactions"][0]["count"] == 1
    # Slim payload — no read/delivered that could clobber the receiver's ticks.
    assert "read" not in data and "content" not in data

    # The thread lists the reactions.
    resp = await client.get(
        f"/api/v1/conversations/{chat.conv.id}/messages", headers=chat.alice_headers
    )
    assert resp.json()[0]["reactions"][0]["emoji"] == "👍"


async def test_same_emoji_noop_and_replace(client, chat, db, ws_events):
    msg = await _send(client, chat)
    await client.put(_url(msg["id"]), json={"emoji": "👍"}, headers=chat.bob_headers)
    resp = await client.put(_url(msg["id"]), json={"emoji": "👍"}, headers=chat.bob_headers)
    assert resp.status_code == 200
    assert len(_reacted(ws_events)) == 1  # no-op: no second broadcast

    resp = await client.put(_url(msg["id"]), json={"emoji": "❤️"}, headers=chat.bob_headers)
    assert resp.json()["reactions"] == [
        {"emoji": "❤️", "count": 1, "user_ids": [str(chat.bob.id)]}
    ]
    assert len(_reacted(ws_events)) == 2
    count = await db.scalar(select(func.count()).select_from(MessageReaction))
    assert count == 1


async def test_remove_reaction_and_double_remove_noop(client, chat, ws_events):
    msg = await _send(client, chat)
    await client.put(_url(msg["id"]), json={"emoji": "😂"}, headers=chat.bob_headers)
    resp = await client.delete(_url(msg["id"]), headers=chat.bob_headers)
    assert resp.status_code == 200
    assert resp.json()["reactions"] == []
    reacted = _reacted(ws_events)
    assert len(reacted) == 2 and reacted[-1][1]["emoji"] is None

    resp = await client.delete(_url(msg["id"]), headers=chat.bob_headers)
    assert resp.status_code == 200
    assert len(_reacted(ws_events)) == 2


async def test_group_ordering_by_count_then_oldest(client, db):
    org = await helpers.create_org(db)
    users = []
    for name in ("Dr A", "Dr B", "Dr C"):
        u = await helpers.create_user(db, full_name=name)
        await helpers.add_org_member(db, org, u)
        users.append(u)
    conv = await helpers.create_conversation(
        db, org, users, conv_type=ConversationType.GROUP, name="Team"
    )
    a, b, c = [await helpers.auth_headers(u.id) for u in users]
    resp = await client.post(
        f"/api/v1/conversations/{conv.id}/messages",
        json={"type": "text", "content": "rounds at 7"},
        headers=a,
    )
    assert resp.status_code == 200, resp.text
    mid = resp.json()["id"]
    # ❤️ first (older), then two 👍: count wins over age.
    await client.put(_url(mid), json={"emoji": "❤️"}, headers=a)
    await client.put(_url(mid), json={"emoji": "👍"}, headers=b)
    resp = await client.put(_url(mid), json={"emoji": "👍"}, headers=c)
    reactions = resp.json()["reactions"]
    assert [r["emoji"] for r in reactions] == ["👍", "❤️"]
    assert reactions[0]["user_ids"] == [str(users[1].id), str(users[2].id)]


@pytest.mark.parametrize("emoji", ["👨‍👩‍👧‍👦", "👍🏽", "🇮🇳", "❤️", "1️⃣"])
async def test_complex_emoji_accepted(client, chat, emoji):
    msg = await _send(client, chat)
    resp = await client.put(_url(msg["id"]), json={"emoji": emoji}, headers=chat.bob_headers)
    assert resp.status_code == 200, resp.text
    assert resp.json()["reactions"][0]["emoji"] == emoji


@pytest.mark.parametrize("emoji", ["a", "👍👍", "ok", "👍 ", "x" * 32])
async def test_invalid_emoji_rejected(client, chat, emoji):
    msg = await _send(client, chat)
    resp = await client.put(_url(msg["id"]), json={"emoji": emoji}, headers=chat.bob_headers)
    assert resp.status_code == 422
    assert resp.json()["detail"] == "invalid_emoji"


async def test_too_long_payload_rejected(client, chat):
    msg = await _send(client, chat)
    resp = await client.put(_url(msg["id"]), json={"emoji": "👍" * 20}, headers=chat.bob_headers)
    assert resp.status_code == 422


async def test_non_member_forbidden(client, chat, db):
    msg = await _send(client, chat)
    eve = await helpers.create_user(db, full_name="Dr Eve")
    await helpers.add_org_member(db, chat.org, eve)
    headers = await helpers.auth_headers(eve.id)
    resp = await client.put(_url(msg["id"]), json={"emoji": "👍"}, headers=headers)
    # Same answer as a missing id: no existence oracle for outsiders.
    assert resp.status_code == 404
    assert resp.json()["detail"] == "message_not_found"


async def test_blocked_user_cannot_react_or_ping(client, chat, db, ws_events, fake_sender):
    """Security: a block freezes reactions like it freezes sends, and the
    blocker gets no push or WS event (a block is never observable)."""
    await PushService.register_token(user_id=chat.bob.id, token="bob-tok", platform="ios", db=db)
    await db.commit()
    msg = await _send(client, chat, "from bob", headers=chat.bob_headers)
    await _drain()
    fake_sender.calls.clear()
    db.add(Block(blocker_id=chat.bob.id, blocked_id=chat.alice.id))
    await db.commit()
    resp = await client.put(_url(msg["id"]), json={"emoji": "❤️"}, headers=chat.alice_headers)
    assert resp.status_code == 403
    await _drain()
    assert fake_sender.calls == []
    assert _reacted(ws_events) == []
    count = await db.scalar(select(func.count()).select_from(MessageReaction))
    assert count == 0


async def test_expired_message_not_reactable_before_purge(client, chat, db):
    """Security: a disappeared message (expires_at passed, purge not run yet)
    is invisible to reads, so it takes no reactions either."""
    msg = await _send(client, chat)
    await db.execute(
        update(Message)
        .where(Message.id == msg["id"])
        .values(expires_at=datetime.now(tz=timezone.utc) - timedelta(seconds=1))
    )
    await db.commit()
    resp = await client.put(_url(msg["id"]), json={"emoji": "👍"}, headers=chat.bob_headers)
    assert resp.status_code == 404


async def test_unknown_message_404(client, chat):
    resp = await client.put(
        _url(str(uuid.uuid4())), json={"emoji": "👍"}, headers=chat.bob_headers
    )
    assert resp.status_code == 404


async def test_system_message_not_reactable(client, chat, db):
    sys_msg = await MessageService.send_system(
        conv=chat.conv, sender_id=chat.alice.id, content="Disappearing messages on", db=db
    )
    await db.commit()
    resp = await client.put(
        _url(str(sys_msg.id)), json={"emoji": "👍"}, headers=chat.bob_headers
    )
    assert resp.status_code == 409
    assert resp.json()["detail"] == "message_not_reactable"


async def test_delete_clears_reactions_and_blocks_new_ones(client, chat, db):
    msg = await _send(client, chat)
    await client.put(_url(msg["id"]), json={"emoji": "👍"}, headers=chat.bob_headers)
    resp = await client.delete(f"/api/v1/messages/{msg['id']}", headers=chat.alice_headers)
    assert resp.status_code == 200
    assert resp.json()["reactions"] == []
    count = await db.scalar(select(func.count()).select_from(MessageReaction))
    assert count == 0
    resp = await client.put(_url(msg["id"]), json={"emoji": "👍"}, headers=chat.bob_headers)
    assert resp.status_code == 409
    assert resp.json()["detail"] == "message_deleted"


async def test_edit_broadcast_keeps_reactions(client, chat, ws_events):
    msg = await _send(client, chat, "draft")
    await client.put(_url(msg["id"]), json={"emoji": "👍"}, headers=chat.bob_headers)
    resp = await client.patch(
        f"/api/v1/messages/{msg['id']}", json={"content": "final"}, headers=chat.alice_headers
    )
    assert resp.status_code == 200
    assert resp.json()["reactions"][0]["emoji"] == "👍"
    edited = [d for ev, _, d in ws_events if ev == "message_edited"]
    assert edited[-1]["reactions"][0]["emoji"] == "👍"
    assert edited[-1]["changed_at"] is not None


async def test_changed_since_returns_only_changed(client, chat, db):
    m1 = await _send(client, chat, "one")
    m2 = await _send(client, chat, "two")
    await _send(client, chat, "three")
    since = datetime.now(tz=timezone.utc) - timedelta(seconds=1)
    await client.put(_url(m1["id"]), json={"emoji": "👍"}, headers=chat.bob_headers)
    await client.patch(
        f"/api/v1/messages/{m2['id']}", json={"content": "two!"}, headers=chat.alice_headers
    )
    resp = await client.get(
        f"/api/v1/conversations/{chat.conv.id}/messages",
        params={"changed_since": since.isoformat()},
        headers=chat.bob_headers,
    )
    assert resp.status_code == 200, resp.text
    ids = [m["id"] for m in resp.json()]
    assert ids == [m1["id"], m2["id"]]  # ordered by changed_at
    assert resp.json()[0]["reactions"][0]["emoji"] == "👍"

    resp = await client.get(
        f"/api/v1/conversations/{chat.conv.id}/messages",
        params={"changed_since": since.isoformat(), "after_seq": 0},
        headers=chat.bob_headers,
    )
    assert resp.status_code == 400


async def test_push_to_author_only_on_set_by_someone_else(client, chat, db, fake_sender):
    await PushService.register_token(
        user_id=chat.alice.id, token="alice-tok", platform="ios", db=db
    )
    await PushService.register_token(user_id=chat.bob.id, token="bob-tok", platform="ios", db=db)
    await db.commit()
    msg = await _send(client, chat, "patient in bed 4 needs a consult")
    await _drain()
    fake_sender.calls.clear()  # drop the new-message push

    await client.put(_url(msg["id"]), json={"emoji": "👍"}, headers=chat.bob_headers)
    await _drain()
    assert len(fake_sender.calls) == 1
    call = fake_sender.calls[0]
    assert call["token"] == "alice-tok"
    assert call["body"] == "Dr Bob reacted 👍 to your message"
    assert "bed 4" not in call["body"]  # never message content
    assert call["data"] == {"type": "reaction", "conversation_id": str(chat.conv.id)}
    assert call["collapse_key"] == f"reaction:{chat.conv.id}"

    # Removal → nothing. Reacting to your own message → nothing.
    fake_sender.calls.clear()
    await client.delete(_url(msg["id"]), headers=chat.bob_headers)
    await client.put(_url(msg["id"]), json={"emoji": "❤️"}, headers=chat.alice_headers)
    await _drain()
    assert fake_sender.calls == []


async def test_list_page_reaction_queries_constant(client, chat, db):
    """reactions_for batches a page into one query (no N+1)."""
    ids = []
    for i in range(5):
        ids.append((await _send(client, chat, f"m{i}"))["id"])
    for mid in ids:
        await client.put(_url(mid), json={"emoji": "👍"}, headers=chat.bob_headers)
    msgs = (
        await db.scalars(select(Message).where(Message.conversation_id == chat.conv.id))
    ).all()
    result = await MessageService.reactions_for(message_ids=[m.id for m in msgs], db=db)
    assert len(result) == 5
    assert all(r[0].count == 1 for r in result.values())
