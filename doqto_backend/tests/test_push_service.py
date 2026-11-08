"""PushService._dispatch — presence gating, sender exclusion, token pruning,
and the PHI guard (payload must be constants + conversation UUID, nothing else).

_dispatch is awaited directly (not via notify_new_message's create_task) so
tests don't depend on task scheduling."""
from __future__ import annotations

import uuid

import pytest
from sqlalchemy import func, select

from app.core.constants import (
    PRESENCE_AWAY_TTL_SECONDS,
    PRESENCE_ONLINE_TTL_SECONDS,
    PUSH_TITLE,
)
from app.core.enums import PresenceStatus
from app.core.redis_keys import presence_key
from app.db.redis import get_redis
from app.models import DeviceToken
from app.services import push_service
from app.services.push_service import PushResult, PushService


class RecordingSender:
    """Records every send; returns False for tokens in invalid_tokens."""

    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.invalid_tokens: set[str] = set()
        self.failing_tokens: set[str] = set()

    async def send(
        self, *, token: str, title: str, body: str, data: dict[str, str], collapse_key: str,
        badge: int | None = None,
    ) -> PushResult:
        self.calls.append(
            {
                "token": token,
                "title": title,
                "body": body,
                "data": data,
                "collapse_key": collapse_key,
            }
        )
        if token in self.invalid_tokens:
            return PushResult.DEAD
        if token in self.failing_tokens:
            return PushResult.FAILED
        return PushResult.SENT


@pytest.fixture
def fake_sender():
    fake = RecordingSender()
    push_service.sender_factory = lambda: fake
    yield fake
    push_service.sender_factory = push_service._default_sender


async def _register(db, user_id: uuid.UUID) -> str:
    token = f"fake-token-{uuid.uuid4().hex}"
    await PushService.register_token(
        user_id=user_id, token=token, platform="ios", db=db
    )
    await db.commit()
    return token


async def _set_presence(user_id: uuid.UUID, status: PresenceStatus, ttl: int) -> None:
    redis = await get_redis()
    await redis.setex(presence_key(user_id), ttl, status.value)


async def _dispatch(chat) -> None:
    await PushService._dispatch(
        conversation_id=chat.conv.id,
        recipient_ids=[chat.alice.id, chat.bob.id],
        sender_id=chat.alice.id,
    )


async def test_online_recipient_is_still_pushed(db, chat, fake_sender):
    """A killed iOS app keeps its socket 'online' for minutes; FCM suppresses
    foreground display itself, so presence must not gate the push."""
    token = await _register(db, chat.bob.id)
    await _set_presence(chat.bob.id, PresenceStatus.ONLINE, PRESENCE_ONLINE_TTL_SECONDS)
    await _dispatch(chat)
    assert [c["token"] for c in fake_sender.calls] == [token]


async def test_away_recipient_is_pushed(db, chat, fake_sender):
    token = await _register(db, chat.bob.id)
    await _set_presence(chat.bob.id, PresenceStatus.AWAY, PRESENCE_AWAY_TTL_SECONDS)
    await _dispatch(chat)
    assert [c["token"] for c in fake_sender.calls] == [token]


async def test_absent_presence_is_pushed(db, chat, fake_sender):
    token = await _register(db, chat.bob.id)  # no presence key at all
    await _dispatch(chat)
    assert [c["token"] for c in fake_sender.calls] == [token]
    # Sender's name (directory data) in the body; never the message content.
    assert fake_sender.calls[0]["body"] == f"{chat.alice.full_name} sent you a message"


async def test_sender_is_excluded(db, chat, fake_sender):
    await _register(db, chat.alice.id)  # sender's own device, offline
    bob_token = await _register(db, chat.bob.id)
    await _dispatch(chat)
    assert [c["token"] for c in fake_sender.calls] == [bob_token]


async def test_invalid_token_row_is_pruned(db, chat, fake_sender):
    token = await _register(db, chat.bob.id)
    fake_sender.invalid_tokens.add(token)
    await _dispatch(chat)
    assert [c["token"] for c in fake_sender.calls] == [token]
    db.expire_all()
    count = await db.scalar(select(func.count()).select_from(DeviceToken))
    assert count == 0


async def test_payload_is_phi_free(db, chat, fake_sender):
    """The payload is the fixed title, the sender's NAME (directory data, not
    PHI) and the conversation UUID — never message content or anything else."""
    await _register(db, chat.bob.id)
    await _dispatch(chat)
    assert len(fake_sender.calls) == 1
    call = fake_sender.calls[0]
    assert call["title"] == PUSH_TITLE
    assert call["body"] == f"{chat.alice.full_name} sent you a message"
    assert set(call["data"].keys()) == {"type", "conversation_id"}
    assert call["data"]["type"] == "new_message"
    assert call["data"]["conversation_id"] == str(chat.conv.id)
    assert call["collapse_key"] == str(chat.conv.id)


async def test_unread_count_rides_in_the_collapsed_banner(db, chat, fake_sender):
    """Pushes collapse per conversation, so eight messages must say eight."""
    from app.services.message_service import MessageService

    await _register(db, chat.bob.id)
    for i in range(8):
        await MessageService.send_text(
            conversation_id=chat.conv.id, sender_id=chat.alice.id,
            content=f"secret clinical note {i}", db=db,
        )
    await db.commit()
    await _dispatch(chat)

    body = fake_sender.calls[0]["body"]
    assert body == f"{chat.alice.full_name} sent you 8 new messages"
    assert "secret" not in body


def test_fcm_message_survives_an_offline_phone():
    """Apple and Google hold the push while the phone is off or offline and
    deliver it on reconnect, app closed or not."""
    from app.services.push_service import PUSH_TTL_SECONDS, fcm_message

    m = fcm_message(
        token="t", title="Doqto", body="Dr A sent you a message",
        data={"type": "new_message", "conversation_id": "c"},
        collapse_key="c", now=1_000_000,
    )
    apns = m["apns"]["headers"]
    assert apns["apns-expiration"] == str(1_000_000 + PUSH_TTL_SECONDS)
    assert apns["apns-push-type"] == "alert"
    assert apns["apns-priority"] == "10"
    assert apns["apns-collapse-id"] == "c"
    assert m["android"]["ttl"] == f"{PUSH_TTL_SECONDS}s"
    assert m["android"]["priority"] == "high"
    assert PUSH_TTL_SECONDS >= 7 * 24 * 3600


async def test_failed_push_keeps_token_and_is_not_logged_as_sent(db, chat, fake_sender, caplog):
    """FCM 401 (bad APNs key) is a config failure, not a dead device."""
    token = await _register(db, chat.bob.id)
    fake_sender.failing_tokens.add(token)
    with caplog.at_level("INFO", logger="doqto.push"):
        await _dispatch(chat)
    db.expire_all()
    assert await db.scalar(select(func.count()).select_from(DeviceToken)) == 1
    assert any("push failed" in r.getMessage() for r in caplog.records)
    assert not any("push sent" in r.getMessage() for r in caplog.records)
