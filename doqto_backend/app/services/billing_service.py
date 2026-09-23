"""Who may use Doqto, and why.

One rule, in one place, so the API, the app and any future admin screen can
never disagree. Pure: no database, no network, no clock of its own.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import NamedTuple

from app.core.config import settings
from app.core.enums import UserRole
from app.models import User

# Stripe statuses that mean "this person is paid up". `trialing` only appears
# if a Stripe-side trial is ever configured; our own trial lives in the
# database and is checked first.
LIVE_STATUSES = frozenset({"active", "trialing"})


class Entitlement(NamedTuple):
    entitled: bool
    reason: str  # staff | trial | subscribed | grace | expired


def entitlement(user: User, now: datetime | None = None) -> Entitlement:
    """First matching rule wins."""
    now = now or datetime.now(timezone.utc)

    if user.role == UserRole.SUPER_ADMIN:
        return Entitlement(True, "staff")

    if user.trial_ends_at is not None and user.trial_ends_at > now:
        return Entitlement(True, "trial")

    if user.billing_status in LIVE_STATUSES:
        return Entitlement(True, "subscribed")

    # A failed renewal keeps the door open briefly: cards expire, people are
    # on call, and losing a messaging app over a declined charge is worse than
    # a few unpaid days. Measured from the period START: by the time a renewal
    # fails Stripe has already rolled the period forward, so the start is the
    # day the charge failed and the end is a whole billing period away.
    if (
        user.billing_status == "past_due"
        and user.current_period_start is not None
        and user.current_period_start + timedelta(days=settings.BILLING_GRACE_DAYS) > now
    ):
        return Entitlement(True, "grace")

    return Entitlement(False, "expired")
