"""Stripe's webhook is the only thing that may declare someone subscribed."""
from __future__ import annotations

from datetime import datetime, timezone

import pytest

from app.services.stripe_client import Subscription
from tests import helpers

pytestmark = pytest.mark.asyncio

PERIOD_END = datetime(2026, 10, 23, 12, 0, tzinfo=timezone.utc)


def _sub(status: str = "active", price: str = "price_yearly") -> Subscription:
    return Subscription(
        id="sub_1",
        customer_id="cus_fake0",
        status=status,
        price_id=price,
        current_period_end=PERIOD_END,
    )


async def _post(client) -> object:
    return await client.post(
        "/api/v1/billing/webhook",
        content=b"{}",
        headers={"stripe-signature": "t=1,v1=whatever"},
    )


async def test_checkout_completed_subscribes_the_user(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    stripe_gateway.subscriptions["sub_1"] = _sub()
    stripe_gateway.event = {
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "client_reference_id": str(user.id),
                "customer": "cus_fake0",
                "subscription": "sub_1",
            }
        },
    }

    r = await _post(client)

    assert r.status_code == 200
    await db.refresh(user)
    assert user.billing_status == "active"
    assert user.billing_plan == "yearly"
    assert user.stripe_subscription_id == "sub_1"
    assert user.stripe_customer_id == "cus_fake0"
    assert user.current_period_end == PERIOD_END


async def test_subscription_updated_is_matched_by_customer(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_fake0"
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = _sub(status="past_due", price="price_monthly")
    stripe_gateway.event = {
        "type": "customer.subscription.updated",
        "data": {"object": {"id": "sub_1", "customer": "cus_fake0"}},
    }

    await _post(client)

    await db.refresh(user)
    assert user.billing_status == "past_due"
    assert user.billing_plan == "monthly"


async def test_a_stale_event_cannot_resurrect_a_cancelled_subscription(
    client, db, stripe_gateway
):
    # Stripe promises neither order nor exactly-once delivery. The handler
    # re-fetches, so whatever the event says, the truth wins.
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_fake0"
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = _sub(status="canceled")
    stripe_gateway.event = {
        "type": "customer.subscription.updated",
        "data": {"object": {"id": "sub_1", "customer": "cus_fake0"}},
    }

    await _post(client)
    await _post(client)  # delivered twice, as Stripe does on retry

    await db.refresh(user)
    assert user.billing_status == "canceled"


async def test_a_forged_signature_is_refused(client, db, stripe_gateway):
    stripe_gateway.signature_valid = False

    r = await _post(client)

    assert r.status_code == 400


async def test_an_unknown_customer_is_accepted_and_ignored(client, db, stripe_gateway):
    stripe_gateway.subscriptions["sub_1"] = _sub()
    stripe_gateway.event = {
        "type": "customer.subscription.updated",
        "data": {"object": {"id": "sub_1", "customer": "cus_nobody"}},
    }

    r = await _post(client)

    # 200, or Stripe retries this for three days over a user we don't have.
    assert r.status_code == 200


async def test_an_uninteresting_event_is_ignored(client, db, stripe_gateway):
    stripe_gateway.event = {"type": "invoice.paid", "data": {"object": {}}}

    assert (await _post(client)).status_code == 200


async def test_checkout_completed_with_no_reference_falls_back_to_customer(
    client, db, stripe_gateway
):
    # client_reference_id can be missing (e.g. session started elsewhere), or
    # not a valid UUID. Fall back to matching on the Stripe customer id.
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_fake0"
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = _sub()
    stripe_gateway.event = {
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "customer": "cus_fake0",
                "subscription": "sub_1",
            }
        },
    }

    r = await _post(client)

    assert r.status_code == 200
    await db.refresh(user)
    assert user.billing_status == "active"
    assert user.billing_plan == "yearly"
    assert user.stripe_subscription_id == "sub_1"
