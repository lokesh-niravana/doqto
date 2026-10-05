"""Networking graph models (M1): invitations, connections, removals, blocks,
mutes, reports.

Indexes are declared on the models (not only in the migration) so the test
harness's Base.metadata.create_all builds them too — the partial UNIQUE index
that enforces "one pending invitation per (sender, recipient)" is load-bearing
for acceptance test 1, and must exist in the test DB.
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.enums import InvitationStatus, ReportStatus
from app.db.postgres import Base
from app.db.tables import Tables


class ConnectionInvitation(Base):
    __tablename__ = Tables.CONNECTION_INVITATIONS
    __table_args__ = (
        CheckConstraint("sender_id <> recipient_id", name="ck_connection_invitations_distinct"),
        CheckConstraint(
            "status IN ('pending', 'accepted', 'ignored', 'withdrawn', 'expired')",
            name="ck_connection_invitations_status",
        ),
        # One live invitation per ordered (sender, recipient) pair.
        Index(
            "uq_connection_invitations_pending",
            "sender_id",
            "recipient_id",
            unique=True,
            postgresql_where=text("status = 'pending'"),
        ),
        Index("ix_connection_invitations_recipient_status", "recipient_id", "status"),
        Index("ix_connection_invitations_sender_status", "sender_id", "status"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    sender_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False
    )
    recipient_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False
    )
    message: Mapped[str | None] = mapped_column(String(300), nullable=True)
    status: Mapped[InvitationStatus] = mapped_column(
        String(20),
        default=InvitationStatus.PENDING,
        server_default=InvitationStatus.PENDING.value,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    responded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class Connection(Base):
    """Mirrored rows: (a→b) and (b→a) share one `pair_id`. Undirected edge is
    the pair; each row lets us list one user's connections with a single index."""

    __tablename__ = Tables.CONNECTIONS
    __table_args__ = (
        CheckConstraint(
            "user_id <> connected_user_id", name="ck_connections_distinct"
        ),
        Index("ix_connections_pair_id", "pair_id"),
        Index("ix_connections_user_created", "user_id", "created_at"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    connected_user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    pair_id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class ConnectionRemoval(Base):
    """Cooldown ledger — a removed connection can't be re-invited for 30 days."""

    __tablename__ = Tables.CONNECTION_REMOVALS
    __table_args__ = (Index("ix_connection_removals_pair", "user_a", "user_b"),)

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    pair_id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    removed_by: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False
    )
    # Sorted pair (a < b) so a lookup is order-independent.
    user_a: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    user_b: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    removed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class Block(Base):
    __tablename__ = Tables.BLOCKS
    __table_args__ = (
        UniqueConstraint("blocker_id", "blocked_id", name="uq_blocks_pair"),
        Index("ix_blocks_blocked", "blocked_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    blocker_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False
    )
    blocked_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class Mute(Base):
    __tablename__ = Tables.MUTES
    __table_args__ = (
        UniqueConstraint("user_id", "muted_user_id", name="uq_mutes_pair"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False
    )
    muted_user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class SuggestionDismissal(Base):
    """A doctor the viewer hid from "Recommended for you", for good."""

    __tablename__ = Tables.SUGGESTION_DISMISSALS

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    dismissed_user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )


class Report(Base):
    __tablename__ = Tables.REPORTS
    __table_args__ = (
        CheckConstraint(
            "status IN ('open', 'reviewing', 'actioned', 'dismissed')",
            name="ck_reports_status",
        ),
        Index("ix_reports_status_created", "status", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    reporter_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=False
    )
    subject_type: Mapped[str] = mapped_column(String(20), nullable=False)
    subject_id: Mapped[uuid.UUID] = mapped_column(PgUUID(as_uuid=True), nullable=False)
    reason: Mapped[str] = mapped_column(String(50), nullable=False)
    details: Mapped[str | None] = mapped_column(String(1000), nullable=True)
    status: Mapped[ReportStatus] = mapped_column(
        String(20),
        default=ReportStatus.OPEN,
        server_default=ReportStatus.OPEN.value,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
