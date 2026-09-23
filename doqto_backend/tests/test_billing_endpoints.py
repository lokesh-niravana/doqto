"""Billing status, checkout and portal."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from tests import helpers

pytestmark = pytest.mark.asyncio


async def test_status_reports_a_running_trial(client, db):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.get("/api/v1/billing", headers=headers)

    assert r.status_code == 200
    body = r.json()
    assert body["entitled"] is True
    assert body["reason"] == "trial"
    assert body["trial_ends_at"] is not None
    assert body["plan"] is None
    # The app computes the yearly saving from these, never from typed-in copy.
    assert body["monthly_cents"] == 899
    assert body["yearly_cents"] == 8000


async def test_status_reports_an_expired_user(client, db):
    user = await helpers.create_user(db, trial_days=None)
    headers = await helpers.auth_headers(user.id)

    r = await client.get("/api/v1/billing", headers=headers)

    assert r.json()["entitled"] is False
    assert r.json()["reason"] == "expired"


async def test_checkout_returns_a_stripe_url_and_remembers_the_customer(
    client, db, stripe_gateway
):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/checkout", json={"plan": "yearly"}, headers=headers)

    assert r.status_code == 200
    assert r.json()["url"] == "https://checkout.stripe.test/session"
    assert stripe_gateway.checkouts == [
        {
            "customer_id": "cus_fake0",
            "price_id": "price_yearly",
            "user_id": str(user.id),
        }
    ]
    await db.refresh(user)
    assert user.stripe_customer_id == "cus_fake0"


async def test_checkout_reuses_the_existing_customer(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_existing"
    await db.commit()
    headers = await helpers.auth_headers(user.id)

    await client.post("/api/v1/billing/checkout", json={"plan": "monthly"}, headers=headers)

    assert stripe_gateway.customers == []
    assert stripe_gateway.checkouts[0]["customer_id"] == "cus_existing"
    assert stripe_gateway.checkouts[0]["price_id"] == "price_monthly"


async def test_checkout_refuses_an_unknown_plan(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/checkout", json={"plan": "lifetime"}, headers=headers)

    assert r.status_code == 422


async def test_checkout_sends_a_subscriber_to_the_portal_instead(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.billing_status = "active"
    await db.commit()
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/checkout", json={"plan": "monthly"}, headers=headers)

    assert r.status_code == 409
    assert r.json()["detail"] == "already_subscribed"
    assert stripe_gateway.checkouts == []


async def test_checkout_asks_stripe_before_creating_a_second_subscription(
    client, db, stripe_gateway
):
    # The webhook hasn't landed yet, so the mirror is empty — but Stripe
    # already has a live subscription for this customer.
    from app.services.stripe_client import Subscription

    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_existing"
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = Subscription(
        id="sub_1",
        customer_id="cus_existing",
        status="active",
        price_id="price_monthly",
        current_period_end=None,
    )
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/checkout", json={"plan": "monthly"}, headers=headers)

    assert r.status_code == 409
    assert r.json()["detail"] == "already_subscribed"
    assert stripe_gateway.checkouts == []


async def test_registering_starts_the_trial(client, db):
    # A Firebase sign-in creates the row without a trial; finishing
    # registration is what starts the clock.
    user = await helpers.create_user(db, full_name="", trial_days=None)
    user.npi_number = "PENDING01"
    await db.commit()
    headers = await helpers.auth_headers(user.id)

    r = await client.post(
        "/api/v1/auth/register",
        json={"full_name": "Dr New", "npi_number": "1234567890"},
        headers=headers,
    )
    assert r.status_code == 200, r.text

    body = (await client.get("/api/v1/billing", headers=headers)).json()
    assert body["entitled"] is True
    assert body["reason"] == "trial"
    trial_ends_at = datetime.fromisoformat(body["trial_ends_at"])
    assert trial_ends_at > datetime.now(timezone.utc) + timedelta(days=13)


async def test_checkout_is_503_when_stripe_is_not_configured(client, db):
    # No stripe_gateway fixture: this is production with a missing key.
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/checkout", json={"plan": "monthly"}, headers=headers)

    assert r.status_code == 503
    assert r.json()["detail"] == "billing_unavailable"


async def test_status_still_works_without_stripe(client, db):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.get("/api/v1/billing", headers=headers)

    assert r.status_code == 200
    assert r.json()["entitled"] is True


async def test_portal_returns_a_url(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_existing"
    await db.commit()
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/portal", headers=headers)

    assert r.status_code == 200
    assert r.json()["url"] == "https://portal.stripe.test/session"
    assert stripe_gateway.portals == ["cus_existing"]


async def test_portal_refuses_someone_who_never_paid(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/portal", headers=headers)

    assert r.status_code == 409
    assert r.json()["detail"] == "no_billing_account"


async def test_billing_needs_a_session(client):
    assert (await client.get("/api/v1/billing")).status_code == 401
