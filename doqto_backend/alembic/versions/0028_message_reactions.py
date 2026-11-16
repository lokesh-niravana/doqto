"""message_reactions + messages.changed_at (catch-up for post-send changes)

Revision ID: 0028_message_reactions
Revises: 0027_apple_billing
Create Date: 2026-11-08
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0028_message_reactions"
down_revision: Union[str, None] = "0027_apple_billing"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "message_reactions",
        sa.Column(
            "message_id",
            UUID(as_uuid=True),
            sa.ForeignKey("messages.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "user_id",
            UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("emoji", sa.String(32), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
        ),
    )
    op.add_column("messages", sa.Column("changed_at", sa.DateTime(timezone=True), nullable=True))
    op.create_index(
        "ix_messages_conv_changed", "messages", ["conversation_id", "changed_at"]
    )


def downgrade() -> None:
    op.drop_index("ix_messages_conv_changed", table_name="messages")
    op.drop_column("messages", "changed_at")
    op.drop_table("message_reactions")
