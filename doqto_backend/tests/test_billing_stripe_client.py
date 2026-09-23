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
