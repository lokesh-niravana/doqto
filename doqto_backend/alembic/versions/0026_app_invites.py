"""Invite a colleague: who invited which NPI.

Revision ID: 0026_app_invites
Revises: 0025_suggestion_dismissals
Create Date: 2026-10-11
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0026_app_invites"
down_revision: Union[str, None] = "0025_suggestion_dismissals"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "app_invites",
        sa.Column(
            "inviter_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("npi", sa.String(10), primary_key=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("joined_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_app_invites_npi", "app_invites", ["npi"])


def downgrade() -> None:
    op.drop_index("ix_app_invites_npi", table_name="app_invites")
    op.drop_table("app_invites")
