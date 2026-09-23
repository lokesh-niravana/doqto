"""Billing columns and the entitlement rule."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from tests import helpers

pytestmark = pytest.mark.asyncio


async def test_a_new_user_gets_a_trial_by_default(db):
    user = await helpers.create_user(db)

    assert user.trial_ends_at is not None
    assert user.trial_ends_at > datetime.now(timezone.utc) + timedelta(days=13)
    assert user.billing_status is None
    assert user.stripe_customer_id is None


async def test_a_user_can_be_created_without_a_trial(db):
    user = await helpers.create_user(db, trial_days=None)

    assert user.trial_ends_at is None


from app.core.enums import UserRole
from app.services.billing_service import entitlement

NOW = datetime(2026, 9, 23, 12, 0, tzinfo=timezone.utc)


async def test_a_running_trial_is_entitled(db):
    user = await helpers.create_user(db, trial_days=None)
    user.trial_ends_at = NOW + timedelta(seconds=1)

    assert entitlement(user, NOW) == (True, "trial")


async def test_the_trial_ends_exactly_at_its_deadline(db):
    user = await helpers.create_user(db, trial_days=None)
    user.trial_ends_at = NOW

    # Not "one more second of goodwill": the deadline IS the end.
    assert entitlement(user, NOW) == (False, "expired")


async def test_a_user_who_never_had_a_trial_is_refused(db):
    # Registration abandoned half-way: no trial, no subscription, no crash.
    user = await helpers.create_user(db, trial_days=None)

    assert entitlement(user, NOW) == (False, "expired")


@pytest.mark.parametrize("status", ["active", "trialing"])
async def test_a_live_subscription_is_entitled(db, status):
    user = await helpers.create_user(db, trial_days=None)
    user.billing_status = status

    assert entitlement(user, NOW) == (True, "subscribed")


async def test_a_failed_payment_keeps_access_for_the_grace_period(db):
    user = await helpers.create_user(db, trial_days=None)
    user.billing_status = "past_due"
    user.current_period_end = NOW - timedelta(days=6)

    assert entitlement(user, NOW) == (True, "grace")


async def test_grace_runs_out_after_seven_days(db):
    user = await helpers.create_user(db, trial_days=None)
    user.billing_status = "past_due"
    user.current_period_end = NOW - timedelta(days=7)

    assert entitlement(user, NOW) == (False, "expired")


async def test_a_cancelled_subscription_is_refused(db):
    user = await helpers.create_user(db, trial_days=None)
    user.billing_status = "canceled"

    assert entitlement(user, NOW) == (False, "expired")


async def test_staff_never_meet_the_paywall(db):
    user = await helpers.create_user(db, trial_days=None)
    user.role = UserRole.SUPER_ADMIN

    assert entitlement(user, NOW) == (True, "staff")
