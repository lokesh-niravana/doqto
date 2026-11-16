"""Organization lookup (org_directory) and the create/join rules built on it.

Spec: docs/superpowers/specs/2026-10-04-org-lookup-research.md and part 1 of
2026-10-04-create-org-and-dm-without-org-design.md.
"""
from __future__ import annotations

import pytest
from sqlalchemy import select

import app.services.org_directory_service as directory_module
from app.core.enums import OrgStatus
from app.models import Organization, OrgDirectoryEntry, OrgDirectoryMember, OrgMember
from app.services.org_directory_service import display_name
from scripts.import_org_directory import GroupAggregator, hospital_entries
from tests import helpers

ORGS = "/api/v1/orgs"


# ------------------------------------------------------------------ pure
@pytest.mark.parametrize(
    ("legal", "shown"),
    [
        ("SAINT LUKES PHYSICIAN GROUP INC", "Saint Lukes Physician Group"),
        ("SAINT LUKE'S CARDIOLOGY SERVICES, LLC", "Saint Luke's Cardiology Services"),
        ("UNIVERSITY OF KANSAS HOSPITAL AUTHORITY", "University of Kansas Hospital Authority"),
        ("JOHN SMITH MD PC", "John Smith MD"),
        ("MID-AMERICA CARDIOLOGY ASSOCIATES PA", "Mid-America Cardiology Associates"),
    ],
)
def test_display_name(legal, shown):
    assert display_name(legal) == shown


def test_group_aggregator_folds_rows_per_group():
    agg = GroupAggregator()
    rows = [
        {"NPI": "1111111111", "org_pac_id": "P1", "Facility Name": "ACME HEART LLC",
         "num_org_mem": "3", "City/Town": "LEAWOOD", "State": "KS"},
        {"NPI": "2222222222", "org_pac_id": "P1", "Facility Name": "ACME HEART LLC",
         "num_org_mem": "3", "City/Town": "LEAWOOD", "State": "KS"},
        {"NPI": "3333333333", "org_pac_id": "P1", "Facility Name": "ACME HEART LLC",
         "num_org_mem": "3", "City/Town": "OVERLAND PARK", "State": "KS"},
        {"NPI": "4444444444", "org_pac_id": "", "Facility Name": "", "City/Town": "X", "State": "MO"},
    ]
    pairs = [agg.add(r) for r in rows]
    assert pairs == [("P1", "1111111111"), ("P1", "2222222222"), ("P1", "3333333333"), None]
    [entry] = agg.entries()
    assert entry["display_name"] == "Acme Heart"
    assert (entry["city"], entry["state"]) == ("Leawood", "KS")  # most common location
    assert entry["member_count"] == 3
    assert entry["practice_type"] == "specialty_group"


def test_hospital_entries():
    [h] = hospital_entries(
        [{"Facility ID": "260062", "Facility Name": "SAINT LUKES NORTH HOSPITAL",
          "City/Town": "KANSAS CITY", "State": "MO"}]
    )
    assert h["source"] == "cms_hospital"
    assert h["practice_type"] == "community_hospital"
    assert h["city"] == "Kansas City"


# ------------------------------------------------------------------ helpers
async def _group(db, pac="P1", name="Riverside Cardiology", members=(), state="KS"):
    db.add(
        OrgDirectoryEntry(
            source="cms_group", source_id=pac, name=name.upper(), display_name=name,
            city="Leawood", state=state, practice_type="specialty_group",
            member_count=max(len(members), 2),
        )
    )
    for npi in members:
        db.add(OrgDirectoryMember(source_id=pac, npi=npi))
    await db.commit()


@pytest.fixture
def no_nppes(monkeypatch):
    calls = []

    async def fake(query, state):
        calls.append(query)
        return []

    monkeypatch.setattr(directory_module, "fetch_nppes", fake)
    return calls


# ------------------------------------------------------------------ search
async def test_search_and_suggested_flag_your_group(db, client, no_nppes):
    me = await helpers.create_user(db)
    await _group(db, members=[me.npi_number])
    await _group(db, pac="P2", name="Riverside Pediatrics")
    h = await helpers.auth_headers(me.id)

    r = await client.get(f"{ORGS}/directory/search", params={"q": "riverside"}, headers=h)
    assert r.status_code == 200, r.text
    by_id = {e["source_id"]: e for e in r.json()}
    assert set(by_id) == {"P1", "P2"}
    assert by_id["P1"]["you_are_listed"] is True
    assert by_id["P2"]["you_are_listed"] is False
    assert by_id["P1"]["doqto_org"] is None

    r = await client.get(f"{ORGS}/directory/suggested", headers=h)
    assert [e["source_id"] for e in r.json()] == ["P1"]


