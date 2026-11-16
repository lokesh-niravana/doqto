"""Batch 6 — settings backend: notification preferences driving APNs / FCM
(tone, channel, priority, reaction drop, per-chat tone, mention tone),
screenshot audit + org policy, linked-device sessions (create / list / revoke
/ revoke-others / refresh rotation / new sign-in alert / 401 after revoke),
two-step PIN (set / change / remove / new-device gate / verify / lockout /
7-day reset), change number, account export (no messages), status presets
with expiry, and the unauthenticated app metadata routes.
"""
from __future__ import annotations

import asyncio
import json
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy import select

import app.api.v1.users as users_module
import app.services.session_service as session_module
import app.services.status_service as status_module
from app.core.constants import (
    PIN_RESET_COOLDOWN_SEC,
    PUSH_CHANNEL_GROUPS,
    PUSH_CHANNEL_INVITATIONS,
    PUSH_CHANNEL_MESSAGES,
    RATE_LIMIT_PIN_VERIFY_PER_15_MIN,
)
from app.core.enums import (
    AuditAction,
    ConversationType,
    JwtTokenType,
    StatusPreset,
    WsEventServer,
)
from app.core.redis_keys import refresh_session_key, session_key
from app.core.security import decode_token
from app.db.redis import get_redis
from app.models import AuditLog, Notification, Session, User, UserNotificationSettings
from app.services import push_service
from app.services.notification_settings_service import apns_sound
from app.services.push_service import PushResult, PushService, fcm_message
from app.services.session_service import PinService
from app.services.status_service import StatusService
from tests import helpers

pytestmark = pytest.mark.asyncio

AUTH = "/api/v1/auth"
USERS = "/api/v1/users"
CONVS = "/api/v1/conversations"
MSGS = "/api/v1/messages"


# --------------------------------------------------------------------------- #
# fixtures
# --------------------------------------------------------------------------- #
class RecordingSender:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    async def send(self, *, token, title, body, data, collapse_key, badge=None, **extra):
        self.calls.append(
            {"token": token, "body": body, "data": data, "collapse_key": collapse_key, **extra}
        )
        return PushResult.SENT


@pytest.fixture
def fake_sender():
    fake = RecordingSender()
    push_service.sender_factory = lambda: fake
    yield fake
    push_service.sender_factory = push_service._default_sender


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


def _of(sent, event):
    return [(ids, data) for ids, ev, data in sent if ev == event]


async def _drain() -> None:
    pending = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)


async def _register(db, user_id) -> str:
    token = f"tok-{uuid.uuid4().hex}"
    await PushService.register_token(user_id=user_id, token=token, platform="ios", db=db)
    await db.commit()
    return token


async def _audit(db, action: AuditAction) -> list[AuditLog]:
    rows = await db.scalars(select(AuditLog).where(AuditLog.action == action.value))
    return list(rows.all())


async def _sign_in(client, firebase, user: User, **device):
    firebase(uid=user.firebase_uid or "fb-uid", phone=user.phone)
    r = await client.post(f"{AUTH}/firebase", json={"id_token": "x", **device})
    assert r.status_code == 200, r.text
    return r.json()


