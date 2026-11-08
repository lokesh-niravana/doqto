"""Message features (batch 4): reply, forward, star, pin, mentions, org
content policies, report context + resolution.

merging with Batch 3 — that revision does not exist in this worktree yet.

Revision ID: 0032_message_features
Revises: 0030_privacy_presence
Create Date: 2026-11-08
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID

revision: str = "0032_message_features"
down_revision: Union[str, None] = "0031_conversation_prefs"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # messages: reply / forward / mentions
    op.add_column(
        "messages",
        sa.Column(
            "reply_to_id",
            UUID(as_uuid=True),
            sa.ForeignKey("messages.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.create_index("ix_messages_reply_to_id", "messages", ["reply_to_id"])
    op.add_column(
        "messages",
        sa.Column("forwarded", sa.Boolean(), nullable=False, server_default=sa.text("false")),
    )
    op.add_column(
        "messages",
        sa.Column("forward_depth", sa.Integer(), nullable=False, server_default="0"),
    )
    op.add_column("messages", sa.Column("mentions", ARRAY(UUID(as_uuid=True)), nullable=True))

    # message_stars
    op.create_table(
        "message_stars",
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
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
        ),
    )
    op.create_index("ix_message_stars_user_created", "message_stars", ["user_id", "created_at"])

    # conversations: pinned message
    op.add_column(
        "conversations", sa.Column("pinned_message_id", UUID(as_uuid=True), nullable=True)
    )
    op.create_foreign_key(
        "fk_conversations_pinned_message",
        "conversations",
        "messages",
        ["pinned_message_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.add_column(
        "conversations", sa.Column("pinned_until", sa.DateTime(timezone=True), nullable=True)
    )
    op.create_index("ix_conversations_pinned_until", "conversations", ["pinned_until"])
    op.add_column(
        "conversations",
        sa.Column(
            "pinned_by", UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=True
        ),
    )

    # organizations: content policies
    op.add_column(
        "organizations",
        sa.Column("policies", JSONB, nullable=False, server_default=sa.text("'{}'::jsonb")),
    )

    # reports: context + resolution
    op.add_column(
        "reports", sa.Column("context_message_ids", ARRAY(UUID(as_uuid=True)), nullable=True)
    )
    op.add_column(
        "reports",
        sa.Column(
            "resolved_by", UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=True
        ),
    )
    op.add_column(
        "reports", sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("reports", "resolved_at")
    op.drop_column("reports", "resolved_by")
    op.drop_column("reports", "context_message_ids")
    op.drop_column("organizations", "policies")
    op.drop_column("conversations", "pinned_by")
    op.drop_index("ix_conversations_pinned_until", table_name="conversations")
    op.drop_column("conversations", "pinned_until")
    op.drop_constraint("fk_conversations_pinned_message", "conversations", type_="foreignkey")
    op.drop_column("conversations", "pinned_message_id")
    op.drop_index("ix_message_stars_user_created", table_name="message_stars")
    op.drop_table("message_stars")
    op.drop_column("messages", "mentions")
    op.drop_column("messages", "forward_depth")
    op.drop_column("messages", "forwarded")
    op.drop_index("ix_messages_reply_to_id", table_name="messages")
    op.drop_column("messages", "reply_to_id")
