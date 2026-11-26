"""Moderation: operator suspension of an account (App Store Guideline 1.2).

Additive: two nullable columns on users. A suspended account cannot sign in,
call the API or hold a socket; nothing is erased.

Revision ID: 0036_user_suspension
Revises: 0035_compliance
Create Date: 2026-11-26
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0036_user_suspension"
down_revision: Union[str, None] = "0035_compliance"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("suspended_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("users", sa.Column("suspended_reason", sa.String(255), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "suspended_reason")
    op.drop_column("users", "suspended_at")
