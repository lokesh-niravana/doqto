"""Invite a colleague: NPI lookup statuses, recording invites, and the
connection made when the invitee registers."""
from __future__ import annotations

from sqlalchemy import select

from app.models import AppInvite, Connection, ConnectionInvitation, Notification, UserPrivacySettings
from app.services import invite_service
from tests import helpers

LOOKUP = "/api/v1/people/npi-lookup"
INVITES = "/api/v1/people/invites"


def _nppes(npi: str, first: str, last: str = "PATEL") -> dict:
    return {
        "number": int(npi),
        "basic": {"first_name": first, "last_name": last, "credential": "M.D."},
        "taxonomies": [{"primary": True, "code": "207Q00000X", "desc": "Family Medicine"}],
        "addresses": [{"address_purpose": "LOCATION", "city": "QUINCY", "state": "MA"}],
    }


async def test_lookup_marks_who_is_on_doqto(client, db, monkeypatch):
    me = await helpers.create_user(db, full_name="Dr Me")
    friend = await helpers.create_user(db, full_name="Dr Friend")
    await helpers.connect_users(db, me, friend)
    asked = await helpers.create_user(db, full_name="Dr Asked")
    stranger = await helpers.create_user(db, full_name="Dr Stranger")
    hidden = await helpers.create_user(db, full_name="Dr Hidden")
    db.add_all([
        ConnectionInvitation(sender_id=me.id, recipient_id=asked.id, status="pending"),
        UserPrivacySettings(user_id=hidden.id, discoverability="nobody"),
    ])
    await db.commit()

    seen: list[dict] = []

    async def fake(params):
        seen.append(params)
        return [
            _nppes(me.npi_number, "ME"),
            _nppes(friend.npi_number, "FRIEND"),
            _nppes(asked.npi_number, "ASKED"),
            _nppes(stranger.npi_number, "STRANGER"),
            _nppes(hidden.npi_number, "HIDDEN"),
            _nppes("1999999999", "NEEL"),
        ]

    monkeypatch.setattr(invite_service, "fetch_nppes_people", fake)
    r = await client.get(
        LOOKUP, params={"q": "Dr. Patel", "state": "ma"},
        headers=await helpers.auth_headers(me.id),
    )
    assert r.status_code == 200, r.text
    got = {h["name"]: (h["status"], h["user_id"]) for h in r.json()}
    # One word: last name or first name.
    assert seen == [
        {"last_name": "Patel*", "limit": "200", "state": "MA"},
        {"first_name": "Patel*", "limit": "200", "state": "MA"},
    ]
    assert got == {
        "Friend Patel, MD": ("message", str(friend.id)),
        "Asked Patel, MD": ("requested", str(asked.id)),
        "Stranger Patel, MD": ("connect", str(stranger.id)),
        # Hidden from search: never revealed as being on Doqto.
        "Hidden Patel, MD": ("invite", None),
        "Neel Patel, MD": ("invite", None),
    }
    # A first name narrows to current first names too.
    r = await client.get(LOOKUP, params={"q": "Neel Patel"}, headers=await helpers.auth_headers(me.id))
    assert [h["name"] for h in r.json()] == ["Neel Patel, MD"]
    neel = next(h for h in r.json() if h["status"] == "invite" and h["npi"] == "1999999999")
    assert neel["specialty"] == "Family Medicine" and neel["location"] == "Quincy, MA"


async def test_ten_digits_search_by_number(client, db, monkeypatch):
    me = await helpers.create_user(db)
    seen: list[dict] = []

    async def fake(params):
        seen.append(params)
        return []

    monkeypatch.setattr(invite_service, "fetch_nppes_people", fake)
    await client.get(LOOKUP, params={"q": "1999999999"}, headers=await helpers.auth_headers(me.id))
    assert seen == [{"number": "1999999999"}]


async def test_invitee_registering_connects_and_notifies_inviter(client, db):
    inviter = await helpers.create_user(db, full_name="Dr Inviter")
    other = await helpers.create_user(db, full_name="Dr Other Inviter")
    for u in (inviter, other):
        r = await client.post(
            INVITES, json={"npi": "1999999999"}, headers=await helpers.auth_headers(u.id)
        )
        assert r.status_code == 200, r.text
    # Inviting twice is harmless.
    await client.post(INVITES, json={"npi": "1999999999"}, headers=await helpers.auth_headers(inviter.id))
    assert (await client.post(
        INVITES, json={"npi": "P123"}, headers=await helpers.auth_headers(inviter.id)
    )).status_code == 422

    inviter_id, other_id = inviter.id, other.id
    newbie = await helpers.create_user(db, full_name="")
    newbie.npi_number = "P000000001"
    await db.commit()
    r = await client.post(
        "/api/v1/auth/register",
        json={"full_name": "Dr Neel Patel", "npi_number": "1999999999"},
        headers=await helpers.auth_headers(newbie.id),
    )
    assert r.status_code == 200, r.text

    newbie_id = newbie.id
    db.expire_all()
    friends = set(
        (await db.scalars(
            select(Connection.connected_user_id).where(Connection.user_id == newbie_id)
        )).all()
    )
    assert friends == {inviter_id, other_id}
    notes = (await db.scalars(
        select(Notification).where(Notification.type == "invite_joined")
    )).all()
    assert {n.user_id for n in notes} == {inviter_id, other_id}
    assert all(n.payload["actor_name"] == "Dr Neel Patel" for n in notes)
    assert all(
        i.joined_at is not None for i in (await db.scalars(select(AppInvite))).all()
    )


async def test_only_physicians_under_their_current_name(client, db, monkeypatch):
    me = await helpers.create_user(db)
    pt = _nppes("1000000001", "PAT")
    pt["taxonomies"] = [{"primary": True, "code": "225100000X", "desc": "Physical Therapist"}]
    formerly = _nppes("1000000002", "ONCE", last="ADEDOKUN")
    now = _nppes("1000000003", "NOW")

    async def fake(params):
        if "first_name" in params:
            # First-name search for "Patel": Patel Shah is current, so kept.
            return [_nppes("1000000004", "PATEL", last="SHAH"), now]
        return [pt, formerly, now]

    monkeypatch.setattr(invite_service, "fetch_nppes_people", fake)
    r = await client.get(LOOKUP, params={"q": "Patel"}, headers=await helpers.auth_headers(me.id))
    assert [h["name"] for h in r.json()] == ["Now Patel, MD", "Patel Shah, MD"]
