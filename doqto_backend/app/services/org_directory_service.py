"""Organization lookup against the public directory (org_directory).

Local rows come from CMS (scripts/import_org_directory.py). When a search
finds little locally, the NPPES registry's organizations (NPI-2) are asked
live and the usable hits are cached into org_directory as source 'nppes', so
creating an org always references a row we hold.

Ranking mirrors people search: ILIKE filters always; similarity() orders only
when pg_trgm is installed (the test schema has no extension).
"""
from __future__ import annotations

import re
from dataclasses import dataclass

import httpx
from sqlalchemy import and_, func, or_, select, text
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.enums import PracticeType
from app.models import Organization, OrgDirectoryEntry, OrgDirectoryMember

SOURCE_CMS_GROUP = "cms_group"
SOURCE_CMS_HOSPITAL = "cms_hospital"
SOURCE_NPPES = "nppes"

SEARCH_LIMIT = 20
NPPES_FALLBACK_BELOW = 3  # ask NPPES when local search finds fewer than this
NPPES_URL = "https://npiregistry.cms.hhs.gov/api/"

_SUFFIXES = re.compile(
    r"[,\s]+(INC|INCORPORATED|LLC|L\.L\.C|PLLC|PC|P\.C|PA|P\.A|LLP|PLC|LTD|CORP|CORPORATION|CO)\.?$",
    re.I,
)
_SMALL = {"of", "and", "the", "for", "at", "in", "on", "&"}
_KEEP_UPPER = {"md", "do", "pc", "usa", "ii", "iii", "iv", "ent", "obgyn", "ob/gyn"}
# NPPES organizations that are not practices doctors would message from.
_NPPES_SKIP = re.compile(
    r"pharmacy|hospice|laboratory|supplier|ambulance|home health|durable|"
    r"transportation|equipment|nursing facility|assisted living",
    re.I,
)


def display_name(legal: str) -> str:
    """'SAINT LUKE'S PHYSICIAN GROUP, INC.' -> "Saint Luke's Physician Group"."""
    name = legal.strip()
    while True:
        stripped = _SUFFIXES.sub("", name).strip()
        if stripped == name or not stripped:
            break
        name = stripped
    words = []
    for i, w in enumerate(name.split()):
        lw = w.lower()
        if lw in _KEEP_UPPER:
            words.append(w.upper())
        elif i and lw in _SMALL:
            words.append(lw)
        else:
            words.append(re.sub(r"(^|[-/])(\w)", lambda m: m.group(1) + m.group(2).upper(), lw))
    return " ".join(words)


@dataclass(frozen=True)
class DirectoryHit:
    entry: OrgDirectoryEntry
    you_are_listed: bool
    doqto_org: Organization | None


async def _hits(
    db: AsyncSession, entries: list[OrgDirectoryEntry], npi: str | None
) -> list[DirectoryHit]:
    if not entries:
        return []
    group_ids = [e.source_id for e in entries if e.source == SOURCE_CMS_GROUP]
    listed: set[str] = set()
    if npi and group_ids:
        listed = set(
            (
                await db.scalars(
                    select(OrgDirectoryMember.source_id).where(
                        OrgDirectoryMember.npi == npi,
                        OrgDirectoryMember.source_id.in_(group_ids),
                    )
                )
            ).all()
        )
    orgs = {
        (o.directory_source, o.directory_id): o
        for o in (
            await db.scalars(
                select(Organization).where(
                    Organization.directory_id.in_([e.source_id for e in entries])
                )
            )
        ).all()
    }
    return [
        DirectoryHit(
            entry=e,
            you_are_listed=e.source == SOURCE_CMS_GROUP and e.source_id in listed,
            doqto_org=orgs.get((e.source, e.source_id)),
        )
        for e in entries
    ]


async def fetch_nppes(query: str, state: str | None) -> list[dict]:
    """Raw NPPES organization results. Patched in tests."""
    params = {
        "version": "2.1",
        "enumeration_type": "NPI-2",
        "organization_name": f"{query}*",
        "limit": "20",
    }
    if state:
        params["state"] = state
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(NPPES_URL, params=params)
        return resp.json().get("results", []) or []
    except (httpx.HTTPError, ValueError):
        return []  # lookup is a convenience; manual entry still works