def _bearer(pair: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {pair['access_token']}"}


@pytest.fixture
async def fb_user(db):
    user = await helpers.create_user(db, full_name="Dr Session")
    user.firebase_uid = "fb-uid-session"
    await db.commit()
    return user


# --------------------------------------------------------------------------- #
# B. notification settings
# --------------------------------------------------------------------------- #
async def test_defaults_preview_off_for_org_members_on_for_solo(client, db, chat):
    r = await client.get(f"{USERS}/me/notifications", headers=chat.alice_headers)
    assert r.status_code == 200
    body = r.json()
    assert body["messages_show_preview"] is False and body["groups_show_preview"] is False
    assert body["messages_tone"] == "default" and body["reaction_notifications"] is True
    solo = await helpers.create_user(db)
    r = await client.get(f"{USERS}/me/notifications", headers=await helpers.auth_headers(solo.id))
    assert r.json()["messages_show_preview"] is True


async def test_patch_is_partial_idempotent_audited_and_own_devices_only(
    client, db, chat, monkeypatch
):
    sent = _recorder(monkeypatch, users_module)
    r = await client.patch(
        f"{USERS}/me/notifications",
        json={"messages_tone": "chime", "reaction_notifications": False},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["messages_tone"] == "chime" and r.json()["groups_tone"] == "default"
    # Explicit preview choice survives the org default.
    r = await client.patch(
        f"{USERS}/me/notifications", json={"messages_show_preview": True}, headers=chat.alice_headers
    )
    assert r.json()["messages_show_preview"] is True and r.json()["messages_tone"] == "chime"
    # Same values again: no audit row, no event.
    r = await client.patch(
        f"{USERS}/me/notifications", json={"messages_tone": "chime"}, headers=chat.alice_headers
    )
    assert r.status_code == 200
    rows = await _audit(db, AuditAction.NOTIFICATION_SETTINGS_UPDATED)
    assert [sorted(r.meta["fields"]) for r in rows] == [
        ["messages_tone", "reaction_notifications"],
        ["messages_show_preview"],
    ]
    events = _of(sent, WsEventServer.NOTIFICATION_SETTINGS_UPDATED)
    assert len(events) == 2 and all(ids == {chat.alice.id} for ids, _ in events)
    assert events[-1][1]["messages_tone"] == "chime"
    # Bob is untouched.
    r = await client.get(f"{USERS}/me/notifications", headers=chat.bob_headers)
    assert r.json()["messages_tone"] == "default"


async def test_unknown_tone_and_vibrate_are_rejected(client, chat):
    r = await client.patch(
        f"{USERS}/me/notifications", json={"messages_tone": "rickroll"}, headers=chat.alice_headers
    )
    assert r.status_code == 422
    r = await client.patch(
        f"{USERS}/me/notifications", json={"groups_vibrate": "earthquake"}, headers=chat.alice_headers
    )
    assert r.status_code == 422


async def test_reset_returns_to_defaults(client, db, chat):
    await client.patch(
        f"{USERS}/me/notifications", json={"haptics": False}, headers=chat.alice_headers
    )
    r = await client.patch(f"{USERS}/me/notifications", json={"reset": True}, headers=chat.alice_headers)
    assert r.status_code == 200 and r.json()["haptics"] is True
    assert (
        await db.scalar(
            select(UserNotificationSettings).where(UserNotificationSettings.user_id == chat.alice.id)
        )
    ) is None


async def test_fcm_message_carries_sound_channel_and_priority():
    m = fcm_message(
        token="t", title="Doqto", body="b", data={}, collapse_key="c",
        sound="chime.caf", channel_id=PUSH_CHANNEL_GROUPS, high_priority=False,
    )
    assert m["apns"]["payload"]["aps"]["sound"] == "chime.caf"
    assert m["android"]["notification"] == {"channel_id": "groups", "sound": "chime"}
    assert m["android"]["priority"] == "normal"
    silent = fcm_message(token="t", title="a", body="b", data={}, collapse_key="c", sound=None)
    assert "sound" not in silent["apns"]["payload"]["aps"]
    assert apns_sound(None) == "default" and apns_sound("none") is None
    assert apns_sound("pulse") == "pulse.caf"


async def test_push_uses_messages_tone_and_per_chat_custom_tone_wins(
    client, db, chat, fake_sender
):
    token = await _register(db, chat.bob.id)
    await client.patch(
        f"{USERS}/me/notifications",
        json={"messages_tone": "chime", "messages_high_priority": False},
        headers=chat.bob_headers,
    )
    await PushService._dispatch(
        conversation_id=chat.conv.id, recipient_ids=[chat.alice.id, chat.bob.id], sender_id=chat.alice.id
    )
    assert [c["token"] for c in fake_sender.calls] == [token]
    call = fake_sender.calls[0]
    assert call["sound"] == "chime.caf"
    assert call["channel_id"] == PUSH_CHANNEL_MESSAGES
    assert call["high_priority"] is False
    # Per-chat custom tone (batch 3 prefs) beats the global one.
    r = await client.patch(
        f"{CONVS}/{chat.conv.id}/prefs", json={"custom_tone": "bell"}, headers=chat.bob_headers
    )
    assert r.status_code == 200, r.text
    fake_sender.calls.clear()
    await PushService._dispatch(
        conversation_id=chat.conv.id, recipient_ids=[chat.alice.id, chat.bob.id], sender_id=chat.alice.id
    )
    assert fake_sender.calls[0]["sound"] == "bell.caf"


async def test_group_push_uses_groups_tone_and_channel(client, db, chat, fake_sender):
    group = await helpers.create_conversation(
        db, chat.org, [chat.alice, chat.bob], conv_type=ConversationType.GROUP, name="Ward 3"
    )
    await _register(db, chat.bob.id)
    await client.patch(
        f"{USERS}/me/notifications",
        json={"messages_tone": "chime", "groups_tone": "pulse"},
        headers=chat.bob_headers,
    )
    await PushService._dispatch(
        conversation_id=group.id, recipient_ids=[chat.alice.id, chat.bob.id], sender_id=chat.alice.id
    )
    assert fake_sender.calls[0]["sound"] == "pulse.caf"
    assert fake_sender.calls[0]["channel_id"] == PUSH_CHANNEL_GROUPS


async def test_reaction_push_dropped_when_off(client, db, chat, fake_sender):
    await _register(db, chat.alice.id)
    await PushService._dispatch_reaction(
        conversation_id=chat.conv.id, author_id=chat.alice.id, actor_id=chat.bob.id, emoji="👍"
    )
    assert len(fake_sender.calls) == 1 and "reacted" in fake_sender.calls[0]["body"]
    await client.patch(
        f"{USERS}/me/notifications", json={"reaction_notifications": False}, headers=chat.alice_headers
    )
    fake_sender.calls.clear()
    await PushService._dispatch_reaction(
        conversation_id=chat.conv.id, author_id=chat.alice.id, actor_id=chat.bob.id, emoji="👍"
    )
    assert fake_sender.calls == []


async def test_mention_push_bypasses_mute_but_honours_tone(client, db, chat, fake_sender):
    await _register(db, chat.bob.id)
    await client.patch(
        f"{USERS}/me/notifications", json={"messages_tone": "glass"}, headers=chat.bob_headers
    )
    r = await client.patch(
        f"{CONVS}/{chat.conv.id}/prefs",
        json={"muted_until": "9999-12-31T00:00:00Z"},
        headers=chat.bob_headers,
    )
    assert r.status_code == 200, r.text
    await PushService._dispatch(
        conversation_id=chat.conv.id, recipient_ids=[chat.alice.id, chat.bob.id], sender_id=chat.alice.id
    )
    assert fake_sender.calls == []  # muted
    await PushService._dispatch_mentions(
        conversation_id=chat.conv.id, mentioned_ids=[chat.bob.id], sender_id=chat.alice.id
    )
    assert len(fake_sender.calls) == 1
    assert fake_sender.calls[0]["data"]["type"] == "mention"
    assert fake_sender.calls[0]["sound"] == "glass.caf"


async def test_invitation_push_uses_invitations_channel(db, chat, fake_sender):
    await _register(db, chat.bob.id)
    PushService.notify_invitation_received(
        recipient_id=chat.bob.id, actor_name="Dr Alice", invitation_id=uuid.uuid4()
    )
    await _drain()
    assert fake_sender.calls[0]["channel_id"] == PUSH_CHANNEL_INVITATIONS


# --------------------------------------------------------------------------- #
# C. screenshot audit + org policy
# --------------------------------------------------------------------------- #
async def test_screenshot_audit_member_only(client, db, chat):
    r = await client.post(
        "/api/v1/audit/screenshot", json={"conversation_id": str(chat.conv.id)}, headers=chat.alice_headers
    )
    assert r.status_code == 200, r.text
    rows = await _audit(db, AuditAction.SCREENSHOT_TAKEN)
    assert len(rows) == 1 and rows[0].resource_id == chat.conv.id and rows[0].user_id == chat.alice.id
    outsider = await helpers.create_user(db)
    r = await client.post(
        "/api/v1/audit/screenshot",
        json={"conversation_id": str(chat.conv.id)},
        headers=await helpers.auth_headers(outsider.id),
    )
    assert r.status_code == 404 and r.json()["detail"] == "conversation_not_found"
    assert len(await _audit(db, AuditAction.SCREENSHOT_TAKEN)) == 1


async def test_block_screenshots_org_policy(client, db, chat):
    from app.core.enums import OrgRole
    from app.models import OrgMember

    m = await db.scalar(
        select(OrgMember).where(OrgMember.user_id == chat.alice.id, OrgMember.org_id == chat.org.id)
    )
    m.org_role = OrgRole.ADMIN
    await db.commit()
    r = await client.get(f"/api/v1/orgs/{chat.org.id}", headers=chat.bob_headers)
    assert r.json()["policies"]["block_screenshots"] is False
    r = await client.patch(
        f"/api/v1/orgs/{chat.org.id}/settings/networking",
        json={"block_screenshots": True},
        headers=chat.alice_headers,
    )
    assert r.status_code == 200, r.text
    assert r.json()["policies"]["block_screenshots"] is True
    r = await client.get(f"/api/v1/orgs/{chat.org.id}", headers=chat.bob_headers)
    assert r.json()["policies"]["block_screenshots"] is True


# --------------------------------------------------------------------------- #
# D. sessions / linked devices
# --------------------------------------------------------------------------- #
async def test_sign_in_creates_a_session_row_and_lists_it_as_current(
    client, db, fb_user, firebase
):
    pair = await _sign_in(
        client, firebase, fb_user, device_name="iPhone 16 Pro", platform="ios", app_version="1.0.0+45"
    )
    assert pair["session_id"] and pair["pin_required"] is False
    row = await db.get(Session, uuid.UUID(pair["session_id"]))
    jti = decode_token(pair["access_token"], JwtTokenType.ACCESS)["jti"]
    assert row.access_jti == jti == row.refresh_jti
    assert (row.device_name, row.platform, row.app_version) == ("iPhone 16 Pro", "ios", "1.0.0+45")
    r = await client.get(f"{USERS}/me/sessions", headers=_bearer(pair))
    assert r.status_code == 200
    assert [(s["device_name"], s["current"]) for s in r.json()] == [("iPhone 16 Pro", True)]


async def test_second_sign_in_alerts_other_devices(
    client, db, fb_user, firebase, fake_sender, monkeypatch
):
    sent = _recorder(monkeypatch, session_module)
    first = await _sign_in(client, firebase, fb_user, device_name="iPhone 16 Pro", platform="ios")
    await _register(db, fb_user.id)
    assert _of(sent, WsEventServer.SESSION_CREATED) == []  # nobody else to tell
    second = await _sign_in(client, firebase, fb_user, device_name="Pixel 9", platform="android")
    await _drain()
    events = _of(sent, WsEventServer.SESSION_CREATED)
    assert len(events) == 1 and events[0][0] == {fb_user.id}
    assert events[0][1]["session_id"] == second["session_id"]
    assert events[0][1]["device_name"] == "Pixel 9"
    notif = await db.scalar(select(Notification).where(Notification.user_id == fb_user.id))
    assert notif.type == "new_sign_in" and notif.payload == {"device_name": "Pixel 9", "platform": "android"}
    assert [c["body"] for c in fake_sender.calls] == ["New sign-in on Pixel 9"]
    assert fake_sender.calls[0]["data"] == {"type": "new_sign_in", "session_id": second["session_id"]}
    # Both devices are listed; each sees itself as current.
    r = await client.get(f"{USERS}/me/sessions", headers=_bearer(first))
    assert {(s["device_name"], s["current"]) for s in r.json()} == {
        ("iPhone 16 Pro", True), ("Pixel 9", False)
    }


async def test_unregistered_user_sign_in_sends_no_alert(client, db, firebase, monkeypatch):
    sent = _recorder(monkeypatch, session_module)
    firebase(uid="brand-new", phone="+13125550000")
    await client.post(f"{AUTH}/firebase", json={"id_token": "x", "device_name": "A"})
    await client.post(f"{AUTH}/firebase", json={"id_token": "x", "device_name": "B"})
    assert _of(sent, WsEventServer.SESSION_CREATED) == []


async def test_revoke_one_session_kills_its_tokens(client, db, fb_user, firebase, monkeypatch):
    sent = _recorder(monkeypatch, session_module)
    phone = await _sign_in(client, firebase, fb_user, device_name="iPhone", platform="ios")
    tablet = await _sign_in(client, firebase, fb_user, device_name="iPad", platform="ios")
    r = await client.delete(f"{USERS}/me/sessions/{tablet['session_id']}", headers=_bearer(phone))
    assert r.status_code == 200, r.text
    r = await client.get(f"{USERS}/me", headers=_bearer(tablet))
    assert r.status_code == 401 and r.json()["detail"] == "session_revoked"
    r = await client.post(f"{AUTH}/refresh", json={"refresh_token": tablet["refresh_token"]})
    assert r.status_code == 401 and r.json()["detail"] == "session_revoked"
    assert _of(sent, WsEventServer.SESSION_REVOKED) == [
        ({fb_user.id}, {"session_id": tablet["session_id"]})
    ]
    rows = await _audit(db, AuditAction.SESSION_REVOKED)
    assert len(rows) == 1 and rows[0].resource_id == uuid.UUID(tablet["session_id"])
    # Idempotent; and the phone still works.
    r = await client.delete(f"{USERS}/me/sessions/{tablet['session_id']}", headers=_bearer(phone))
    assert r.status_code == 200
    r = await client.get(f"{USERS}/me/sessions", headers=_bearer(phone))
    assert [s["device_name"] for s in r.json()] == ["iPhone"]


async def test_cannot_revoke_someone_elses_session(client, db, fb_user, firebase):
    mine = await _sign_in(client, firebase, fb_user, device_name="iPhone", platform="ios")
    other = await helpers.create_user(db)
    r = await client.delete(
        f"{USERS}/me/sessions/{mine['session_id']}", headers=await helpers.auth_headers(other.id)
    )
    assert r.status_code == 404 and r.json()["detail"] == "session_not_found"
    r = await client.get(f"{USERS}/me", headers=_bearer(mine))
    assert r.status_code == 200


async def test_revoke_others_keeps_the_caller(client, db, fb_user, firebase):
    a = await _sign_in(client, firebase, fb_user, device_name="A", platform="ios")
    b = await _sign_in(client, firebase, fb_user, device_name="B", platform="ios")
    c = await _sign_in(client, firebase, fb_user, device_name="C", platform="android")
    r = await client.post(f"{USERS}/me/sessions/revoke-others", headers=_bearer(b))
    assert r.status_code == 200 and r.json() == {"revoked": 2}
    assert (await client.get(f"{USERS}/me", headers=_bearer(a))).status_code == 401
    assert (await client.get(f"{USERS}/me", headers=_bearer(c))).status_code == 401
    r = await client.get(f"{USERS}/me/sessions", headers=_bearer(b))
    assert [(s["device_name"], s["current"]) for s in r.json()] == [("B", True)]
    rows = await _audit(db, AuditAction.SESSION_REVOKED)
    assert rows[0].meta["count"] == 2
    # Nothing left to revoke: no second audit row.
    r = await client.post(f"{USERS}/me/sessions/revoke-others", headers=_bearer(b))
    assert r.json() == {"revoked": 0}
    assert len(await _audit(db, AuditAction.SESSION_REVOKED)) == 1


async def test_refresh_rotates_the_row_and_logout_revokes_it(client, db, fb_user, firebase):
    pair = await _sign_in(client, firebase, fb_user, device_name="iPhone", platform="ios")
    r = await client.post(f"{AUTH}/refresh", json={"refresh_token": pair["refresh_token"]})
    assert r.status_code == 200
    new = r.json()
    assert new["session_id"] == pair["session_id"]
    row = await db.get(Session, uuid.UUID(pair["session_id"]))
    new_jti = decode_token(new["access_token"], JwtTokenType.ACCESS)["jti"]
    assert row.access_jti == new_jti == row.refresh_jti
    r = await client.get(f"{USERS}/me/sessions", headers=_bearer(new))
    assert r.json()[0]["current"] is True
    r = await client.post(f"{AUTH}/logout", headers=_bearer(new))
    assert r.status_code == 200
    await db.refresh(row)
    assert row.revoked_at is not None
    redis = await get_redis()
    assert not await redis.exists(session_key(new_jti))
    assert not await redis.exists(refresh_session_key(new_jti))


# --------------------------------------------------------------------------- #
# E. two-step PIN
# --------------------------------------------------------------------------- #
async def test_pin_set_requires_digits_and_change_requires_current(client, db, fb_user, firebase):
    pair = await _sign_in(client, firebase, fb_user, device_name="iPhone", platform="ios")
    r = await client.put(f"{USERS}/me/pin", json={"pin": "12ab56"}, headers=_bearer(pair))
    assert r.status_code == 422
    r = await client.put(f"{USERS}/me/pin", json={"pin": "123456"}, headers=_bearer(pair))
    assert r.status_code == 200 and r.json()["pin_enabled"] is True
    await db.refresh(fb_user)
    assert fb_user.pin_hash and fb_user.pin_hash != "123456"
    assert PinService.check("123456", fb_user.pin_hash)
    r = await client.get(f"{USERS}/me", headers=_bearer(pair))
    assert r.json()["pin_enabled"] is True
    # Change without / with the current PIN.
    r = await client.put(f"{USERS}/me/pin", json={"pin": "654321"}, headers=_bearer(pair))
    assert r.status_code == 401 and r.json()["detail"] == "pin_invalid"
    r = await client.put(
        f"{USERS}/me/pin", json={"pin": "654321", "current_pin": "123456"}, headers=_bearer(pair)
    )
    assert r.status_code == 200
    # Remove needs the PIN too.
    r = await client.request(
        "DELETE", f"{USERS}/me/pin", json={"pin": "000000"}, headers=_bearer(pair)
    )
    assert r.status_code == 401
    r = await client.request(
        "DELETE", f"{USERS}/me/pin", json={"pin": "654321"}, headers=_bearer(pair)
    )
    assert r.status_code == 200 and r.json()["pin_enabled"] is False
    assert {a.action for a in await db.scalars(select(AuditLog))} >= {
        AuditAction.PIN_SET.value, AuditAction.PIN_REMOVED.value
    }


async def test_new_device_owes_the_pin_until_verified(client, db, fb_user, firebase):
    phone = await _sign_in(client, firebase, fb_user, device_name="iPhone", platform="ios")
    await client.put(f"{USERS}/me/pin", json={"pin": "123456"}, headers=_bearer(phone))
    # Known device: straight in.
    again = await _sign_in(client, firebase, fb_user, device_name="iPhone", platform="ios")
    assert again["pin_required"] is False
    assert (await client.get(f"{USERS}/me", headers=_bearer(again))).status_code == 200
    # Unknown device: tokens issued, everything else gated.
    tablet = await _sign_in(client, firebase, fb_user, device_name="iPad", platform="ios")
    assert tablet["pin_required"] is True
    r = await client.get(f"{USERS}/me", headers=_bearer(tablet))
    assert r.status_code == 403 and r.json()["detail"] == "pin_required"
    r = await client.get(f"{USERS}/me/sessions", headers=_bearer(tablet))
    assert r.status_code == 403
    # Refresh keeps the gate.
    r = await client.post(f"{AUTH}/refresh", json={"refresh_token": tablet["refresh_token"]})
    assert r.status_code == 200 and r.json()["pin_required"] is True
    tablet = r.json()
    # Wrong, then right.
    r = await client.post(f"{AUTH}/pin/verify", json={"pin": "000000"}, headers=_bearer(tablet))
    assert r.status_code == 401 and r.json()["detail"] == "pin_invalid"
    r = await client.post(f"{AUTH}/pin/verify", json={"pin": "123456"}, headers=_bearer(tablet))
    assert r.status_code == 200, r.text
    assert (await client.get(f"{USERS}/me", headers=_bearer(tablet))).status_code == 200
    # The gate was per session: the phone never noticed.
    assert (await client.get(f"{USERS}/me", headers=_bearer(phone))).status_code == 200
    assert len(await _audit(db, AuditAction.PIN_VERIFIED)) == 1


async def test_pin_verify_locks_out_after_too_many_attempts(client, db, fb_user, firebase):
    phone = await _sign_in(client, firebase, fb_user, device_name="iPhone", platform="ios")
    await client.put(f"{USERS}/me/pin", json={"pin": "123456"}, headers=_bearer(phone))
    tablet = await _sign_in(client, firebase, fb_user, device_name="iPad", platform="ios")
    for _ in range(RATE_LIMIT_PIN_VERIFY_PER_15_MIN):
        r = await client.post(f"{AUTH}/pin/verify", json={"pin": "999999"}, headers=_bearer(tablet))
        assert r.status_code == 401
    r = await client.post(f"{AUTH}/pin/verify", json={"pin": "123456"}, headers=_bearer(tablet))
    assert r.status_code == 429 and r.json()["detail"] == "pin_too_many_attempts"


async def test_forgot_pin_cooldown_clears_after_seven_days(client, db, fb_user, firebase):
    phone = await _sign_in(client, firebase, fb_user, device_name="iPhone", platform="ios")
    await client.put(f"{USERS}/me/pin", json={"pin": "123456"}, headers=_bearer(phone))
    tablet = await _sign_in(client, firebase, fb_user, device_name="iPad", platform="ios")
    r = await client.post(f"{AUTH}/pin/reset-request", headers=_bearer(tablet))
    assert r.status_code == 200, r.text
    clears_at = datetime.fromisoformat(r.json()["pin_clears_at"])
    assert timedelta(days=6, hours=23) < clears_at - datetime.now(timezone.utc) <= timedelta(days=7)
    # Asking again is idempotent; sign-in responses surface the instant.
    r2 = await client.post(f"{AUTH}/pin/reset-request", headers=_bearer(tablet))
    assert r2.json()["pin_clears_at"] == r.json()["pin_clears_at"]
    again = await _sign_in(client, firebase, fb_user, device_name="Pixel", platform="android")
    assert again["pin_required"] is True and again["pin_clears_at"] == r.json()["pin_clears_at"]
    # Not yet: the loop finds nothing.
    assert await PinService.complete_resets(db) == []
    assert (await client.get(f"{USERS}/me", headers=_bearer(tablet))).status_code == 403
    # Seven days later.
    await db.refresh(fb_user)
    fb_user.pin_reset_at = datetime.now(timezone.utc) - timedelta(seconds=PIN_RESET_COOLDOWN_SEC + 1)
    await db.commit()
    assert await PinService.complete_resets(db) == [fb_user.id]
    await db.commit()
    await db.refresh(fb_user)
    assert fb_user.pin_hash is None and fb_user.pin_reset_at is None
    assert (await client.get(f"{USERS}/me", headers=_bearer(tablet))).status_code == 200
    assert len(await _audit(db, AuditAction.PIN_RESET_COMPLETED)) == 1


async def test_entering_the_pin_cancels_a_reset(client, db, fb_user, firebase):
    phone = await _sign_in(client, firebase, fb_user, device_name="iPhone", platform="ios")
    await client.put(f"{USERS}/me/pin", json={"pin": "123456"}, headers=_bearer(phone))
    tablet = await _sign_in(client, firebase, fb_user, device_name="iPad", platform="ios")
    await client.post(f"{AUTH}/pin/reset-request", headers=_bearer(tablet))
    await client.post(f"{AUTH}/pin/verify", json={"pin": "123456"}, headers=_bearer(tablet))
    await db.refresh(fb_user)
    assert fb_user.pin_reset_at is None
    r = await client.get(f"{USERS}/me/pin", headers=_bearer(phone))
    assert r.json() == {"pin_enabled": True, "pin_clears_at": None}


async def test_reset_request_without_a_pin_is_a_conflict(client, chat):
    r = await client.post(f"{AUTH}/pin/reset-request", headers=chat.alice_headers)
    assert r.status_code == 409 and r.json()["detail"] == "pin_not_set"


# --------------------------------------------------------------------------- #
# E. change number
# --------------------------------------------------------------------------- #
async def test_change_number_verifies_uniqueness_and_audits(client, db, chat, firebase):
    chat.alice.firebase_uid = "uid-alice"
    await db.commit()
    firebase(uid="uid-alice", phone="+13125550123")
    r = await client.patch(f"{USERS}/me/phone", json={"id_token": "t"}, headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    assert r.json()["phone"] == "+13125550123"
    rows = await _audit(db, AuditAction.PHONE_CHANGED)
    assert len(rows) == 1 and rows[0].meta is None  # no numbers in the row
    # Bob's number: taken.
    firebase(uid="uid-alice", phone=chat.bob.phone)
    r = await client.patch(f"{USERS}/me/phone", json={"id_token": "t"}, headers=chat.alice_headers)
    assert r.status_code == 409 and r.json()["detail"] == "phone_already_registered"
    # A token for another Firebase user: refused.
    firebase(uid="uid-someone-else", phone="+13125550999")
    r = await client.patch(f"{USERS}/me/phone", json={"id_token": "t"}, headers=chat.alice_headers)
    assert r.status_code == 403
    # No phone claim: nothing verified.
    firebase(uid="uid-alice", email="a@example.com")
    r = await client.patch(f"{USERS}/me/phone", json={"id_token": "t"}, headers=chat.alice_headers)
    assert r.status_code == 400 and r.json()["detail"] == "phone_not_verified"


# --------------------------------------------------------------------------- #
# E. account export
# --------------------------------------------------------------------------- #
async def test_export_is_a_presigned_json_without_messages(client, db, chat, fake_s3):
    await helpers.connect_users(db, chat.alice, chat.bob)
    r = await client.post(f"{CONVS}/{chat.conv.id}/messages", json={"content": "PHI here"}, headers=chat.alice_headers)
    assert r.status_code == 200
    await client.patch(f"{USERS}/me/notifications", json={"messages_tone": "chime"}, headers=chat.alice_headers)
    r = await client.post(f"{USERS}/me/export", headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    assert r.json()["url"].startswith("https://s3.test/exports/")
    key = r.json()["url"].split("https://s3.test/")[1].split("?")[0]
    data = json.loads(fake_s3.objects[key])
    assert data["profile"]["id"] == str(chat.alice.id)
    assert data["profile"]["npi_number"] == chat.alice.npi_number
    assert data["settings"]["notifications"]["messages_tone"] == "chime"
    assert [c["user_id"] for c in data["connections"]] == [str(chat.bob.id)]
    assert [o["id"] for o in data["organizations"]] == [str(chat.org.id)]
    assert data["groups"] == []
    assert "messages" not in data and "PHI here" not in fake_s3.objects[key].decode()
    rows = await _audit(db, AuditAction.ACCOUNT_EXPORTED)
    assert len(rows) == 1 and rows[0].user_id == chat.alice.id


# --------------------------------------------------------------------------- #
# E. status under the name
# --------------------------------------------------------------------------- #
async def test_status_preset_custom_expiry_and_clear(client, db, chat, monkeypatch):
    sent = _recorder(monkeypatch, status_module)
    r = await client.patch(
        f"{USERS}/me/status", json={"preset": "on_call", "expires_in_sec": 3600}, headers=chat.alice_headers
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status_preset"] == "on_call" and body["status_text"] is None
    exp = datetime.fromisoformat(body["status_expires_at"])
    assert timedelta(minutes=59) < exp - datetime.now(timezone.utc) <= timedelta(hours=1)
    assert _of(sent, WsEventServer.PROFILE_UPDATED) == [({chat.bob.id}, {"user_id": str(chat.alice.id)})]
    # Shown on the profile and in presence.
    r = await client.get(f"{USERS}/{chat.alice.id}/profile", headers=chat.bob_headers)
    assert r.json()["status_preset"] == "on_call"
    r = await client.get(f"{USERS}/presence?ids={chat.alice.id}", headers=chat.bob_headers)
    assert r.json()[0]["status_preset"] == "on_call"
    r = await client.get(f"{USERS}/me", headers=chat.alice_headers)
    assert r.json()["status_preset"] == "on_call"
    # Custom text, never.
    r = await client.patch(f"{USERS}/me/status", json={"text": "  Rounds till 6 "}, headers=chat.alice_headers)
    assert r.json() == {"status_preset": None, "status_text": "Rounds till 6", "status_expires_at": None}
    rows = await _audit(db, AuditAction.STATUS_UPDATED)
    assert rows[-1].meta == {"preset": None, "custom": True, "expires_in_sec": None}
    # Clear.
    r = await client.patch(f"{USERS}/me/status", json={}, headers=chat.alice_headers)
    assert r.json()["status_text"] is None and r.json()["status_preset"] is None
    # Idempotent clear: no extra event.
    before = len(sent)
    r = await client.patch(f"{USERS}/me/status", json={}, headers=chat.alice_headers)
    assert r.status_code == 200 and len(sent) == before


async def test_status_validation(client, chat):
    h = chat.alice_headers
    assert (await client.patch(f"{USERS}/me/status", json={"preset": "napping"}, headers=h)).status_code == 422
    assert (await client.patch(f"{USERS}/me/status", json={"text": "x" * 41}, headers=h)).status_code == 422
    assert (
        await client.patch(f"{USERS}/me/status", json={"preset": "on_call", "text": "hi"}, headers=h)
    ).status_code == 422
    assert (
        await client.patch(f"{USERS}/me/status", json={"preset": "on_call", "expires_in_sec": 42}, headers=h)
    ).status_code == 422
    for p in StatusPreset:
        r = await client.patch(f"{USERS}/me/status", json={"preset": p.value}, headers=h)
        assert r.status_code == 200 and r.json()["status_preset"] == p.value


async def test_expired_status_is_hidden_then_cleared_by_the_loop(client, db, chat, monkeypatch):
    sent = _recorder(monkeypatch, status_module)
    await client.patch(
        f"{USERS}/me/status", json={"preset": "in_surgery", "expires_in_sec": 3600}, headers=chat.alice_headers
    )
    await db.refresh(chat.alice)
    chat.alice.status_expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    await db.commit()
    # Presence hides it even before the loop runs.
    r = await client.get(f"{USERS}/presence?ids={chat.alice.id}", headers=chat.bob_headers)
    assert r.json()[0]["status_preset"] is None
    assert await StatusService.expire(db) == [chat.alice.id]
    await db.commit()
    await StatusService.publish(chat.alice.id, db)
    await db.refresh(chat.alice)
    assert chat.alice.status_text is None and chat.alice.status_expires_at is None
    assert _of(sent, WsEventServer.PROFILE_UPDATED)[-1][0] == {chat.bob.id}
    assert await StatusService.expire(db) == []


# --------------------------------------------------------------------------- #
# F. app metadata
# --------------------------------------------------------------------------- #
async def test_min_version_and_legal_need_no_auth(client):
    r = await client.get("/api/v1/app/min-version")
    assert r.status_code == 200
    assert set(r.json()) == {"ios", "android", "message"}
    assert "+" in r.json()["ios"] and "+" in r.json()["android"]
    r = await client.get("/api/v1/app/legal")
    assert r.status_code == 200
    assert set(r.json()) == {"help", "contact", "terms", "privacy", "hipaa"}
    assert r.json()["privacy"].startswith("https://")
