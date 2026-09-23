"""Subscription status, checkout and the customer portal.

The app never talks to Stripe. It asks here, and opens whatever URL we hand
back in an external browser — which is also what Apple's link-out rule
requires.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.concurrency import run_in_threadpool
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.dependencies import get_current_user, get_db
from app.core.routes import ApiRoutes
from app.models import User
from app.schemas.billing import BillingOut, CheckoutIn, UrlOut
from app.services.billing_service import entitlement
from app.services.stripe_client import StripeGateway, get_stripe

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
