"""A single real check on the Stripe gateway module: unconfigured billing
fails loud and readable, not with a 500."""
from __future__ import annotations

import uuid

import pytest
from fastapi import HTTPException

from app.core.config import settings
from app.models import User
from app.services.stripe_client import StripeGateway, get_stripe


def test_get_stripe_raises_503_when_unconfigured(monkeypatch):
    monkeypatch.setattr(settings, "STRIPE_SECRET_KEY", "", raising=False)

    with pytest.raises(HTTPException) as exc_info:
        get_stripe()

    assert exc_info.value.status_code == 503
    assert exc_info.value.detail == "billing_unavailable"


def test_ensure_customer_sends_an_idempotency_key_keyed_on_the_user(monkeypatch):
    """Two concurrent checkout requests for the same customer-less user both
    pass the in-memory `user.stripe_customer_id` guard in the endpoint and
    both reach here. Without an idempotency key, Stripe would create two
    customers and only one id would ever get persisted."""
    gateway = StripeGateway("sk_test_dummy")
    user = User(id=uuid.uuid4(), email="doc@example.com", full_name="Dr Test", npi_number="1234567890")

    calls = []

    def _fake_create(params=None, options=None):
        calls.append({"params": params, "options": options})

        class _Customer:
            id = "cus_new"

        return _Customer()

    monkeypatch.setattr(gateway._client.customers, "create", _fake_create)

    customer_id = gateway.ensure_customer(user)

    assert customer_id == "cus_new"
    assert len(calls) == 1
    idempotency_key = calls[0]["options"]["idempotency_key"]
    assert str(user.id) in idempotency_key


def test_the_portal_returns_to_a_neutral_page(monkeypatch):
    # Not ?status=success: the doctor may only have looked at an invoice.
    gateway = StripeGateway("sk_test_dummy")
    calls = []

    def _fake_create(params=None, options=None):
        calls.append(params)

        class _Session:
            url = "https://portal.stripe.test/session"

        return _Session()

    monkeypatch.setattr(gateway._client.billing_portal.sessions, "create", _fake_create)

    gateway.portal_url("cus_1")

    assert calls[0]["return_url"] == f"{settings.BILLING_RETURN_URL}?status=portal"


def test_list_subscriptions_reads_the_period_from_the_item_when_needed(monkeypatch):
    # Newer API versions moved both period fields onto the subscription item.
    import stripe

    gateway = StripeGateway("sk_test_dummy")
    sub = stripe.StripeObject.construct_from(
        {
            "id": "sub_1",
            "customer": "cus_1",
            "status": "past_due",
            "created": 100,
            "items": {
                "data": [
                    {
                        "price": {"id": "price_monthly"},
                        "current_period_start": 1_000,
                        "current_period_end": 2_000,
                    }
                ]
            },
        },
        "sk_test_dummy",
    )
    calls = []

    def _fake_list(params=None, options=None):
        calls.append(params)
        return stripe.StripeObject.construct_from({"data": [sub]}, "sk_test_dummy")

    monkeypatch.setattr(gateway._client.subscriptions, "list", _fake_list)

    [result] = gateway.list_subscriptions("cus_1")

    assert calls[0]["customer"] == "cus_1"
    assert calls[0]["status"] == "all"
    assert result.status == "past_due"
    assert result.created == 100
    assert result.current_period_start.timestamp() == 1_000
    assert result.current_period_end.timestamp() == 2_000
