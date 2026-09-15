"""Sign-in through Firebase as the identity broker.

Every provider — phone, Google, Facebook, Apple — arrives here as one Firebase
ID token. The backend verifies it, resolves it to a Doqto user, and mints its
own token pair. Firebase answers *who*; nothing downstream changes.

The google-auth verifier is stubbed: these tests are about resolution and
policy, not about Google's signature checking.
"""
from __future__ import annotations

import pytest
from sqlalchemy import func, select

from app.core.config import settings
from app.models import User
from app.services import firebase_auth
from tests import helpers


def sa_count():
    return func.count()

pytestmark = pytest.mark.asyncio

UID = "firebase-uid-abc123"


async def test_unknown_token_creates_a_pending_user(client, db, firebase):
    firebase(phone="+13125339656")

    r = await client.post("/api/v1/auth/firebase", json={"id_token": "whatever"})

    assert r.status_code == 200
    body = r.json()
    assert body["access_token"]
    assert body["is_registered"] is False

    user = await db.scalar(select(User).where(User.firebase_uid == UID))
    assert user is not None
    assert user.phone == "+13125339656"
    assert user.npi_number.startswith("PENDING")


async def test_returning_user_is_registered(client, db, firebase):
    existing = await helpers.create_user(db)
    existing.firebase_uid = UID
    await db.commit()
    firebase(phone=existing.phone)

    r = await client.post("/api/v1/auth/firebase", json={"id_token": "whatever"})

    assert r.status_code == 200
    assert r.json()["is_registered"] is True


async def test_existing_phone_user_is_adopted_not_duplicated(client, db, firebase):
    # Signed up before Firebase existed: no firebase_uid, but the phone matches.
    existing = await helpers.create_user(db)
    firebase(phone=existing.phone)

    r = await client.post("/api/v1/auth/firebase", json={"id_token": "whatever"})

    assert r.status_code == 200
    assert r.json()["is_registered"] is True
    await db.refresh(existing)
    assert existing.firebase_uid == UID
    assert await db.scalar(select(sa_count()).select_from(User)) == 1


async def test_existing_email_user_is_adopted(client, db, firebase):
    existing = await helpers.create_user(db)
    existing.email = "dr@example.com"
    await db.commit()
    # Google sign-in asserts an email and no phone.
    firebase(email="dr@example.com")

    r = await client.post("/api/v1/auth/firebase", json={"id_token": "whatever"})

    assert r.status_code == 200
    await db.refresh(existing)
    assert existing.firebase_uid == UID
    assert await db.scalar(select(sa_count()).select_from(User)) == 1


async def test_social_only_user_has_no_phone(client, db, firebase):
    firebase(email="new@example.com")

    r = await client.post("/api/v1/auth/firebase", json={"id_token": "whatever"})

    assert r.status_code == 200
    user = await db.scalar(select(User).where(User.firebase_uid == UID))
    assert user.phone is None
    assert user.email == "new@example.com"


async def test_rejected_token_is_401(client, db, firebase):
    firebase(raises=firebase_auth.FirebaseAuthError("firebase_token_invalid"))

    r = await client.post("/api/v1/auth/firebase", json={"id_token": "forged"})

    assert r.status_code == 401
    assert await db.scalar(select(sa_count()).select_from(User)) == 0


async def test_deleted_account_cannot_sign_back_in(client, db, firebase):
    # A tombstone is a HIPAA retention record — the provider account still
    # exists, but the Doqto account must stay dead.
    from datetime import datetime, timezone

    existing = await helpers.create_user(db)
    existing.firebase_uid = UID
    existing.deleted_at = datetime.now(tz=timezone.utc)
    await db.commit()
    firebase(phone=existing.phone)

    r = await client.post("/api/v1/auth/firebase", json={"id_token": "whatever"})

    assert r.status_code == 401
    assert r.json()["detail"] == "account_deleted"


async def test_verification_requires_the_project_id(monkeypatch):
    monkeypatch.setattr(settings, "FIREBASE_PROJECT_ID", "")

    with pytest.raises(RuntimeError, match="FIREBASE_PROJECT_ID"):
        firebase_auth.verify_id_token("anything")


async def test_never_logs_the_token_or_full_number(client, firebase, caplog):
    import logging

    firebase(phone="+13125339656")

    with caplog.at_level(logging.DEBUG):
        await client.post("/api/v1/auth/firebase", json={"id_token": "super-secret-token"})

    assert "super-secret-token" not in caplog.text
    assert "+13125339656" not in caplog.text


async def test_sign_in_is_rate_limited_per_ip(client, db, firebase):
    """The only unauthenticated endpoint left. A valid token still costs a DB
    write, so a flood of them must not be free."""
    from app.core.constants import RATE_LIMIT_SIGNIN_PER_HOUR

    firebase(email="flood@example.com")
    for _ in range(RATE_LIMIT_SIGNIN_PER_HOUR):
        r = await client.post("/api/v1/auth/firebase", json={"id_token": "whatever"})
        assert r.status_code == 200

    r = await client.post("/api/v1/auth/firebase", json={"id_token": "whatever"})
    assert r.status_code == 429