async def test_search_falls_back_to_nppes_and_caches(db, client, monkeypatch):
    me = await helpers.create_user(db)

    async def fake(query, state):
        return [
            {
                "number": "1801031414",
                "basic": {"organization_name": "SAINT LUKE'S CARDIOLOGY SERVICES, LLC",
                          "organizational_subpart": "NO"},
                "addresses": [{"address_purpose": "LOCATION", "city": "KANSAS CITY", "state": "MO"}],
                "taxonomies": [{"primary": True, "desc": "Internal Medicine, Cardiovascular Disease"}],
            },
            {
                "number": "1023860962",
                "basic": {"organization_name": "SAINT LUKE'S HOME CARE AND HOSPICE",
                          "organizational_subpart": "YES"},
                "addresses": [], "taxonomies": [{"primary": True, "desc": "Hospice Care"}],
            },
        ]

    monkeypatch.setattr(directory_module, "fetch_nppes", fake)
    r = await client.get(
        f"{ORGS}/directory/search", params={"q": "saint luke"},
        headers=await helpers.auth_headers(me.id),
    )
    assert [e["name"] for e in r.json()] == ["Saint Luke's Cardiology Services"]
    cached = await db.get(OrgDirectoryEntry, ("nppes", "1801031414"))
    assert cached is not None and cached.state == "MO"


# ------------------------------------------------------------------ create
async def _create(client, user, **body):
    payload = {"name": "Riverside Cardiology", "practice_type": "specialty_group"}
    payload.update(body)
    return await client.post(ORGS, json=payload, headers=await helpers.auth_headers(user.id))


async def test_create_from_your_group_is_verified_at_once(db, client):
    me = await helpers.create_user(db)
    await _group(db, members=[me.npi_number])
    r = await _create(client, me, directory_source="cms_group", directory_id="P1")
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "active"
    assert r.json()["city"] == "Leawood"  # filled from the directory


async def test_create_from_someone_elses_group_stays_pending(db, client):
    me = await helpers.create_user(db)
    await _group(db, members=["9999999999"])
    r = await _create(client, me, directory_source="cms_group", directory_id="P1")
    assert r.status_code == 200
    assert r.json()["status"] == "pending"


async def test_one_pending_org_per_creator(db, client):
    me = await helpers.create_user(db)
    assert (await _create(client, me)).status_code == 200
    r = await _create(client, me, name="Second Clinic")
    assert r.status_code == 409
    assert r.json()["detail"] == "org_pending_exists"


async def test_same_directory_entry_cannot_be_created_twice(db, client):
    a = await helpers.create_user(db)
    b = await helpers.create_user(db)
    await _group(db, members=[a.npi_number, b.npi_number])
    assert (await _create(client, a, directory_source="cms_group", directory_id="P1")).status_code == 200
    r = await _create(client, b, directory_source="cms_group", directory_id="P1")
    assert r.status_code == 409
    assert r.json()["detail"] == "org_exists"

    # The search now points b at the existing org instead.
    r = await client.get(
        f"{ORGS}/directory/search", params={"q": "riverside"},
        headers=await helpers.auth_headers(b.id),
    )
    assert r.json()[0]["doqto_org"]["name"] == "Riverside Cardiology"


async def test_unknown_directory_entry_is_rejected(db, client):
    me = await helpers.create_user(db)
    r = await _create(client, me, directory_source="cms_group", directory_id="NOPE")
    assert r.status_code == 400
    assert r.json()["detail"] == "directory_entry_not_found"


# ------------------------------------------------------------------ join
async def test_join_by_directory_needs_your_npi_listed(db, client):
    admin = await helpers.create_user(db)
    colleague = await helpers.create_user(db)
    stranger = await helpers.create_user(db)
    await _group(db, members=[admin.npi_number, colleague.npi_number])
    created = await _create(client, admin, directory_source="cms_group", directory_id="P1")
    org_id = created.json()["id"]
    ref = {"directory_source": "cms_group", "directory_id": "P1"}

    r = await client.post(
        f"{ORGS}/directory/join", json=ref, headers=await helpers.auth_headers(colleague.id)
    )
    assert r.status_code == 200, r.text
    assert await db.scalar(
        select(OrgMember.org_role).where(
            OrgMember.org_id == r.json()["id"], OrgMember.user_id == colleague.id
        )
    ) == "doctor"

    r = await client.post(
        f"{ORGS}/directory/join", json=ref, headers=await helpers.auth_headers(stranger.id)
    )
    assert r.status_code == 403
    assert r.json()["detail"] == "npi_not_listed"
    assert str(created.json()["id"]) == org_id


# ------------------------------------------------------------------ groups wait
async def test_groups_wait_for_verification(db, client):
    me = await helpers.create_user(db)
    other = await helpers.create_user(db)
    org = await helpers.create_org(db, status=OrgStatus.PENDING)
    await helpers.add_org_member(db, org, me)
    await helpers.add_org_member(db, org, other)
    h = await helpers.auth_headers(me.id)

    r = await client.post(
        "/api/v1/conversations",
        json={"type": "group", "name": "Rounds", "member_ids": [str(other.id)]},
        headers=h,
    )
    assert r.status_code == 403
    assert r.json()["detail"] == "org_not_verified"

    r = await client.post(
        "/api/v1/groups",
        json={"name": "Rounds", "post_policy": "all_members", "member_dm_policy": "request",
              "org_id": str(org.id)},
        headers=h,
    )
    assert r.status_code == 403
    assert r.json()["detail"] == "org_not_verified"

    org.status = OrgStatus.ACTIVE
    await db.commit()
    r = await client.post(
        "/api/v1/conversations",
        json={"type": "group", "name": "Rounds", "member_ids": [str(other.id)]},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert await db.scalar(select(Organization.status).where(Organization.id == org.id)) == "active"
