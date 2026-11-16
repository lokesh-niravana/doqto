"""Settings (batch 6): notification preferences, linked-device sessions,
two-step PIN, status under the name.

Revision ID: 0034_settings
Revises: 0033_media
Create Date: 2026-11-08
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0034_settings"
down_revision: Union[str, None] = "0033_media"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("pin_hash", sa.String(255), nullable=True))
    op.add_column("users", sa.Column("pin_reset_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("users", sa.Column("status_text", sa.String(40), nullable=True))
    op.add_column(
        "users", sa.Column("status_expires_at", sa.DateTime(timezone=True), nullable=True)
    )

    op.create_table(
        "user_notification_settings",
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("messages_tone", sa.String(32), nullable=False, server_default="default"),
        sa.Column("messages_vibrate", sa.String(16), nullable=False, server_default="default"),
        sa.Column("messages_show_preview", sa.Boolean(), nullable=True),
        sa.Column(
            "messages_high_priority", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column("groups_tone", sa.String(32), nullable=False, server_default="default"),
        sa.Column("groups_vibrate", sa.String(16), nullable=False, server_default="default"),
        sa.Column("groups_show_preview", sa.Boolean(), nullable=True),
        sa.Column(
            "groups_high_priority", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column(
            "reaction_notifications", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column(
            "conversation_tones", sa.Boolean(), nullable=False, server_default=sa.text("true")
        ),
        sa.Column("haptics", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )

    op.create_table(
        "sessions",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("device_name", sa.String(80), nullable=True),
        sa.Column("platform", sa.String(10), nullable=True),
        sa.Column("app_version", sa.String(32), nullable=True),
        sa.Column("ip", postgresql.INET(), nullable=True),
        sa.Column("refresh_jti", sa.String(64), nullable=False),
        sa.Column("access_jti", sa.String(64), nullable=False),
        sa.Column("pin_verified_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "last_seen_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_sessions_user_id", "sessions", ["user_id"])
    op.create_index("ix_sessions_refresh_jti", "sessions", ["refresh_jti"])
    op.create_index("ix_sessions_access_jti", "sessions", ["access_jti"])


def downgrade() -> None:
    op.drop_index("ix_sessions_access_jti", table_name="sessions")
    op.drop_index("ix_sessions_refresh_jti", table_name="sessions")
    op.drop_index("ix_sessions_user_id", table_name="sessions")
    op.drop_table("sessions")
    op.drop_table("user_notification_settings")
    op.drop_column("users", "status_expires_at")
    op.drop_column("users", "status_text")
    op.drop_column("users", "pin_reset_at")
    op.drop_column("users", "pin_hash")
