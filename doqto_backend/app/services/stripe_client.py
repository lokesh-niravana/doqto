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
    current_period_start: datetime | None = None
    created: int = 0  # unix seconds; breaks ties between two subscriptions


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
        # Idempotency key keyed on user id: two concurrent checkout requests
        # from the same customer-less user both pass the in-memory guard
        # above, but Stripe collapses duplicate creates within its
        # idempotency window into the same customer instead of orphaning one.
        customer = self._client.customers.create(
            params={"email": user.email or None, "metadata": {"user_id": str(user.id)}},
            options={"idempotency_key": f"doqto-customer-{user.id}"},
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
            params={
                "customer": customer_id,
                "return_url": f"{settings.BILLING_RETURN_URL}?status=portal",
            }
        )
        return session.url

    def list_subscriptions(self, customer_id: str) -> list[Subscription]:
        """Every subscription the customer has, in any state. Nobody holds
        more than a handful, so one page is all of them."""
        page = self._client.subscriptions.list(
            params={"customer": customer_id, "status": "all", "limit": 100}
        )
        return [self._to_subscription(sub) for sub in page.data]

    def cancel_subscription(self, subscription_id: str) -> None:
        """Immediately, not at period end: the account is going away."""
        self._client.subscriptions.cancel(subscription_id)

    @staticmethod
    def _to_subscription(sub) -> Subscription:
        items = sub["items"]["data"]

        # The period fields live on the subscription itself in older API
        # versions; newer ones moved them onto each subscription item instead.
        # Read them from the subscription when present, else fall back to the
        # first item, so this keeps working across API version bumps.
        def period(field: str) -> datetime | None:
            value = sub.get(field)
            if value is None and items:
                value = items[0].get(field)
            return datetime.fromtimestamp(value, tz=timezone.utc) if value else None

        return Subscription(
            id=sub.id,
            customer_id=str(sub.customer),
            status=sub.status,
            price_id=items[0]["price"]["id"] if items else None,
            current_period_end=period("current_period_end"),
            current_period_start=period("current_period_start"),
            created=sub.get("created") or 0,
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


def get_optional_stripe() -> StripeGateway | None:
    """For work that must go ahead with or without billing, like deleting an
    account: None instead of a 503 when Stripe isn't configured."""
    try:
        return get_stripe()
    except HTTPException:
        return None
