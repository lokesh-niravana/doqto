"""Conversation preferences (batch 3): per-member pin / archive / mute /
mark-unread / clear-chat / delete-chat cursors and cosmetic choices.

Revision ID: 0031_conversation_prefs
Revises: 0030_privacy_presence
Create Date: 2026-11-08
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0031_conversation_prefs"
down_revision: Union[str, None] = "0030_privacy_presence"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

TABLE = "conversation_prefs"


def upgrade() -> None:
    op.create_table(
        TABLE,
        sa.Column(
            "conversation_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("conversations.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "user_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("pinned_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("archived", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("muted_until", sa.DateTime(timezone=True), nullable=True),
        sa.Column("custom_tone", sa.String(64), nullable=True),
        sa.Column("custom_vibrate", sa.String(32), nullable=True),
        sa.Column("theme", sa.String(32), nullable=True),
        sa.Column("wallpaper", sa.String(64), nullable=True),
        sa.Column(
            "marked_unread", sa.Boolean(), nullable=False, server_default=sa.text("false")
        ),
        sa.Column("cleared_before_seq", sa.BigInteger(), nullable=True),
        sa.Column("hidden_until_seq", sa.BigInteger(), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index(f"ix_{TABLE}_user_id", TABLE, ["user_id"])


def downgrade() -> None:
    op.drop_index(f"ix_{TABLE}_user_id", table_name=TABLE)
    op.drop_table(TABLE)
