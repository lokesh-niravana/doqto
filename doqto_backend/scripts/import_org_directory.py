"""Refresh org_directory from CMS public data (monthly; CMS refreshes monthly).

Sources (free, no key):
- Doctors and Clinicians national file (dataset mj5m-pzi6): one row per
  clinician x location; rows with an org_pac_id become Medicare group
  practices, and each row's NPI is listed under its group.
- Hospital General Information (dataset xubh-q36u): ~5.4k hospitals.

The CSV URLs come from the CMS metastore so a monthly re-publish is followed
automatically. The clinician file is ~840 MB: it is streamed, never held.

Replaces the cms_* rows and all group members in one transaction; NPPES rows
cached by live search are left alone. Orgs already created from an entry keep
their directory reference even if CMS drops the entry.

    cd doqto_backend && source venv/bin/activate
    python -m scripts.import_org_directory
    # prod: run as a one-off ECS task with the backend image and this command
"""
from __future__ import annotations

import asyncio
import csv
import io
from collections import Counter
from collections.abc import AsyncIterator, Iterable

import httpx
from sqlalchemy import text

from app.core.enums import PracticeType
from app.db.postgres import SessionLocal
from app.services.org_directory_service import (
    SOURCE_CMS_GROUP,
    SOURCE_CMS_HOSPITAL,
    display_name,
)

METASTORE = "https://data.cms.gov/provider-data/api/1/metastore/schemas/dataset/items/{}"
CLINICIANS = "mj5m-pzi6"
HOSPITALS = "xubh-q36u"
MEMBER_BATCH = 50_000


class GroupAggregator:
    """Folds clinician rows into one entry per group plus (group, npi) pairs."""

    def __init__(self) -> None:
        self.names: dict[str, str] = {}
        self.counts: dict[str, int] = {}
        self.places: dict[str, Counter] = {}

    def add(self, row: dict) -> tuple[str, str] | None:
        pac = (row.get("org_pac_id") or "").strip()
        name = (row.get("Facility Name") or "").strip()
        npi = (row.get("NPI") or "").strip()
        if not pac or not name:
            return None
        self.names.setdefault(pac, name)
        try:
            self.counts[pac] = max(self.counts.get(pac, 0), int(row.get("num_org_mem") or 0))
        except ValueError:
            pass
        city = (row.get("City/Town") or "").strip()
        state = (row.get("State") or "").strip()
        if city and len(state) == 2:
            places = self.places.setdefault(pac, Counter())
            if len(places) < 50 or (city, state) in places:  # bound memory on huge systems
                places[(city, state)] += 1
        return (pac, npi) if len(npi) == 10 else None

    def entries(self) -> list[dict]:
        out = []
        for pac, name in self.names.items():
            (city, state), _ = (self.places.get(pac) or Counter({(None, None): 1})).most_common(1)[0]
            members = self.counts.get(pac) or None
            out.append(
                {
                    "source": SOURCE_CMS_GROUP,
                    "source_id": pac,
                    "name": name[:255],
                    "display_name": display_name(name)[:255],
                    "city": city.title() if city else None,
                    "state": state,
                    "practice_type": (
                        PracticeType.SPECIALTY_GROUP.value
                        if (members or 0) >= 2
                        else PracticeType.INDEPENDENT.value
                    ),
                    "member_count": members,
                }
            )
        return out


def hospital_entries(rows: Iterable[dict]) -> list[dict]:
    out = []
    for r in rows:
        ccn, name = (r.get("Facility ID") or "").strip(), (r.get("Facility Name") or "").strip()
        if not ccn or not name:
            continue
        state = (r.get("State") or "").strip()
        out.append(
            {
                "source": SOURCE_CMS_HOSPITAL,
                "source_id": ccn,
                "name": name[:255],
                "display_name": display_name(name)[:255],
                "city": (r.get("City/Town") or "").strip().title() or None,
                "state": state if len(state) == 2 else None,
                "practice_type": PracticeType.COMMUNITY_HOSPITAL.value,
                "member_count": None,
            }
        )
    return out


async def _csv_url(client: httpx.AsyncClient, dataset: str) -> str:
    meta = (await client.get(METASTORE.format(dataset))).json()
    return meta["distribution"][0]["downloadURL"]


async def _rows(client: httpx.AsyncClient, url: str) -> AsyncIterator[dict]:
    async with client.stream("GET", url) as resp:
        resp.raise_for_status()
        header: list[str] | None = None
        async for line in resp.aiter_lines():
            if not line:
                continue
            values = next(csv.reader(io.StringIO(line)))
            if header is None:
                header = values
                continue
            yield dict(zip(header, values))


async def main() -> None:
    groups = GroupAggregator()
    async with httpx.AsyncClient(timeout=httpx.Timeout(60, read=300), follow_redirects=True) as client:
        clinicians_url = await _csv_url(client, CLINICIANS)
        hospitals_url = await _csv_url(client, HOSPITALS)
        hospitals = hospital_entries([r async for r in _rows(client, hospitals_url)])

        async with SessionLocal() as db:
            # Open the transaction through SQLAlchemy first, so the raw
            # asyncpg calls below (temp table, COPY) run inside it.
            await db.execute(text("SELECT 1"))
            raw = (await (await db.connection()).get_raw_connection()).driver_connection
            await raw.execute(
                "CREATE TEMP TABLE import_members (source_id varchar(20), npi char(10)) "
                "ON COMMIT DROP"
            )
            batch: list[tuple[str, str]] = []
            seen = 0
            async for row in _rows(client, clinicians_url):
                seen += 1
                pair = groups.add(row)
                if pair:
                    batch.append(pair)
                if len(batch) >= MEMBER_BATCH:
                    await raw.copy_records_to_table("import_members", records=batch)
                    batch = []
            if batch:
                await raw.copy_records_to_table("import_members", records=batch)

            entries = groups.entries() + hospitals
            await db.execute(
                text("DELETE FROM org_directory WHERE source IN (:g, :h)"),
                {"g": SOURCE_CMS_GROUP, "h": SOURCE_CMS_HOSPITAL},
            )
            cols = ["source", "source_id", "name", "display_name", "city", "state",
                    "practice_type", "member_count"]
            await raw.copy_records_to_table(
                "org_directory", records=[tuple(e[c] for c in cols) for e in entries], columns=cols
            )
            await raw.execute("TRUNCATE org_directory_members")
            await raw.execute(
                "INSERT INTO org_directory_members (source_id, npi) "
                "SELECT DISTINCT source_id, npi FROM import_members"
            )
            members = await raw.fetchval("SELECT count(*) FROM org_directory_members")
            await db.commit()

    print(
        f"clinician rows {seen:,} -> groups {len(groups.names):,}, "
        f"group members {members:,}; hospitals {len(hospitals):,}"
    )


if __name__ == "__main__":
    asyncio.run(main())
