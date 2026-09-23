from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import CHAR, CheckConstraint, DateTime, SmallInteger, String, func
from sqlalchemy.dialects.postgresql import ARRAY, UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.enums import UserRole
from app.db.postgres import Base
from app.db.tables import Tables


class User(Base):
    __tablename__ = Tables.USERS
    __table_args__ = (
        CheckConstraint(
            "phone IS NOT NULL OR email IS NOT NULL", name="ck_users_phone_or_email"
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    # Nullable since Firebase became the identity broker: a user who signs in
    # with Google/Facebook/Apple and skips the optional phone field has none.
    # A CHECK constraint keeps phone-or-email always present.
    phone: Mapped[str | None] = mapped_column(String(20), unique=True, nullable=True, index=True)
    email: Mapped[str | None] = mapped_column(String(255), unique=True, nullable=True, index=True)
    password_hash: Mapped[str | None] = mapped_column(String(255), nullable=True)
    # Firebase uid — the identity every sign-in method resolves to. Cleared on
    # account deletion so a tombstone can never be adopted by a new sign-in.
    firebase_uid: Mapped[str | None] = mapped_column(
        String(128), unique=True, nullable=True, index=True
    )
    # Billing — mirrored from Stripe by the webhook, except trial_ends_at,
    # which is ours: the trial needs no card, so Stripe never sees it.
    trial_ends_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    stripe_customer_id: Mapped[str | None] = mapped_column(
        String(64), unique=True, nullable=True
    )
    stripe_subscription_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    billing_status: Mapped[str | None] = mapped_column(String(20), nullable=True)
    billing_plan: Mapped[str | None] = mapped_column(String(10), nullable=True)
    current_period_start: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    current_period_end: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    full_name: Mapped[str] = mapped_column(String(255), nullable=False)
    # Public handle (nullable, generated lazily on first profile edit) + headline.
    handle: Mapped[str | None] = mapped_column(String(30), unique=True, nullable=True)
    headline: Mapped[str | None] = mapped_column(String(120), nullable=True)
    specialty: Mapped[str | None] = mapped_column(String(100), nullable=True)
    npi_number: Mapped[str] = mapped_column(CHAR(10), unique=True, nullable=False, index=True)
    role: Mapped[UserRole] = mapped_column(String(20), default=UserRole.DOCTOR, nullable=False)
    avatar_color: Mapped[str | None] = mapped_column(String(7), nullable=True)
    avatar_url: Mapped[str | None] = mapped_column(String(1024), nullable=True)
    bio: Mapped[str | None] = mapped_column(String(500), nullable=True)
    city: Mapped[str | None] = mapped_column(String(120), nullable=True)
    state: Mapped[str | None] = mapped_column(String(120), nullable=True)
    years_of_experience: Mapped[int | None] = mapped_column(SmallInteger, nullable=True)
    skills: Mapped[list[str]] = mapped_column(
        ARRAY(String(40)), nullable=False, server_default="{}", default=list
    )
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Set by AccountDeletionService. The row survives as a scrubbed tombstone
    # (audit rows FK to it, HIPAA retention); this makes the account unusable.
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
