"""Compliance (batch 7): tamper-evident audit chain, envelope-encryption key
versions, wrapped data keys, break-glass access requests.

Revision ID: 0035_compliance
Revises: 0034_settings
Create Date: 2026-11-08
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0035_compliance"
down_revision: Union[str, None] = "0034_settings"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # --- audit chain ------------------------------------------------------ #
    # Audit rows are now written in their own transaction, possibly before the
    # user row commits, and must outlive the user: drop the FK.
    op.execute("ALTER TABLE audit_logs DROP CONSTRAINT IF EXISTS audit_logs_user_id_fkey")
    op.add_column("audit_logs", sa.Column("seq", sa.BigInteger(), nullable=True))
    op.add_column("audit_logs", sa.Column("prev_hash", sa.String(64), nullable=True))
    op.add_column("audit_logs", sa.Column("hash", sa.String(64), nullable=True))
    # Number existing rows in time order. Their hash stays NULL: the verifier
    # accepts an unhashed prefix, and the chain starts at the first new row.
    op.execute(
        """
        UPDATE audit_logs a SET seq = n.rn
        FROM (SELECT id, ROW_NUMBER() OVER (ORDER BY created_at, id) AS rn FROM audit_logs) n
        WHERE a.id = n.id
        """
    )
    op.create_index("ix_audit_logs_seq", "audit_logs", ["seq"], unique=True)

    # --- key versions ----------------------------------------------------- #
    for table in ("messages", "message_edits", "scheduled_messages", "poll_options"):
        op.add_column(
            table,
            sa.Column("key_version", sa.Integer(), nullable=False, server_default="0"),
        )

    op.create_table(
        "data_keys",
        sa.Column("version", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("scope", sa.String(64), nullable=False),
        sa.Column("wrapped_key", sa.LargeBinary(), nullable=False),
        sa.Column("wrapper", sa.String(16), nullable=False),
        sa.Column("kms_key_id", sa.Text(), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("retired_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_data_keys_scope", "data_keys", ["scope"])
    op.create_index(
        "uq_data_keys_active_scope",
        "data_keys",
        ["scope"],
        unique=True,
        postgresql_where=sa.text("retired_at IS NULL"),
    )

    # --- break-glass ------------------------------------------------------ #
    op.create_table(
        "access_requests",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "org_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("organizations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "conversation_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("conversations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "requester_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=False
        ),
        sa.Column("reason", sa.String(500), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="pending"),
        sa.Column(
            "decided_by", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id"), nullable=True
        ),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("first_read_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
    )
    op.create_index("ix_access_requests_conversation_id", "access_requests", ["conversation_id"])
    op.create_index("ix_access_requests_requester_id", "access_requests", ["requester_id"])
    op.create_index("ix_access_requests_expires_at", "access_requests", ["expires_at"])
    op.create_index("ix_access_requests_org_created", "access_requests", ["org_id", "created_at"])


def downgrade() -> None:
    op.drop_index("ix_access_requests_org_created", table_name="access_requests")
    op.drop_index("ix_access_requests_expires_at", table_name="access_requests")
    op.drop_index("ix_access_requests_requester_id", table_name="access_requests")
    op.drop_index("ix_access_requests_conversation_id", table_name="access_requests")
    op.drop_table("access_requests")
    op.drop_index("uq_data_keys_active_scope", table_name="data_keys")
    op.drop_index("ix_data_keys_scope", table_name="data_keys")
    op.drop_table("data_keys")
    # Rows written under a data key cannot be read by the pre-0035 code; the
    # column drop is schema-only — run scripts/rotate_keys.py --to-legacy first.
    for table in ("poll_options", "scheduled_messages", "message_edits", "messages"):
        op.drop_column(table, "key_version")
    op.drop_index("ix_audit_logs_seq", table_name="audit_logs")
    op.drop_column("audit_logs", "hash")
    op.drop_column("audit_logs", "prev_hash")
    op.drop_column("audit_logs", "seq")
    op.create_foreign_key(
        "audit_logs_user_id_fkey", "audit_logs", "users", ["user_id"], ["id"]
    )
