"""Operator moderation (App Store 1.2): suspend / unsuspend an account and
remove a reported message, all super-admin only and all audited."""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

import pytest
from sqlalchemy import select
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import app.db.redis as redis_mod
from app.api.ws_manager import ws_manager
from app.core import crypto
from app.core.enums import AuditAction, OrgRole, UserRole
from app.models import AuditLog, Message, MessageEdit, Report, Session
from main import app
from tests import helpers

ADMIN = "/api/v1/admin"
ME = "/api/v1/users/me"
FIREBASE = "/api/v1/auth/firebase"
UID = "firebase-uid-abc123"


@pytest.fixture
def ws_events(monkeypatch):
    events: list[tuple[str, list, dict]] = []

    async def fake_publish(user_ids, event, data):
        events.append((str(event), list(user_ids), data))

    monkeypatch.setattr(ws_manager, "publish_to_users", fake_publish)
    return events


async def _super_admin(db):
    admin = await helpers.create_user(db, full_name="Ops")
    admin.role = UserRole.SUPER_ADMIN
    await db.commit()
    return admin, await helpers.auth_headers(admin.id)


async def _send(client, conv_id, headers, content):
    r = await client.post(
        f"/api/v1/conversations/{conv_id}/messages", json={"content": content}, headers=headers
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _audits(db, action: AuditAction) -> list[AuditLog]:
    return list(
        (await db.scalars(select(AuditLog).where(AuditLog.action == action.value))).all()
    )


async def _suspend(client, user_id, headers, reason="harassing colleagues"):
    return await client.post(
        f"{ADMIN}/users/{user_id}/suspend", json={"reason": reason}, headers=headers
    )


# ================================================================ suspend ==


async def test_suspend_locks_the_account_and_unsuspend_restores_it(client, chat, db):
    admin, admin_h = await _super_admin(db)
    assert (await client.get(ME, headers=chat.bob_headers)).status_code == 200

    r = await _suspend(client, chat.bob.id, admin_h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["id"] == str(chat.bob.id) and body["suspended_at"]
    assert body["suspended_reason"] == "harassing colleagues"

    # The token is still live in Redis (no sessions row behind it), so this
    # is the dependency gate answering — and 403, not 401.
    r = await client.get(ME, headers=chat.bob_headers)
    assert r.status_code == 403 and r.json()["detail"] == "account_suspended"
    # Everyone else is untouched.
    assert (await client.get(ME, headers=chat.alice_headers)).status_code == 200

    audits = await _audits(db, AuditAction.USER_SUSPENDED)
    assert len(audits) == 1
    assert audits[0].user_id == admin.id
    assert audits[0].resource_type == "user" and audits[0].resource_id == chat.bob.id
    assert audits[0].meta == {
        "admin_id": str(admin.id),
        "reason": "harassing colleagues",
        "sessions_revoked": 0,
    }

    # Suspending again changes nothing and writes no second row.
    r = await _suspend(client, chat.bob.id, admin_h, reason="again")
    assert r.status_code == 200 and r.json()["suspended_reason"] == "harassing colleagues"
    assert len(await _audits(db, AuditAction.USER_SUSPENDED)) == 1

    r = await client.post(f"{ADMIN}/users/{chat.bob.id}/unsuspend", headers=admin_h)
    assert r.status_code == 200, r.text
    assert r.json()["suspended_at"] is None and r.json()["suspended_reason"] is None
    assert (await client.get(ME, headers=chat.bob_headers)).status_code == 200

    audits = await _audits(db, AuditAction.USER_UNSUSPENDED)
    assert len(audits) == 1 and audits[0].user_id == admin.id
    assert audits[0].resource_id == chat.bob.id
    assert audits[0].meta == {"admin_id": str(admin.id), "reason": "harassing colleagues"}
    # Lifting a suspension that is not there is a no-op.
    r = await client.post(f"{ADMIN}/users/{chat.bob.id}/unsuspend", headers=admin_h)
    assert r.status_code == 200
    assert len(await _audits(db, AuditAction.USER_UNSUSPENDED)) == 1


async def test_suspend_revokes_live_sessions_and_blocks_sign_in(
    client, db, firebase, ws_events
):
    _, admin_h = await _super_admin(db)
    user = await helpers.create_user(db, full_name="Dr Abuse")
    user.firebase_uid = UID
    await db.commit()
    firebase(phone=user.phone)

    r = await client.post(FIREBASE, json={"id_token": "whatever"})
    assert r.status_code == 200, r.text
    pair = r.json()
    headers = {"Authorization": f"Bearer {pair['access_token']}"}
    assert (await client.get(ME, headers=headers)).status_code == 200

    r = await _suspend(client, user.id, admin_h)
    assert r.status_code == 200, r.text

    # The real session was revoked: row stamped, device told over WS.
    row = (await db.scalars(select(Session).where(Session.user_id == user.id))).one()
    assert row.revoked_at is not None
    revoked = [(ids, d) for ev, ids, d in ws_events if ev == "session_revoked"]
    assert revoked == [([user.id], {"session_id": str(row.id)})]
    audit = (await _audits(db, AuditAction.USER_SUSPENDED))[0]
    assert audit.meta["sessions_revoked"] == 1

    # Old tokens are dead, the refresh half too …
    assert (await client.get(ME, headers=headers)).status_code == 401
    r = await client.post("/api/v1/auth/refresh", json={"refresh_token": pair["refresh_token"]})
    assert r.status_code == 401
    # … and a fresh sign-in is refused, leaving no new session behind.
    r = await client.post(FIREBASE, json={"id_token": "whatever"})
    assert r.status_code == 403 and r.json()["detail"] == "account_suspended"
    assert len((await db.scalars(select(Session).where(Session.user_id == user.id))).all()) == 1

    r = await client.post(f"{ADMIN}/users/{user.id}/unsuspend", headers=admin_h)
    assert r.status_code == 200
    r = await client.post(FIREBASE, json={"id_token": "whatever"})
    assert r.status_code == 200, r.text
    fresh = {"Authorization": f"Bearer {r.json()['access_token']}"}
    assert (await client.get(ME, headers=fresh)).status_code == 200


async def test_refresh_is_refused_for_a_suspended_user_without_a_session_row(client, db):
    """A token pair with no sessions row (legacy / admin panel) cannot be found
    by the revoke, so refresh itself has to say no."""
    from app.core.constants import REFRESH_TOKEN_TTL_SECONDS
    from app.core.enums import JwtTokenType
    from app.core.redis_keys import refresh_session_key
    from app.core.security import create_token
    from app.db.redis import get_redis

    user = await helpers.create_user(db)
    token, jti = create_token(user.id, JwtTokenType.REFRESH)
    await (await get_redis()).setex(refresh_session_key(jti), REFRESH_TOKEN_TTL_SECONDS, "1")
    user.suspended_at = datetime.now(tz=timezone.utc)
    await db.commit()

    r = await client.post("/api/v1/auth/refresh", json={"refresh_token": token})
    assert r.status_code == 403 and r.json()["detail"] == "account_suspended"


async def test_suspended_user_gets_no_socket(db):
    user = await helpers.create_user(db, full_name="Dr Socket")
    user.suspended_at = datetime.now(tz=timezone.utc)
    await db.commit()
    token = helpers.access_token(user.id)
    # The app runs in the TestClient's portal thread: drop the loop-bound
    # Redis client on both sides (see test_ws_health).
    redis_mod._redis = None
    try:
        with TestClient(app).websocket_connect("/ws") as ws:
            ws.send_json({"type": "auth", "token": token})
            with pytest.raises(WebSocketDisconnect) as closed:
                ws.receive_json()
            assert closed.value.code == 4401
    finally:
        redis_mod._redis = None


async def test_open_socket_is_closed_on_the_next_heartbeat_after_suspension(db):
    user = await helpers.create_user(db, full_name="Dr Socket")
    token = helpers.access_token(user.id)
    redis_mod._redis = None
    try:
        with TestClient(app).websocket_connect("/ws") as ws:
            ws.send_json({"type": "auth", "token": token})
            assert ws.receive_json()["type"] == "connected"
            ws.send_json({"type": "heartbeat"})
            assert ws.receive_json()["type"] == "heartbeat_ack"
            user.suspended_at = datetime.now(tz=timezone.utc)
            await db.commit()
            ws.send_json({"type": "heartbeat"})
            with pytest.raises(WebSocketDisconnect) as closed:
                ws.receive_json()
            assert closed.value.code == 4403
    finally:
        redis_mod._redis = None


async def test_suspend_guards(client, chat, db):
    admin, admin_h = await _super_admin(db)
    other_admin, _ = await _super_admin(db)

    # A super admin cannot be suspended — not another one, not yourself.
    for target in (other_admin.id, admin.id):
        r = await _suspend(client, target, admin_h)
        assert r.status_code == 403 and r.json()["detail"] == "cannot_suspend_super_admin"
    # Unknown and deleted accounts are the same 404.
    r = await _suspend(client, uuid.uuid4(), admin_h)
    assert r.status_code == 404 and r.json()["detail"] == "user_not_found"
    gone = await helpers.create_user(db, full_name="Dr Gone")
    gone.deleted_at = datetime.now(tz=timezone.utc)
    await db.commit()
    assert (await _suspend(client, gone.id, admin_h)).status_code == 404
    r = await client.post(f"{ADMIN}/users/{gone.id}/unsuspend", headers=admin_h)
    assert r.status_code == 404
    # The reason is required, non-blank and bounded.
    url = f"{ADMIN}/users/{chat.bob.id}/suspend"
    for bad in ({}, {"reason": ""}, {"reason": "   "}, {"reason": "x" * 256}):
        assert (await client.post(url, json=bad, headers=admin_h)).status_code == 422
    assert await _audits(db, AuditAction.USER_SUSPENDED) == []
    assert (await client.get(ME, headers=chat.bob_headers)).status_code == 200


async def test_moderation_endpoints_are_super_admin_only(client, chat, db):
    msg = await _send(client, chat.conv.id, chat.bob_headers, "x")
    # An org admin is still not an operator.
    boss = await helpers.create_user(db, full_name="Dr Boss")
    await helpers.add_org_member(db, chat.org, boss, role=OrgRole.ADMIN)
    for headers in (chat.alice_headers, await helpers.auth_headers(boss.id)):
        r = await _suspend(client, chat.bob.id, headers)
        assert r.status_code == 403 and r.json()["detail"] == "super_admin_required"
        r = await client.post(f"{ADMIN}/users/{chat.bob.id}/unsuspend", headers=headers)
        assert r.status_code == 403 and r.json()["detail"] == "super_admin_required"
        r = await client.post(f"{ADMIN}/messages/{msg['id']}/remove", headers=headers)
        assert r.status_code == 403 and r.json()["detail"] == "super_admin_required"
    # No token at all.
    assert (await client.post(f"{ADMIN}/messages/{msg['id']}/remove")).status_code == 401
    await db.refresh(chat.bob)
    assert chat.bob.suspended_at is None
    row = await db.get(Message, uuid.UUID(msg["id"]))
    assert row.deleted_at is None and row.content_encrypted is not None


# ========================================================= remove message ==


async def test_remove_message_tombstones_for_everyone_and_is_idempotent(
    client, chat, db, ws_events
):
    admin, admin_h = await _super_admin(db)
    msg = await _send(client, chat.conv.id, chat.bob_headers, "abusive text")
    await client.patch(
        f"/api/v1/messages/{msg['id']}", json={"content": "abusive text v2"},
        headers=chat.bob_headers,
    )
    # Far outside the sender's own delete window: the operator has none.
    row = await db.get(Message, uuid.UUID(msg["id"]))
    row.created_at = datetime(2020, 1, 1, tzinfo=timezone.utc)
    await db.commit()

    r = await client.post(f"{ADMIN}/messages/{msg['id']}/remove", headers=admin_h)
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["id"] == msg["id"] and out["deleted_at"] and out["content"] is None
    assert "abusive" not in r.text

    # Shredded exactly like the sender's delete: body and edit history gone.
    await db.refresh(row)
    assert row.content_encrypted is None and row.deleted_at is not None
    assert row.is_deleted is False
    assert (
        await db.scalars(select(MessageEdit).where(MessageEdit.message_id == row.id))
    ).all() == []

    # Same realtime event, to both members (the operator is not one).
    deleted = [(ids, d) for ev, ids, d in ws_events if ev == "message_deleted"]
    assert len(deleted) == 1
    assert set(deleted[0][0]) == {chat.alice.id, chat.bob.id}
    assert deleted[0][1]["id"] == msg["id"] and deleted[0][1]["content"] is None

    # The other member sees a tombstone.
    r = await client.get(
        f"/api/v1/conversations/{chat.conv.id}/messages", headers=chat.alice_headers
    )
    tomb = next(m for m in r.json() if m["id"] == msg["id"])
    assert tomb["deleted_at"] and tomb["content"] is None

    audits = await _audits(db, AuditAction.MESSAGE_REMOVED_BY_ADMIN)
    assert len(audits) == 1
    assert audits[0].user_id == admin.id
    assert audits[0].resource_type == "message" and audits[0].resource_id == row.id
    assert audits[0].meta == {
        "admin_id": str(admin.id),
        "sender_id": str(chat.bob.id),
        "conversation_id": str(chat.conv.id),
    }

    # Again: same answer, no second event, no second audit row.
    r = await client.post(f"{ADMIN}/messages/{msg['id']}/remove", headers=admin_h)
    assert r.status_code == 200 and r.json()["deleted_at"] == out["deleted_at"]
    assert len([e for e in ws_events if e[0] == "message_deleted"]) == 1
    assert len(await _audits(db, AuditAction.MESSAGE_REMOVED_BY_ADMIN)) == 1

    # A message the sender already deleted is equally a no-op.
    own = await _send(client, chat.conv.id, chat.bob_headers, "oops")
    assert (
        await client.delete(f"/api/v1/messages/{own['id']}", headers=chat.bob_headers)
    ).status_code == 200
    r = await client.post(f"{ADMIN}/messages/{own['id']}/remove", headers=admin_h)
    assert r.status_code == 200 and r.json()["deleted_at"]
    assert len(await _audits(db, AuditAction.MESSAGE_REMOVED_BY_ADMIN)) == 1

    r = await client.post(f"{ADMIN}/messages/{uuid.uuid4()}/remove", headers=admin_h)
    assert r.status_code == 404 and r.json()["detail"] == "message_not_found"


async def test_remove_message_respects_legal_hold(client, chat, db):
    admin, admin_h = await _super_admin(db)
    boss = await helpers.create_user(db, full_name="Dr Boss")
    await helpers.add_org_member(db, chat.org, boss, role=OrgRole.ADMIN)
    r = await client.patch(
        f"/api/v1/orgs/{chat.org.id}/policies",
        json={"legal_hold": True},
        headers=await helpers.auth_headers(boss.id),
    )
    assert r.status_code == 200, r.text
    msg = await _send(client, chat.conv.id, chat.bob_headers, "keep me v1")
    await client.patch(
        f"/api/v1/messages/{msg['id']}", json={"content": "keep me"}, headers=chat.bob_headers
    )

    r = await client.post(f"{ADMIN}/messages/{msg['id']}/remove", headers=admin_h)
    assert r.status_code == 200, r.text
    assert r.json()["deleted_at"] and r.json()["content"] is None
    # The held edit history stays in the database but is no longer served.
    assert (
        await db.scalars(
            select(MessageEdit).where(MessageEdit.message_id == uuid.UUID(msg["id"]))
        )
    ).all() != []
    r = await client.get(f"/api/v1/messages/{msg['id']}/edits", headers=chat.alice_headers)
    assert r.status_code == 200 and r.json() == []

    # Hidden from members, but the held content is still on the row.
    row = await db.get(Message, uuid.UUID(msg["id"]))
    assert row.deleted_at is not None
    assert crypto.decrypt(row.content_encrypted, row.key_version) == "keep me"
    r = await client.get(
        f"/api/v1/conversations/{chat.conv.id}/messages", headers=chat.alice_headers
    )
    tomb = next(m for m in r.json() if m["id"] == msg["id"])
    assert tomb["content"] is None and tomb["deleted_at"]
    audit = (await _audits(db, AuditAction.MESSAGE_REMOVED_BY_ADMIN))[0]
    assert audit.meta["legal_hold"] is True and audit.meta["admin_id"] == str(admin.id)


# ============================================================ report line ==


async def test_filing_a_report_logs_one_warning_without_free_text(client, chat, db, caplog):
    msg = await _send(client, chat.conv.id, chat.bob_headers, "buy my pills")
    with caplog.at_level("WARNING", logger="app.services.connection_service"):
        r = await client.post(
            "/api/v1/network/reports",
            json={
                "subject_type": "message",
                "subject_id": msg["id"],
                "reason": "spam",
                "details": "keeps posting ads",
            },
            headers=chat.alice_headers,
        )
    assert r.status_code == 201, r.text
    lines = [
        rec for rec in caplog.records if rec.getMessage().startswith("report_filed ")
    ]
    assert len(lines) == 1 and lines[0].levelname == "WARNING"
    text = lines[0].getMessage()
    report = (await db.scalars(select(Report))).one()
    assert f"id={report.id} " in text
    assert "subject_type=message" in text and "reason=spam" in text
    assert "keeps posting ads" not in text and "buy my pills" not in text
    assert "Alice" not in text and "Bob" not in text
