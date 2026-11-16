"""Compliance models (batch 7): wrapped data keys and break-glass access
requests. Nothing here holds PHI — a data key is wrapped, a request carries
ids and the admin's stated reason."""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Index, Integer, LargeBinary, String, Text, func, text
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.enums import AccessRequestStatus
from app.db.postgres import Base
from app.db.tables import Tables


class DataKey(Base):
    """One AES-256 data key, stored wrapped by the master key (KMS or the
    static key). `version` is what rows store in `key_version`; one active
    (retired_at IS NULL) key per scope."""

    __tablename__ = Tables.DATA_KEYS
    __table_args__ = (
        Index(
            "uq_data_keys_active_scope",
            "scope",
            unique=True,
            postgresql_where=text("retired_at IS NULL"),
        ),
    )

    version: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    scope: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    wrapped_key: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    wrapper: Mapped[str] = mapped_column(String(16), nullable=False)
    kms_key_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    retired_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class AccessRequest(Base):
    """Break-glass: an org admin asks to read one conversation; a *different*
    org admin approves; the requester then has a 24 h window of audited
    reads. Every transition is audited and visible to both admins."""

    __tablename__ = Tables.ACCESS_REQUESTS
    __table_args__ = (Index("ix_access_requests_org_created", "org_id", "created_at"),)

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    org_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.ORGANIZATIONS}.id", ondelete="CASCADE"),
        nullable=False,
    )
    conversation_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.CONVERSATIONS}.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    requester_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False, index=True
    )
    reason: Mapped[str] = mapped_column(String(500), nullable=False)
    status: Mapped[AccessRequestStatus] = mapped_column(
        String(20),
        default=AccessRequestStatus.PENDING,
        server_default=AccessRequestStatus.PENDING.value,
        nullable=False,
    )
    decided_by: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=True
    )
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Approval + ACCESS_REQUEST_WINDOW_SEC; reads refused past it.
    expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True, index=True
    )
    # Set on the first page read — that is when the conversation gets its
    # "An administrator accessed this conversation under policy" line.
    first_read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
