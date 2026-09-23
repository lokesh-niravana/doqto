"""Stripe's webhook is the only thing that may declare someone subscribed."""
from __future__ import annotations

from datetime import datetime, timezone

import pytest

from app.services.stripe_client import Subscription
from tests import helpers

pytestmark = pytest.mark.asyncio

PERIOD_START = datetime(2026, 9, 23, 12, 0, tzinfo=timezone.utc)
PERIOD_END = datetime(2026, 10, 23, 12, 0, tzinfo=timezone.utc)


def _sub(
    status: str = "active",
    price: str = "price_yearly",
    id: str = "sub_1",
    created: int = 1,
) -> Subscription:
    return Subscription(
        id=id,
        customer_id="cus_fake0",
        status=status,
        price_id=price,
        current_period_end=PERIOD_END,
        current_period_start=PERIOD_START,
        created=created,
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
    assert user.current_period_start == PERIOD_START


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


async def test_an_event_with_no_customer_touches_nobody(client, db, stripe_gateway):
    # `stripe_customer_id == None` is IS NULL: unguarded, it would pick a
    # doctor who has never paid and write someone else's subscription onto them.
    user = await helpers.create_user(db)
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = _sub()
    stripe_gateway.event = {
        "type": "customer.subscription.updated",
        "data": {"object": {"id": "sub_1"}},
    }

    r = await _post(client)

    assert r.status_code == 200
    await db.refresh(user)
    assert user.billing_status is None


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


async def test_the_live_subscription_wins_over_a_late_delete_of_the_old_one(
    client, db, stripe_gateway
):
    # A doctor ends up with two subscriptions on one customer. The old one's
    # delete event arrives after the new one is active: it must not overwrite
    # the mirror with "canceled".
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_fake0"
    await db.commit()
    stripe_gateway.subscriptions["sub_old"] = _sub(
        status="canceled", price="price_monthly", id="sub_old", created=1
    )
    stripe_gateway.subscriptions["sub_new"] = _sub(status="active", id="sub_new", created=2)

    for event_type in ("customer.subscription.updated", "customer.subscription.deleted"):
        stripe_gateway.event = {
            "type": event_type,
            "data": {"object": {"id": "sub_old", "customer": "cus_fake0"}},
        }
        assert (await _post(client)).status_code == 200

    await db.refresh(user)
    assert user.billing_status == "active"
    assert user.stripe_subscription_id == "sub_new"
    assert user.billing_plan == "yearly"


async def test_the_newest_subscription_wins_a_tie(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_fake0"
    await db.commit()
    stripe_gateway.subscriptions["sub_a"] = _sub(status="canceled", id="sub_a", created=5)
    stripe_gateway.subscriptions["sub_b"] = _sub(status="canceled", id="sub_b", created=9)
    stripe_gateway.event = {
        "type": "customer.subscription.deleted",
        "data": {"object": {"id": "sub_a", "customer": "cus_fake0"}},
    }

    await _post(client)

    await db.refresh(user)
    assert user.stripe_subscription_id == "sub_b"


async def test_a_customer_with_no_subscriptions_is_cleared(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_fake0"
    user.stripe_subscription_id = "sub_gone"
    user.billing_status = "active"
    user.billing_plan = "monthly"
    user.current_period_end = PERIOD_END
    await db.commit()
    stripe_gateway.event = {
        "type": "customer.subscription.deleted",
        "data": {"object": {"id": "sub_gone", "customer": "cus_fake0"}},
    }

    assert (await _post(client)).status_code == 200

    await db.refresh(user)
    assert user.billing_status == "canceled"
    assert user.stripe_subscription_id is None
    assert user.billing_plan is None
    assert user.current_period_end is None


async def test_the_webhook_is_503_without_a_signing_secret(
    client, db, stripe_gateway, monkeypatch
):
    from app.core.config import settings

    monkeypatch.setattr(settings, "STRIPE_WEBHOOK_SECRET", "")
    stripe_gateway.event = {"type": "invoice.paid", "data": {"object": {}}}

    r = await _post(client)

    assert r.status_code == 503
    assert r.json()["detail"] == "billing_unavailable"


async def test_a_customer_id_already_owned_by_someone_else_is_skipped(
    client, db, stripe_gateway
):
    # The unique constraint on stripe_customer_id: a 500 here would make
    # Stripe retry for three days over something a retry can't fix.
    owner = await helpers.create_user(db)
    owner.stripe_customer_id = "cus_fake0"
    await db.commit()
    other = await helpers.create_user(db)
    stripe_gateway.subscriptions["sub_1"] = _sub()
    stripe_gateway.event = {
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "client_reference_id": str(other.id),
                "customer": "cus_fake0",
                "subscription": "sub_1",
            }
        },
    }

    r = await _post(client)

    assert r.status_code == 200
    await db.refresh(other)
    assert other.stripe_customer_id is None
    assert other.billing_status is None
