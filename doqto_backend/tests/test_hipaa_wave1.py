"""HIPAA remediation Wave 1 — C1/C2/C4/C5 regression tests.

- C5: CONVERSATION_ACCESSED audit row (with IP) on message reads.
- C2: non-local OTP path never logs the code or full phone.
- C4: startup guard refuses placeholder/malformed secrets outside local.
- C1: WS envelopes are encrypted before transiting Redis pub/sub.
"""
from __future__ import annotations

import base64
import json
import os

import pytest
from sqlalchemy import select

from app.api.ws_manager import decode_envelope, encode_envelope
from app.core.config import Settings, settings
from app.core.enums import AuditAction
from app.models import AuditLog
from main import verify_boot_secrets


# ---------------------------------------------------------------- C5: audit

async def test_list_messages_writes_conversation_accessed_audit(chat, client, db):
    r = await client.get(
        f"/api/v1/conversations/{chat.conv.id}/messages", headers=chat.alice_headers
    )
    assert r.status_code == 200

    row = await db.scalar(
        select(AuditLog).where(
            AuditLog.action == AuditAction.CONVERSATION_ACCESSED.value
        )
    )
    assert row is not None
    assert row.user_id == chat.alice.id
    assert row.resource_type == "conversation"
    assert row.resource_id == chat.conv.id
    assert row.ip_address is not None  # populated from the request
    assert "127.0.0.1" in str(row.ip_address)


async def test_mark_conversation_read_is_audited(chat, client, db):
    r = await client.post(
        f"/api/v1/conversations/{chat.conv.id}/read", headers=chat.bob_headers
    )
    assert r.status_code == 200
    row = await db.scalar(
        select(AuditLog).where(
            AuditLog.action == AuditAction.MESSAGE_READ.value,
            AuditLog.resource_id == chat.conv.id,
        )
    )
    assert row is not None
    assert row.user_id == chat.bob.id


# --------------------------------------------- C2: sign-in logs
# Firebase brokers sign-in now; the no-code-no-phone-in-logs guarantee is
# asserted in test_firebase_auth.test_never_logs_the_token_or_full_number.


async def test_transcribe_stub_refuses_non_local(monkeypatch):
    from app.services.transcription_service import _transcribe

    monkeypatch.setattr(settings, "ENVIRONMENT", "production")
    with pytest.raises(RuntimeError):
        _transcribe()


# --------------------------------------------------------- C4: boot guard

def _settings(**overrides) -> Settings:
    base = dict(
        ENVIRONMENT="production",
        DATABASE_URL="postgresql+asyncpg://x:x@localhost/x",
        REDIS_URL="redis://:x@localhost:6379/0",
        JWT_SECRET="a" * 64,
        MESSAGE_ENCRYPTION_KEY=base64.b64encode(os.urandom(32)).decode(),
    )
    base.update(overrides)
    return Settings(**base)


def test_boot_guard_rejects_placeholder_jwt_secret():
    with pytest.raises(RuntimeError):
        verify_boot_secrets(_settings(JWT_SECRET="change-me-in-prod-256-bit-random"))


def test_boot_guard_rejects_placeholder_encryption_key():
    with pytest.raises(RuntimeError):
        verify_boot_secrets(
            _settings(MESSAGE_ENCRYPTION_KEY="change-me-base64-32-bytes-from-kms")
        )


def test_boot_guard_rejects_short_encryption_key():
    with pytest.raises(RuntimeError):
        verify_boot_secrets(
            _settings(MESSAGE_ENCRYPTION_KEY=base64.b64encode(os.urandom(16)).decode())
        )


def test_boot_guard_accepts_real_secrets_and_local_placeholders():
    verify_boot_secrets(_settings())  # real secrets, production: fine
    verify_boot_secrets(
        _settings(ENVIRONMENT="local", JWT_SECRET="change-me-x")
    )  # local: anything goes


# ----------------------------------------------------- C1: WS encryption

def test_ws_envelope_round_trips_and_hides_plaintext():
    envelope = {
        "org_id": "8e6c2a54-0000-0000-0000-000000000000",
        "type": "new_message",
        "data": {"content": "patient BP is 180/110 — call me"},
        "recipients": None,
    }
    wire = encode_envelope(envelope)
    assert "patient" not in wire
    assert "180/110" not in wire
    assert decode_envelope(wire) == envelope


def test_ws_decode_rejects_plaintext_json():
    plaintext = base64.b64encode(json.dumps({"org_id": "x"}).encode()).decode()
    with pytest.raises(Exception):
        decode_envelope(plaintext)
