"""HIPAA remediation Wave 2 — H6/H7/H5b/H8 + M1-M5, M9 regression tests.

- H6: S3 put_object always sets SSE; delete_object disposal path works.
- H7: purge_content crypto-shreds deleted/expired messages past the grace
  period and returns their S3 keys.
- H5b/M5: access-jti session TTL = access TTL; refresh keeps its own key/TTL.
- H8: org member list is minimum-necessary (no phone/email/NPI).
- M1: WS `?token=` query fallback is gone — auth frame only.
- M2: OTP audit metadata stores a masked phone.
- M3: conversation member management authz + cross-org validation.
- M4: admin login rate limit (5 attempts / window per email).
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import app.db.redis as redis_mod
import app.services.s3_client as s3_client_mod
from app.core.constants import (
    ACCESS_TOKEN_TTL_SECONDS,
    ADMIN_LOGIN_MAX_ATTEMPTS,
    REFRESH_TOKEN_TTL_SECONDS,
)
from app.core.enums import AuditAction, ConversationType, JwtTokenType, MessageType, OrgRole, TranscriptStatus
from app.core.redis_keys import refresh_session_key, session_key
from app.core.security import decode_token, encrypt_message
from app.db.redis import get_redis
from app.models import AuditLog, Message
from app.services.file_service import FileService
from app.services.message_service import MessageService
from app.services.s3_client import RealS3Client
from main import app
from tests import helpers


# ------------------------------------------------------------------ H6: S3

class _RecorderS3:
    def __init__(self):
        self.put_calls: list[dict] = []
        self.deleted: list[str] = []

    def put_object(self, **kwargs):
        self.put_calls.append(kwargs)

    def delete_object(self, *, Bucket: str, Key: str):
        self.deleted.append(Key)


@pytest.fixture
def fake_s3(monkeypatch):
    rec = _RecorderS3()
    # _get_client() returns the module global when set — no boto3, no bucket check.
    monkeypatch.setattr(s3_client_mod, "_client", rec)
    return rec


async def test_put_object_sets_server_side_encryption(fake_s3):
    await RealS3Client().upload_bytes(key="files/x/y/z.pdf", data=b"phi", content_type="application/pdf")
    assert len(fake_s3.put_calls) == 1
    assert fake_s3.put_calls[0]["ServerSideEncryption"] == "AES256"
    assert fake_s3.put_calls[0]["Key"] == "files/x/y/z.pdf"


async def test_file_service_delete_object_reaches_s3(fake_s3):
    await FileService.delete_object(key="avatars/u/a.png")
    assert fake_s3.deleted == ["avatars/u/a.png"]


# --------------------------------------------------------------- H7: purge

async def test_purge_content_shreds_old_deleted_and_expired(chat, db):
    now = datetime.now(tz=timezone.utc)
    old = now - timedelta(days=31)

    def _msg(seq: int, **kw) -> Message:
        return Message(
            conversation_id=chat.conv.id,
            sender_id=chat.alice.id,
            type=MessageType.TEXT,
            seq=seq,
            transcript_status=TranscriptStatus.NONE,
            **kw,
        )

    shred_deleted = _msg(
        1, is_deleted=True, created_at=old,
        content_encrypted=encrypt_message("old deleted"), s3_key="files/o/1/a.pdf",
    )
    shred_expired = _msg(
        2, is_deleted=True, created_at=now, expires_at=old,
        transcript_encrypted=encrypt_message("old transcript"), s3_key="voice-notes/o/2.m4a",
    )
    keep_recent_deleted = _msg(
        3, is_deleted=True, created_at=now - timedelta(days=1),
        content_encrypted=encrypt_message("recently deleted"),
    )
    keep_live = _msg(4, created_at=old, content_encrypted=encrypt_message("live"))
    db.add_all([shred_deleted, shred_expired, keep_recent_deleted, keep_live])
    await db.commit()

    keys = await MessageService.purge_content(db)
    await db.commit()

    assert sorted(keys) == ["files/o/1/a.pdf", "voice-notes/o/2.m4a"]
    for m in (shred_deleted, shred_expired, keep_recent_deleted, keep_live):
        await db.refresh(m)
    assert shred_deleted.content_encrypted is None and shred_deleted.s3_key is None
    assert shred_expired.transcript_encrypted is None and shred_expired.s3_key is None
    # rows survive (seq ordering) …
    assert shred_deleted.seq == 1
    # … and untouched messages keep their content.
    assert keep_recent_deleted.content_encrypted is not None
    assert keep_live.content_encrypted is not None

    # to_out renders a shredded row without blowing up.
    out = MessageService.to_out(shred_deleted)
    assert out.content is None

    # Idempotent: second pass finds nothing.
    assert await MessageService.purge_content(db) == []


# ------------------------------------------------- H5b/M5: session TTLs

async def test_login_sets_split_session_ttls_and_refresh_works(client, firebase):
    firebase(phone="+15551230001")
    r = await client.post("/api/v1/auth/firebase", json={"id_token": "stub"})
    assert r.status_code == 200
    pair = r.json()
    jti = decode_token(pair["access_token"], JwtTokenType.ACCESS)["jti"]

    redis = await get_redis()
    access_ttl = await redis.ttl(session_key(jti))
    refresh_ttl = await redis.ttl(refresh_session_key(jti))
    assert 0 < access_ttl <= ACCESS_TOKEN_TTL_SECONDS
    assert access_ttl > ACCESS_TOKEN_TTL_SECONDS - 120
    assert refresh_ttl > ACCESS_TOKEN_TTL_SECONDS  # ≈ 7 days
    assert refresh_ttl <= REFRESH_TOKEN_TTL_SECONDS

    # Refresh rotation still works and re-splits the TTLs.
    r2 = await client.post(
        "/api/v1/auth/refresh", json={"refresh_token": pair["refresh_token"]}
    )
    assert r2.status_code == 200
    new_jti = decode_token(r2.json()["access_token"], JwtTokenType.ACCESS)["jti"]
    assert await redis.ttl(session_key(new_jti)) <= ACCESS_TOKEN_TTL_SECONDS
    assert await redis.ttl(refresh_session_key(new_jti)) > ACCESS_TOKEN_TTL_SECONDS
    # Old pair fully revoked.
    assert not await redis.exists(session_key(jti))
    assert not await redis.exists(refresh_session_key(jti))


# ------------------------------------------------------- H8: MemberOut

async def test_member_list_has_no_phone_email_npi(chat, client):
    r = await client.get(f"/api/v1/orgs/{chat.org.id}/members", headers=chat.alice_headers)
    assert r.status_code == 200
    members = r.json()
    assert len(members) == 2
    for m in members:
        assert "phone" not in m and "email" not in m and "npi_number" not in m
        assert "user" not in m  # no nested full UserOut either
        assert m["full_name"]
        assert "org_role" in m and "id" in m


# --------------------------------------------------- M1: WS auth frame only

async def test_ws_query_token_is_ignored_and_rejected(db):
    org = await helpers.create_org(db)
    user = await helpers.create_user(db, full_name="Dr Socket")
    await helpers.add_org_member(db, org, user)
    token = helpers.access_token(user.id)
    redis_mod._redis = None  # portal thread gets its own client
    try:
        client = TestClient(app)
        with client.websocket_connect(f"/ws/{org.id}?token={token}") as ws:
            # Query token is never read; first frame must be auth — this isn't.
            ws.send_json({"type": "heartbeat"})
            with pytest.raises(WebSocketDisconnect):
                ws.receive_json()
    finally:
        redis_mod._redis = None


# ------------------------------------------------- M2: sign-in audit carries no phone

async def test_signin_audit_row_holds_no_phone_number(client, db, firebase):
    """Firebase owns the phone number now, so the audit row has no reason to
    repeat it — minimum necessary. (Account deletion still records a masked
    last-4; see test_account_deletion.)"""
    phone = "+15559990001"
    firebase(phone=phone)
    r = await client.post("/api/v1/auth/firebase", json={"id_token": "stub"})
    assert r.status_code == 200
    row = await db.scalar(
        select(AuditLog).where(AuditLog.action == AuditAction.OTP_VERIFIED.value)
    )
    assert row is not None
    assert phone not in str(row.meta)
    assert phone[-4:] not in str(row.meta)


# ------------------------------------- M3: member management authz

@pytest.fixture
async def group(db):
    """Group conversation: alice (org admin), bob + carol (doctors), plus a
    same-org non-member dana and an outsider in a different org."""
    from types import SimpleNamespace

    org = await helpers.create_org(db)
    alice = await helpers.create_user(db, full_name="Dr Alice")
    bob = await helpers.create_user(db, full_name="Dr Bob")
    carol = await helpers.create_user(db, full_name="Dr Carol")
    dana = await helpers.create_user(db, full_name="Dr Dana")
    await helpers.add_org_member(db, org, alice, role=OrgRole.ADMIN)
    await helpers.add_org_member(db, org, bob)
    await helpers.add_org_member(db, org, carol)
    await helpers.add_org_member(db, org, dana)
    other_org = await helpers.create_org(db, name="Other Clinic")
    outsider = await helpers.create_user(db, full_name="Dr Outsider")
    await helpers.add_org_member(db, other_org, outsider)
    conv = await helpers.create_conversation(
        db, org, [alice, bob, carol], conv_type=ConversationType.GROUP, name="Team"
    )
    return SimpleNamespace(
        org=org, conv=conv, alice=alice, bob=bob, carol=carol, dana=dana,
        outsider=outsider,
        alice_headers=await helpers.auth_headers(alice.id),
        bob_headers=await helpers.auth_headers(bob.id),
    )


async def test_add_cross_org_member_rejected(group, client):
    r = await client.patch(
        f"/api/v1/conversations/{group.conv.id}/members",
        json={"user_ids": [str(group.outsider.id)]},
        headers=group.alice_headers,
    )
    assert r.status_code == 400
    assert r.json()["detail"] == "member_not_in_org"


async def test_create_conversation_with_cross_org_stranger_is_denied(group, client):
    """A cross-org stranger (no shared org, not connected) can't be messaged:
    403 not_connected. Connect first, then chat — no request tier."""
    r = await client.post(
        "/api/v1/conversations",
        json={"type": "direct", "member_ids": [str(group.outsider.id)]},
        headers=group.alice_headers,
    )
    assert r.status_code == 403, r.text
    assert r.json()["detail"] == "not_connected"


async def test_same_org_member_add_still_works(group, client):
    r = await client.patch(
        f"/api/v1/conversations/{group.conv.id}/members",
        json={"user_ids": [str(group.dana.id)]},
        headers=group.bob_headers,
    )
    assert r.status_code == 200


async def test_non_admin_cannot_remove_others_but_can_leave(group, client):
    r = await client.delete(
        f"/api/v1/conversations/{group.conv.id}/members/{group.carol.id}",
        headers=group.bob_headers,
    )
    assert r.status_code == 403
    assert r.json()["detail"] == "not_authorized"

    r = await client.delete(
        f"/api/v1/conversations/{group.conv.id}/members/{group.bob.id}",
        headers=group.bob_headers,
    )
    assert r.status_code == 200


async def test_org_admin_can_remove_member(group, client):
    r = await client.delete(
        f"/api/v1/conversations/{group.conv.id}/members/{group.carol.id}",
        headers=group.alice_headers,
    )
    assert r.status_code == 200


# ------------------------------------------- M4: admin login rate limit

async def test_admin_login_rate_limited_after_max_attempts(client):
    body = {"email": "nobody@example.com", "password": "wrong"}
    for _ in range(ADMIN_LOGIN_MAX_ATTEMPTS):
        r = await client.post("/api/v1/admin/auth/login", json=body)
        assert r.status_code == 401
    r = await client.post("/api/v1/admin/auth/login", json=body)
    assert r.status_code == 429
    assert r.json()["detail"] == "rate_limited"
