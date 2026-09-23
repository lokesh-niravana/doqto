"""A single real check on the Stripe gateway module: unconfigured billing
fails loud and readable, not with a 500."""
from __future__ import annotations

import pytest
from fastapi import HTTPException

from app.core.config import settings
from app.services.stripe_client import get_stripe


def test_get_stripe_raises_503_when_unconfigured(monkeypatch):
    monkeypatch.setattr(settings, "STRIPE_SECRET_KEY", "", raising=False)

    with pytest.raises(HTTPException) as exc_info:
        get_stripe()

    assert exc_info.value.status_code == 503
    assert exc_info.value.detail == "billing_unavailable"
