"""Public directory of US practices, for organization lookup.

Loaded by scripts/import_org_directory.py from CMS data (Medicare group
practices and hospitals) — read-only to the app. See
docs/superpowers/specs/2026-10-04-org-lookup-research.md.
"""
from __future__ import annotations

from sqlalchemy import CHAR, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.postgres import Base
from app.db.tables import Tables


class OrgDirectoryEntry(Base):
    __tablename__ = Tables.ORG_DIRECTORY

    # cms_group (Medicare group PAC ID) | cms_hospital (CCN) | nppes (NPI-2)
    source: Mapped[str] = mapped_column(String(20), primary_key=True)
    source_id: Mapped[str] = mapped_column(String(20), primary_key=True)
    name: Mapped[str] = mapped_column(String(255), nullable=False)  # legal, as CMS has it
    display_name: Mapped[str] = mapped_column(String(255), nullable=False)
    city: Mapped[str | None] = mapped_column(String(100), nullable=True)
    state: Mapped[str | None] = mapped_column(CHAR(2), nullable=True, index=True)
    practice_type: Mapped[str] = mapped_column(String(50), nullable=False)
    member_count: Mapped[int | None] = mapped_column(Integer, nullable=True)


class OrgDirectoryMember(Base):
    """Clinician NPI listed under a Medicare group (cms_group only)."""

    __tablename__ = Tables.ORG_DIRECTORY_MEMBERS

    source_id: Mapped[str] = mapped_column(String(20), primary_key=True)  # group PAC ID
    npi: Mapped[str] = mapped_column(CHAR(10), primary_key=True, index=True)
