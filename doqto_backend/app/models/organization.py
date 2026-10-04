from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    CHAR,
    Boolean,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
    true,
)
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.enums import DirectoryVisibility, ExternalDmPolicy, OrgRole, OrgStatus
from app.db.postgres import Base
from app.db.tables import Tables


class Organization(Base):
    __tablename__ = Tables.ORGANIZATIONS
    __table_args__ = (
        Index(
            "uq_organizations_directory",
            "directory_source",
            "directory_id",
            unique=True,
            postgresql_where=text("directory_id IS NOT NULL"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    address: Mapped[str | None] = mapped_column(Text, nullable=True)
    city: Mapped[str | None] = mapped_column(String(100), nullable=True)
    state: Mapped[str | None] = mapped_column(CHAR(2), nullable=True)
    practice_type: Mapped[str | None] = mapped_column(String(50), nullable=True)
    invite_code: Mapped[str] = mapped_column(CHAR(9), unique=True, nullable=False, index=True)
    status: Mapped[OrgStatus] = mapped_column(
        String(20), default=OrgStatus.PENDING, nullable=False, index=True
    )
    review_notes: Mapped[str | None] = mapped_column(Text, nullable=True)
    # The public-directory entry this org was created from (org_directory),
    # unique together so one practice can't be created twice.
    directory_source: Mapped[str | None] = mapped_column(String(20), nullable=True)
    directory_id: Mapped[str | None] = mapped_column(String(20), nullable=True)
    # Networking policy (M0 substrate). Kill switch checked server-side on
    # every external path; changes are audit-logged (ORG_POLICY_CHANGED).
    external_networking_enabled: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default=true(), nullable=False
    )
    external_dm_policy: Mapped[ExternalDmPolicy] = mapped_column(
        String(30),  # 'connections_and_requests' is 24 chars
        default=ExternalDmPolicy.CONNECTIONS_AND_REQUESTS,
        server_default=ExternalDmPolicy.CONNECTIONS_AND_REQUESTS.value,
        nullable=False,
    )
    directory_visibility: Mapped[DirectoryVisibility] = mapped_column(
        String(20),
        default=DirectoryVisibility.NETWORK,
        server_default=DirectoryVisibility.NETWORK.value,
        nullable=False,
    )
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    verified_by: Mapped[uuid.UUID | None] = mapped_column(
        PgUUID(as_uuid=True), ForeignKey(f"{Tables.USERS}.id"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )


class OrgMember(Base):
    __tablename__ = Tables.ORG_MEMBERS
    __table_args__ = (UniqueConstraint("org_id", "user_id"),)

    id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True), primary_key=True, server_default=func.gen_random_uuid()
    )
    org_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.ORGANIZATIONS}.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    org_role: Mapped[OrgRole] = mapped_column(String(20), default=OrgRole.DOCTOR, nullable=False)
    joined_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
