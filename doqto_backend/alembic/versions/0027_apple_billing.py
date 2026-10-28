"""In-App Purchase on users.

Apple's 3.1.1 rejection: the iOS app must sell the subscription through
In-App Purchase too. Three columns, kept apart from the Stripe mirror.

Revision ID: 0027_apple_billing
Revises: 0026_app_invites
Create Date: 2026-10-28
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0027_apple_billing"
down_revision: Union[str, None] = "0026_app_invites"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "users", sa.Column("apple_original_transaction_id", sa.String(length=64), nullable=True)
    )
    op.add_column("users", sa.Column("apple_plan", sa.String(length=10), nullable=True))
    op.add_column(
        "users", sa.Column("apple_expires_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.create_unique_constraint(
        "uq_users_apple_original_transaction_id", "users", ["apple_original_transaction_id"]
    )


def downgrade() -> None:
    op.drop_constraint("uq_users_apple_original_transaction_id", "users", type_="unique")
    for column in ("apple_expires_at", "apple_plan", "apple_original_transaction_id"):
        op.drop_column("users", column)
