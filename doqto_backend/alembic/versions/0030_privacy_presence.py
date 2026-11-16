"""Privacy screen + presence (batch 2): last-seen / online / photo / about
visibility, read-receipt toggle, default disappearing timer and link-preview
flag on user_privacy_settings.

Revision ID: 0030_privacy_presence
Revises: 0029_groups_parity
Create Date: 2026-11-08
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0030_privacy_presence"
down_revision: Union[str, None] = "0029_groups_parity"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

TABLE = "user_privacy_settings"


def upgrade() -> None:
    op.add_column(
        TABLE,
        sa.Column(
            "last_seen_visibility", sa.String(20), nullable=False, server_default="connections"
        ),
    )
    op.add_column(
        TABLE,
        sa.Column(
            "online_visibility", sa.String(24), nullable=False, server_default="same_as_last_seen"
        ),
    )
    op.add_column(
        TABLE,
        sa.Column(
            "profile_photo_visibility", sa.String(20), nullable=False, server_default="everyone"
        ),
    )
    op.add_column(
        TABLE,
        sa.Column("about_visibility", sa.String(20), nullable=False, server_default="everyone"),
    )
    op.add_column(
        TABLE,
        sa.Column("read_receipts", sa.Boolean(), nullable=False, server_default=sa.text("true")),
    )
    op.add_column(TABLE, sa.Column("default_disappear_sec", sa.Integer(), nullable=True))
    op.add_column(
        TABLE,
        sa.Column("link_previews", sa.Boolean(), nullable=False, server_default=sa.text("true")),
    )
    op.create_check_constraint(
        "ck_user_privacy_last_seen_visibility",
        TABLE,
        "last_seen_visibility IN ('everyone', 'connections', 'nobody')",
    )
    op.create_check_constraint(
        "ck_user_privacy_online_visibility",
        TABLE,
        "online_visibility IN ('same_as_last_seen', 'nobody')",
    )
    op.create_check_constraint(
        "ck_user_privacy_profile_photo_visibility",
        TABLE,
        "profile_photo_visibility IN ('everyone', 'connections')",
    )
    op.create_check_constraint(
        "ck_user_privacy_about_visibility",
        TABLE,
        "about_visibility IN ('everyone', 'connections')",
    )


def downgrade() -> None:
    for name in (
        "ck_user_privacy_about_visibility",
        "ck_user_privacy_profile_photo_visibility",
        "ck_user_privacy_online_visibility",
        "ck_user_privacy_last_seen_visibility",
    ):
        op.drop_constraint(name, TABLE, type_="check")
    for col in (
        "link_previews",
        "default_disappear_sec",
        "read_receipts",
        "about_visibility",
        "profile_photo_visibility",
        "online_visibility",
        "last_seen_visibility",
    ):
        op.drop_column(TABLE, col)
