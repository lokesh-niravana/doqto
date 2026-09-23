"""Subscription status, checkout and the customer portal.

The app never talks to Stripe. It asks here, and opens whatever URL we hand
back in an external browser — which is also what Apple's link-out rule
requires.
"""
from __future__ import annotations

import logging
import uuid

import stripe
from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.concurrency import run_in_threadpool
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.dependencies import get_current_user, get_db
from app.core.routes import ApiRoutes
from app.models import User
from app.schemas.billing import BillingOut, CheckoutIn, UrlOut
from app.services.billing_service import entitlement
from app.services.stripe_client import StripeGateway, Subscription, get_stripe

logger = logging.getLogger(__name__)
router = APIRouter()

# Statuses that mean "already paying, or recoverable" — sending these users
# through checkout again would create a second subscription.
SUBSCRIBED_STATUSES = frozenset({"active", "trialing", "past_due"})


def _billing_out(user: User) -> BillingOut:
    decision = entitlement(user)
    return BillingOut(
        entitled=decision.entitled,
        reason=decision.reason,
        trial_ends_at=user.trial_ends_at,
        plan=user.billing_plan,
        status=user.billing_status,
        current_period_end=user.current_period_end,
        monthly_cents=settings.BILLING_PRICE_MONTHLY_CENTS,
        yearly_cents=settings.BILLING_PRICE_YEARLY_CENTS,
    )


@router.get(ApiRoutes.BILLING_STATUS, response_model=BillingOut)
async def billing_status(user: User = Depends(get_current_user)) -> BillingOut:
    return _billing_out(user)


@router.post(ApiRoutes.BILLING_CHECKOUT, response_model=UrlOut)
async def create_checkout(
    body: CheckoutIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    stripe: StripeGateway = Depends(get_stripe),
) -> UrlOut:
    if user.billing_status in SUBSCRIBED_STATUSES:
        raise HTTPException(status.HTTP_409_CONFLICT, detail="already_subscribed")

    price_id = (
        settings.STRIPE_PRICE_MONTHLY
        if body.plan == "monthly"
        else settings.STRIPE_PRICE_YEARLY
    )
    if not price_id:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, detail="billing_unavailable"
        )

    # The mirror lags the webhook by seconds. Ask Stripe too, or a double tap
    # on Subscribe during that window buys a second subscription.
    if user.stripe_customer_id:
        existing = await run_in_threadpool(
            stripe.list_subscriptions, user.stripe_customer_id
        )
        if any(sub.status in SUBSCRIBED_STATUSES for sub in existing):
            raise HTTPException(status.HTTP_409_CONFLICT, detail="already_subscribed")

    customer_id = await run_in_threadpool(stripe.ensure_customer, user)
    if user.stripe_customer_id != customer_id:
        user.stripe_customer_id = customer_id
        await db.commit()

    url = await run_in_threadpool(
        lambda: stripe.checkout_url(
            customer_id=customer_id, price_id=price_id, user_id=str(user.id)
        )
    )
    logger.info("billing checkout user=%s plan=%s", user.id, body.plan)
    return UrlOut(url=url)


@router.post(ApiRoutes.BILLING_PORTAL, response_model=UrlOut)
async def create_portal(
    user: User = Depends(get_current_user),
    stripe: StripeGateway = Depends(get_stripe),
) -> UrlOut:
    if not user.stripe_customer_id:
        raise HTTPException(status.HTTP_409_CONFLICT, detail="no_billing_account")
    url = await run_in_threadpool(stripe.portal_url, user.stripe_customer_id)
    return UrlOut(url=url)


SUBSCRIPTION_EVENTS = frozenset(
    {
        "customer.subscription.created",
        "customer.subscription.updated",
        "customer.subscription.deleted",
    }
)


def _plan_for(price_id: str | None) -> str | None:
    if price_id and price_id == settings.STRIPE_PRICE_MONTHLY:
        return "monthly"
    if price_id and price_id == settings.STRIPE_PRICE_YEARLY:
        return "yearly"
    return None


# Which subscription speaks for a customer who has more than one: a paying
# one first, then the newest.
_STATUS_RANK = {"active": 0, "trialing": 1, "past_due": 2}


def _best(subs: list[Subscription]) -> Subscription | None:
    if not subs:
        return None
    return min(subs, key=lambda s: (_STATUS_RANK.get(s.status, 3), -s.created))


@router.post(ApiRoutes.BILLING_WEBHOOK)
async def webhook(
    request: Request,
    db: AsyncSession = Depends(get_db),
    stripe_gateway: StripeGateway = Depends(get_stripe),
) -> dict[str, bool]:
    if not settings.STRIPE_WEBHOOK_SECRET:
        # Without the secret nothing can be verified; 503 so Stripe retries
        # once the deployment is fixed, instead of a 400 for every event.
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, detail="billing_unavailable"
        )
    payload = await request.body()
    signature = request.headers.get("stripe-signature", "")
    try:
        event = stripe_gateway.construct_event(payload, signature)
    except (stripe.SignatureVerificationError, ValueError):
        # Never log the payload or the signature header: both are unverified
        # input, and the header is effectively a credential.
        logger.warning("billing webhook rejected: bad signature")
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="bad_signature")

    event_type = event.get("type", "")
    obj = event.get("data", {}).get("object", {})

    if event_type == "checkout.session.completed":
        user = None
        reference = obj.get("client_reference_id")
        if reference:
            try:
                reference_id = uuid.UUID(reference)
            except ValueError:
                reference_id = None
            if reference_id is not None:
                user = await db.scalar(select(User).where(User.id == reference_id))
        if user is None and obj.get("customer"):
            user = await db.scalar(
                select(User).where(User.stripe_customer_id == obj.get("customer"))
            )
    elif event_type in SUBSCRIPTION_EVENTS:
        # Guarded: `== None` would be IS NULL and match an arbitrary user.
        user = None
        if obj.get("customer"):
            user = await db.scalar(
                select(User).where(User.stripe_customer_id == obj.get("customer"))
            )
    else:
        return {"ok": True}

    customer_id = obj.get("customer") or (user.stripe_customer_id if user else None)
    if user is None or not customer_id:
        # 200 anyway: Stripe retries for three days, and there is nothing to
        # retry for a customer we do not have.
        logger.warning("billing webhook %s for an unknown user", event_type)
        return {"ok": True}

    # Re-fetch rather than trust the event body: events arrive out of order
    # and more than once, and the current state is the only truth. Fetch by
    # customer, not by the subscription the event names, so a late event
    # about an old subscription can't overwrite a newer, live one.
    sub = _best(await run_in_threadpool(stripe_gateway.list_subscriptions, customer_id))
    user_id = user.id  # rollback below expires the instance
    user.stripe_customer_id = customer_id
    if sub is None:
        user.stripe_subscription_id = None
        user.billing_status = "canceled"
        user.billing_plan = None
        user.current_period_start = None
        user.current_period_end = None
    else:
        user.stripe_subscription_id = sub.id
        user.billing_status = sub.status
        user.billing_plan = _plan_for(sub.price_id)
        user.current_period_start = sub.current_period_start
        user.current_period_end = sub.current_period_end
    try:
        await db.commit()
    except IntegrityError:
        # The customer id already belongs to another user. Retrying can't fix
        # that, so 200 and leave it to a human.
        await db.rollback()
        logger.warning("billing %s user=%s: customer id already in use", event_type, user_id)
        return {"ok": True}
    logger.info("billing %s user=%s status=%s", event_type, user_id, user.billing_status)
    return {"ok": True}
