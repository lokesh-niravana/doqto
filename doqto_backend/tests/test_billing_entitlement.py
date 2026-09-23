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
