from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import BigInteger, DateTime, String, Text, func
from sqlalchemy.dialects.postgresql import INET, JSONB, UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db.postgres import Base
from app.db.tables import Tables


class AuditLog(Base):
    """One audited event. Since batch 7 every row is written in its own short
    transaction (so a rolled-back request still leaves its attempt behind)
    and chained: `hash = sha256(prev_hash + canonical JSON of the row)`.
    `seq` is dense and assigned under an advisory lock, so the chain has one
    well-defined order. `user_id` is deliberately NOT a foreign key: the row
    may be written before the user's own transaction commits, and it must
    outlive the user (HIPAA six-year retention)."""

    __tablename__ = Tables.AUDIT_LOGS

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    seq: Mapped[int | None] = mapped_column(BigInteger, nullable=True, unique=True, index=True)
    user_id: Mapped[uuid.UUID | None] = mapped_column(PgUUID(as_uuid=True), nullable=True, index=True)
    action: Mapped[str] = mapped_column(String(100), nullable=False, index=True)
    resource_type: Mapped[str | None] = mapped_column(String(50), nullable=True)
    resource_id: Mapped[uuid.UUID | None] = mapped_column(PgUUID(as_uuid=True), nullable=True)
    ip_address: Mapped[str | None] = mapped_column(INET, nullable=True)
    user_agent: Mapped[str | None] = mapped_column(Text, nullable=True)
    meta: Mapped[dict[str, Any] | None] = mapped_column("metadata", JSONB, nullable=True)
    prev_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