def _nppes_entries(results: list[dict]) -> list[dict]:
    rows: dict[tuple[str, str], dict] = {}
    for r in results:
        basic = r.get("basic") or {}
        legal = (basic.get("organization_name") or "").strip()
        if not legal or basic.get("organizational_subpart") == "YES":
            continue
        primary = next((t for t in r.get("taxonomies", []) if t.get("primary")), {})
        desc = primary.get("desc") or ""
        if _NPPES_SKIP.search(desc):
            continue
        loc = next(
            (a for a in r.get("addresses", []) if a.get("address_purpose") == "LOCATION"), {}
        )
        city = (loc.get("city") or "").title() or None
        row = {
            "source": SOURCE_NPPES,
            "source_id": str(r.get("number")),
            "name": legal[:255],
            "display_name": display_name(legal)[:255],
            "city": city,
            "state": (loc.get("state") or "")[:2] or None,
            "practice_type": (
                PracticeType.COMMUNITY_HOSPITAL.value
                if "hospital" in desc.lower()
                else PracticeType.INDEPENDENT.value
            ),
            "member_count": None,
        }
        rows.setdefault((row["display_name"].lower(), city or ""), row)  # dedupe name+city
    return list(rows.values())


class OrgDirectoryService:
    @staticmethod
    async def search(
        *, db: AsyncSession, query: str, state: str | None, npi: str | None
    ) -> list[DirectoryHit]:
        q = query.strip()
        if len(q) < 2:
            return []
        has_trgm = bool(
            await db.scalar(text("SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'"))
        )
        # Every word must appear, ignoring apostrophes ("saint lukes" finds
        # "Saint Luke's"); with pg_trgm, close spellings match too.
        bare = func.replace(OrgDirectoryEntry.display_name, "'", "")
        words = and_(*(bare.ilike(f"%{w}%") for w in q.replace("'", "").split()))
        match = or_(words, OrgDirectoryEntry.display_name.op("%")(q)) if has_trgm else words
        stmt = select(OrgDirectoryEntry).where(match)
        if state:
            stmt = stmt.where(OrgDirectoryEntry.state == state.upper())
        order = [OrgDirectoryEntry.member_count.desc().nullslast(), OrgDirectoryEntry.display_name]
        if has_trgm:
            order.insert(0, func.similarity(OrgDirectoryEntry.display_name, q).desc())
        entries = list((await db.scalars(stmt.order_by(*order).limit(SEARCH_LIMIT))).all())

        if len(entries) < NPPES_FALLBACK_BELOW and len(q) >= 3:
            rows = _nppes_entries(await fetch_nppes(q, state))
            if rows:
                await db.execute(insert(OrgDirectoryEntry).values(rows).on_conflict_do_nothing())
                await db.commit()
                seen = {(e.source, e.source_id) for e in entries}
                more = (
                    await db.scalars(
                        select(OrgDirectoryEntry).where(
                            OrgDirectoryEntry.source == SOURCE_NPPES,
                            OrgDirectoryEntry.source_id.in_([r["source_id"] for r in rows]),
                        )
                    )
                ).all()
                entries += [e for e in more if (e.source, e.source_id) not in seen]
                entries = entries[:SEARCH_LIMIT]
        return await _hits(db, entries, npi)

    @staticmethod
    async def suggested(*, db: AsyncSession, npi: str | None) -> list[DirectoryHit]:
        """Groups CMS lists this clinician under, biggest first."""
        if not npi:
            return []
        entries = list(
            (
                await db.scalars(
                    select(OrgDirectoryEntry)
                    .join(
                        OrgDirectoryMember,
                        (OrgDirectoryMember.source_id == OrgDirectoryEntry.source_id)
                        & (OrgDirectoryEntry.source == SOURCE_CMS_GROUP),
                    )
                    .where(OrgDirectoryMember.npi == npi)
                    .order_by(OrgDirectoryEntry.member_count.desc().nullslast())
                    .limit(5)
                )
            ).all()
        )
        return await _hits(db, entries, npi)

    @staticmethod
    async def get(*, db: AsyncSession, source: str, source_id: str) -> OrgDirectoryEntry | None:
        return await db.get(OrgDirectoryEntry, (source, source_id))

    @staticmethod
    async def is_listed(*, db: AsyncSession, source: str, source_id: str, npi: str) -> bool:
        if source != SOURCE_CMS_GROUP:
            return False
        return bool(
            await db.scalar(
                select(OrgDirectoryMember.npi).where(
                    OrgDirectoryMember.source_id == source_id, OrgDirectoryMember.npi == npi
                )
            )
        )
