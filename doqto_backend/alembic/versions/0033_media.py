"""Media (batch 5): captions, video poster thumbs, voice waveforms, media
size, polls (poll_options / poll_votes) and presigned multipart upload
intents.

Revision ID: 0033_media
Revises: 0032_message_features
Create Date: 2026-11-08
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import UUID

revision: str = "0033_media"
down_revision: Union[str, None] = "0032_message_features"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("messages", sa.Column("caption_encrypted", sa.LargeBinary(), nullable=True))
    op.add_column("messages", sa.Column("thumb_key", sa.Text(), nullable=True))
    op.add_column("messages", sa.Column("waveform", sa.LargeBinary(), nullable=True))
    op.add_column("messages", sa.Column("media_width", sa.Integer(), nullable=True))
    op.add_column("messages", sa.Column("media_height", sa.Integer(), nullable=True))
    op.add_column("messages", sa.Column("poll_multiple", sa.Boolean(), nullable=True))

    op.create_table(
        "poll_options",
        sa.Column(
            "id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")
        ),
        sa.Column(
            "message_id",
            UUID(as_uuid=True),
            sa.ForeignKey("messages.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("text_encrypted", sa.LargeBinary(), nullable=False),
    )
    op.create_index("ix_poll_options_message_id", "poll_options", ["message_id"])

    op.create_table(
        "poll_votes",
        sa.Column(
            "option_id",
            UUID(as_uuid=True),
            sa.ForeignKey("poll_options.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "user_id",
            UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "message_id",
            UUID(as_uuid=True),
            sa.ForeignKey("messages.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
        ),
    )
    op.create_index("ix_poll_votes_user_id", "poll_votes", ["user_id"])
    op.create_index("ix_poll_votes_message_id", "poll_votes", ["message_id"])

    op.create_table(
        "upload_intents",
        sa.Column(
            "id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")
        ),
        sa.Column(
            "conversation_id",
            UUID(as_uuid=True),
            sa.ForeignKey("conversations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "user_id", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("message_id", UUID(as_uuid=True), nullable=False),
        sa.Column("type", sa.String(20), nullable=False),
        sa.Column("s3_key", sa.Text(), nullable=False),
        sa.Column("thumb_key", sa.Text(), nullable=True),
        sa.Column("upload_id", sa.Text(), nullable=True),
        sa.Column("part_count", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("content_type", sa.String(255), nullable=False),
        sa.Column("file_name", sa.String(255), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("client_id", sa.String(64), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
        ),
    )
    op.create_index("ix_upload_intents_conversation_id", "upload_intents", ["conversation_id"])
    op.create_index("ix_upload_intents_expires_at", "upload_intents", ["expires_at"])


def downgrade() -> None:
    op.drop_index("ix_upload_intents_expires_at", table_name="upload_intents")
    op.drop_index("ix_upload_intents_conversation_id", table_name="upload_intents")
    op.drop_table("upload_intents")
    op.drop_index("ix_poll_votes_message_id", table_name="poll_votes")
    op.drop_index("ix_poll_votes_user_id", table_name="poll_votes")
    op.drop_table("poll_votes")
    op.drop_index("ix_poll_options_message_id", table_name="poll_options")
    op.drop_table("poll_options")
    op.drop_column("messages", "poll_multiple")
    op.drop_column("messages", "media_height")
    op.drop_column("messages", "media_width")
    op.drop_column("messages", "waveform")
    op.drop_column("messages", "thumb_key")
    op.drop_column("messages", "caption_encrypted")
