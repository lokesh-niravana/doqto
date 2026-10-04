"""Organization lookup: a public directory of US practices.

`org_directory` holds Medicare group practices and hospitals from CMS, and
`org_directory_members` lists the clinician NPIs under each group. Both are
filled by scripts/import_org_directory.py, never by the app.

`organizations.directory_source/directory_id` record which directory entry an
org was created from; the partial unique index stops the same practice being
created twice.

Revision ID: 0024_org_directory
Revises: 0023_billing
Create Date: 2026-10-04
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0024_org_directory"
down_revision: Union[str, None] = "0023_billing"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "org_directory",
        sa.Column("source", sa.String(20), primary_key=True),
        sa.Column("source_id", sa.String(20), primary_key=True),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("display_name", sa.String(255), nullable=False),
        sa.Column("city", sa.String(100), nullable=True),
        sa.Column("state", sa.CHAR(2), nullable=True),
        sa.Column("practice_type", sa.String(50), nullable=False),
        sa.Column("member_count", sa.Integer, nullable=True),
    )
    op.create_index("ix_org_directory_state", "org_directory", ["state"])
    # pg_trgm exists since 0013.
    op.execute(
        "CREATE INDEX ix_org_directory_display_name_trgm ON org_directory "
        "USING gin (display_name gin_trgm_ops)"
    )
    op.create_table(
        "org_directory_members",
        sa.Column("source_id", sa.String(20), primary_key=True),
        sa.Column("npi", sa.CHAR(10), primary_key=True),
    )
    op.create_index("ix_org_directory_members_npi", "org_directory_members", ["npi"])

    op.add_column("organizations", sa.Column("directory_source", sa.String(20), nullable=True))
    op.add_column("organizations", sa.Column("directory_id", sa.String(20), nullable=True))
    op.create_index(
        "uq_organizations_directory",
        "organizations",
        ["directory_source", "directory_id"],
        unique=True,
        postgresql_where=sa.text("directory_id IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("uq_organizations_directory", table_name="organizations")
    op.drop_column("organizations", "directory_id")
    op.drop_column("organizations", "directory_source")
    op.drop_table("org_directory_members")
    op.execute("DROP INDEX IF EXISTS ix_org_directory_display_name_trgm")
    op.drop_table("org_directory")
