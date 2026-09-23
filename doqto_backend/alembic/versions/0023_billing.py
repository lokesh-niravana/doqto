"""Stripe billing on users.

Seven columns. Six mirror Stripe; `trial_ends_at` is ours, because the 14-day
trial takes no card and so never exists in Stripe.

Backfill: everyone already registered starts their trial now rather than at
sign-up, so nobody wakes up locked out on deploy day. The App Review demo
account gets a trial that never ends.

Revision ID: 0023_billing
Revises: 0022_firebase_identity
Create Date: 2026-09-23
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0023_billing"
down_revision: Union[str, None] = "0022_firebase_identity"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

DEMO_PHONE = "+16505550199"


def upgrade() -> None:
    op.add_column("users", sa.Column("trial_ends_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("users", sa.Column("stripe_customer_id", sa.String(length=64), nullable=True))
    op.add_column("users", sa.Column("stripe_subscription_id", sa.String(length=64), nullable=True))
    op.add_column("users", sa.Column("billing_status", sa.String(length=20), nullable=True))
    op.add_column("users", sa.Column("billing_plan", sa.String(length=10), nullable=True))
    op.add_column(
        "users", sa.Column("current_period_start", sa.DateTime(timezone=True), nullable=True)
    )
    op.add_column(
        "users", sa.Column("current_period_end", sa.DateTime(timezone=True), nullable=True)
    )
    op.create_unique_constraint("uq_users_stripe_customer_id", "users", ["stripe_customer_id"])

    # Registered = has a name and a real NPI. Half-finished sign-ups get their
    # trial when they finish registering.
    op.execute(
        """
        UPDATE users
           SET trial_ends_at = now() + interval '14 days'
         WHERE full_name <> ''
           AND npi_number NOT LIKE 'PENDING%'
           AND deleted_at IS NULL
        """
    )
    op.execute(
        f"""
        UPDATE users
           SET trial_ends_at = TIMESTAMPTZ '2099-01-01 00:00:00+00'
         WHERE phone = '{DEMO_PHONE}'
        """
    )


def downgrade() -> None:
    op.drop_constraint("uq_users_stripe_customer_id", "users", type_="unique")
    for column in (
        "current_period_end",
        "current_period_start",
        "billing_plan",
        "billing_status",
        "stripe_subscription_id",
        "stripe_customer_id",
        "trial_ends_at",
    ):
        op.drop_column("users", column)
