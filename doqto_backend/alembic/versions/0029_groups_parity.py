"""Groups parity: index message_reactions by user for the leave/remove/ban
reaction purge (reactions of a departed member are deleted per conversation).

Revision ID: 0029_groups_parity
Revises: 0028_message_reactions
Create Date: 2026-11-08
"""
from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0029_groups_parity"
down_revision: Union[str, None] = "0028_message_reactions"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_index("ix_message_reactions_user_id", "message_reactions", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_message_reactions_user_id", table_name="message_reactions")
