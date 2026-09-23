"""The only module that imports `stripe`.

Everything else speaks in our own small types, which keeps Stripe out of the
API layer and makes the whole billing surface testable with a fake.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import NamedTuple

import stripe
from fastapi import HTTPException, status

from app.core.config import settings
from app.models import User


class Subscription(NamedTuple):
    id: str
    customer_id: str
    status: str
    price_id: str | None
    current_period_end: datetime | None


class StripeGateway:
    """Thin, synchronous wrapper. Calls are short; FastAPI runs the endpoints
    that use it in a threadpool via `run_in_threadpool`."""

    def __init__(self, api_key: str) -> None:
        self._client = stripe.StripeClient(api_key)

    def ensure_customer(self, user: User) -> str:
        if user.stripe_customer_id:
            return user.stripe_customer_id
        # metadata carries our id so a webhook can find the user even when the
        # checkout session is long gone. Email is the only personal field we
        # send, and only so receipts reach the doctor.
        customer = self._client.customers.create(
            params={"email": user.email or None, "metadata": {"user_id": str(user.id)}}
        )
        return customer.id

    def checkout_url(self, *, customer_id: str, price_id: str, user_id: str) -> str:
        session = self._client.checkout.sessions.create(
            params={
                "mode": "subscription",
                "customer": customer_id,
                "line_items": [{"price": price_id, "quantity": 1}],
                "client_reference_id": user_id,
                "success_url": f"{settings.BILLING_RETURN_URL}?status=success",
                "cancel_url": f"{settings.BILLING_RETURN_URL}?status=cancel",
                "allow_promotion_codes": True,
            }
        )
        return session.url

    def portal_url(self, customer_id: str) -> str:
        session = self._client.billing_portal.sessions.create(
            params={"customer": customer_id, "return_url": settings.BILLING_RETURN_URL}
        )
        return session.url

    def subscription(self, subscription_id: str) -> Subscription:
        sub = self._client.subscriptions.retrieve(subscription_id)
        items = sub["items"]["data"]
        # `current_period_end` lives on the subscription itself in older API
        # versions; newer ones moved it onto each subscription item instead.
        # Read it from the subscription when present, else fall back to the
        # first item, so this keeps working across API version bumps.
        period_end = sub.get("current_period_end")
        if period_end is None and items:
            period_end = items[0].get("current_period_end")
        return Subscription(
            id=sub.id,
            customer_id=str(sub.customer),
            status=sub.status,
            price_id=items[0]["price"]["id"] if items else None,
            current_period_end=(
                datetime.fromtimestamp(period_end, tz=timezone.utc) if period_end else None
            ),
        )

    def construct_event(self, payload: bytes, signature: str) -> dict:
        """Raises stripe.SignatureVerificationError on a forged request."""
        return stripe.Webhook.construct_event(
            payload, signature, settings.STRIPE_WEBHOOK_SECRET
        )


_gateway: StripeGateway | None = None


def get_stripe() -> StripeGateway:
    """FastAPI dependency. 503 rather than 500 when Stripe isn't configured:
    that is a deployment problem, and the app shows a readable message."""
    global _gateway
    if not settings.STRIPE_SECRET_KEY:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, detail="billing_unavailable"
        )
    if _gateway is None:
        _gateway = StripeGateway(settings.STRIPE_SECRET_KEY)
    return _gateway
