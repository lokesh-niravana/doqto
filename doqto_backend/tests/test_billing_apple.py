"""In-App Purchase: the app's StoreKit transactions and Apple's notifications."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.services.apple_store import AppleTransaction
from tests import helpers

pytestmark = pytest.mark.asyncio

NOW = datetime.now(timezone.utc)


def txn(original="1000", product="com.doqto.ios.yearly", days=365, revoked=False, token=None):
    return AppleTransaction(original, product, NOW + timedelta(days=days), revoked, token)


async def test_a_verified_purchase_entitles_an_expired_doctor(
    client, db, apple_gateway, stripe_gateway
):
    user = await helpers.create_user(db, trial_days=None)
    headers = await helpers.auth_headers(user.id)
    apple_gateway.transactions["jws"] = txn(token=str(user.id))

    r = await client.post("/api/v1/billing/apple", json={"transaction": "jws"}, headers=headers)

    assert r.status_code == 200
    body = r.json()
    assert body["entitled"] is True and body["reason"] == "subscribed"
    assert body["store"] == "apple" and body["plan"] == "yearly"
    # And the Stripe checkout now refuses a second subscription.
    r = await client.post("/api/v1/billing/checkout", json={"plan": "monthly"}, headers=headers)
    assert r.status_code == 409


async def test_an_unverified_transaction_changes_nothing(client, db, apple_gateway):
    user = await helpers.create_user(db, trial_days=None)
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/apple", json={"transaction": "forged"}, headers=headers)

    assert r.status_code == 400
    await db.refresh(user)
    assert user.apple_expires_at is None


async def test_another_doctors_subscription_is_refused(client, db, apple_gateway):
    owner = await helpers.create_user(db, trial_days=None)
    other = await helpers.create_user(db, trial_days=None)
    apple_gateway.transactions["jws"] = txn()
    await client.post(
        "/api/v1/billing/apple", json={"transaction": "jws"},
        headers=await helpers.auth_headers(owner.id),
    )

    r = await client.post(
        "/api/v1/billing/apple", json={"transaction": "jws"},
        headers=await helpers.auth_headers(other.id),
    )
    assert r.status_code == 409
    # Bought under someone else's account token, too.
    apple_gateway.transactions["tok"] = txn(original="2000", token=str(owner.id))
    r = await client.post(
        "/api/v1/billing/apple", json={"transaction": "tok"},
        headers=await helpers.auth_headers(other.id),
    )
    assert r.status_code == 409


async def test_notifications_renew_and_refund(client, db, apple_gateway):
    user = await helpers.create_user(db, trial_days=None)
    headers = await helpers.auth_headers(user.id)
    apple_gateway.transactions["buy"] = txn(days=30, product="com.doqto.ios.monthly")
    await client.post("/api/v1/billing/apple", json={"transaction": "buy"}, headers=headers)

    # A renewal moves the expiry on; a replayed old one can't pull it back.
    apple_gateway.transactions["renew"] = txn(days=60)
    apple_gateway.transactions["old"] = txn(days=1)
    for payload in ("renew", "old"):
        r = await client.post("/api/v1/billing/apple/notifications", json={"signedPayload": payload})
        assert r.status_code == 200
    await db.refresh(user)
    assert user.apple_expires_at.date() == (NOW + timedelta(days=60)).date()

    apple_gateway.transactions["refund"] = txn(days=60, revoked=True)
    await client.post("/api/v1/billing/apple/notifications", json={"signedPayload": "refund"})
    await db.refresh(user)
    assert user.apple_expires_at is None


async def test_a_notification_finds_the_doctor_by_account_token(client, db, apple_gateway):
    user = await helpers.create_user(db, trial_days=None)
    apple_gateway.transactions["n"] = txn(token=str(user.id))

    await client.post("/api/v1/billing/apple/notifications", json={"signedPayload": "n"})

    await db.refresh(user)
    assert user.apple_expires_at is not None


async def test_bad_or_unknown_notifications(client, db, apple_gateway):
    r = await client.post("/api/v1/billing/apple/notifications", json={"signedPayload": "x"})
    assert r.status_code == 400
    apple_gateway.transactions["stray"] = txn(original="9999")
    r = await client.post("/api/v1/billing/apple/notifications", json={"signedPayload": "stray"})
    assert r.status_code == 200
