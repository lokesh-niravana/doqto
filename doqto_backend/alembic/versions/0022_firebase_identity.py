"""Firebase becomes the identity broker.

Phone OTP could never reach a US number (SNS has no origination identity;
Twilio Verify is gated on TrustHub review). Firebase phone auth has neither
gate, and brings Google/Facebook/Apple in on the same ID token.

Three changes, all on `users`:
  * `firebase_uid` — the identity every sign-in method resolves to.
  * `phone` becomes nullable — a social-only account has none.
  * a CHECK keeping phone-or-email present, so no account is unreachable.

Revision ID: 0022_firebase_identity
Revises: 0021_no_message_requests
Create Date: 2026-09-14
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0022_firebase_identity"
down_revision: Union[str, None] = "0021_no_message_requests"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("firebase_uid", sa.String(length=128), nullable=True))
    op.create_index("ix_users_firebase_uid", "users", ["firebase_uid"], unique=True)
    op.alter_column("users", "phone", existing_type=sa.String(length=20), nullable=True)
    op.create_check_constraint(
        "ck_users_phone_or_email", "users", "phone IS NOT NULL OR email IS NOT NULL"
    )


def downgrade() -> None:
    # Rows with no phone cannot exist under the old schema. They are social-only
    # accounts created after this migration; there is nothing to back them out
    # to, so downgrade refuses rather than inventing placeholder numbers.
    orphans = op.get_bind().scalar(sa.text("SELECT count(*) FROM users WHERE phone IS NULL"))
    if orphans:
        raise RuntimeError(
            f"{orphans} user(s) have no phone number; cannot restore NOT NULL. "
            "Resolve them before downgrading."
        )
    op.drop_constraint("ck_users_phone_or_email", "users", type_="check")
    op.alter_column("users", "phone", existing_type=sa.String(length=20), nullable=False)
    op.drop_index("ix_users_firebase_uid", table_name="users")
    op.drop_column("users", "firebase_uid")
