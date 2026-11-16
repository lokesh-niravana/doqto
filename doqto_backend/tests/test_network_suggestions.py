"""Recommended for you: who is suggested, in what order, and who never is."""
from __future__ import annotations

from app.models import Block, ConnectionInvitation, UserPrivacySettings
from tests import helpers

URL = "/api/v1/network/suggestions"


async def _names(client, viewer) -> list[tuple[str, str | None]]:
    r = await client.get(URL, headers=await helpers.auth_headers(viewer.id))
    assert r.status_code == 200, r.text
    return [(c["full_name"], c["reason"]) for c in r.json()["data"]]


async def test_ranked_colleague_then_mutuals_then_specialty_and_place(client, db):
    me = await helpers.create_user(
        db, full_name="Dr Me", specialty="Cardiology", city="Leawood", state="KS"
    )
    friend = await helpers.create_user(db, full_name="Dr Friend")
    await helpers.connect_users(db, me, friend)

    colleague = await helpers.create_user(db, full_name="Dr Colleague")
    org = await helpers.create_org(db)
    await helpers.add_org_member(db, org, me)
    await helpers.add_org_member(db, org, colleague)

    fof = await helpers.create_user(db, full_name="Dr Friend Of Friend")
    await helpers.connect_users(db, friend, fof)
    await helpers.create_user(
        db, full_name="Dr Same Specialty Nearby", specialty="cardiology", state="KS"
    )
    await helpers.create_user(db, full_name="Dr Same Specialty", specialty="Cardiology")
    await helpers.create_user(db, full_name="Dr Nearby", state="KS")
    await helpers.create_user(db, full_name="Dr Stranger", specialty="Dermatology")

    got = await _names(client, me)
    assert got == [
        ("Dr Colleague", "colleague"),
        ("Dr Friend Of Friend", "mutual"),
        ("Dr Same Specialty Nearby", "specialty_nearby"),
        ("Dr Same Specialty", "specialty"),
        ("Dr Nearby", "nearby"),
        ("Dr Stranger", "new_member"),
    ]
    # Already connected: never suggested.
    assert "Dr Friend" not in [n for n, _ in got]


async def test_mutual_count_is_returned(client, db):
    me = await helpers.create_user(db, full_name="Dr Me")
    a = await helpers.create_user(db)
    b = await helpers.create_user(db)
    target = await helpers.create_user(db, full_name="Dr Two Mutuals")
    for f in (a, b):
        await helpers.connect_users(db, me, f)
        await helpers.connect_users(db, f, target)

    r = await client.get(URL, headers=await helpers.auth_headers(me.id))
    top = r.json()["data"][0]
    assert top["full_name"] == "Dr Two Mutuals"
    assert top["mutual_count"] == 2
    assert top["degree"] == "2nd"
    assert "npi_number" not in top and "phone" not in top


async def test_excludes_pending_invites_blocks_privacy_and_dismissed(client, db):
    me = await helpers.create_user(db, full_name="Dr Me")
    sent = await helpers.create_user(db, full_name="Dr Sent")
    received = await helpers.create_user(db, full_name="Dr Received")
    blocked = await helpers.create_user(db, full_name="Dr Blocked")
    blocker = await helpers.create_user(db, full_name="Dr Blocker")
    hidden = await helpers.create_user(db, full_name="Dr Hidden")
    conn_only = await helpers.create_user(db, full_name="Dr Connections Only")
    dismissed = await helpers.create_user(db, full_name="Dr Dismissed")
    await helpers.create_user(db, full_name="Dr Visible")

    db.add_all([
        ConnectionInvitation(sender_id=me.id, recipient_id=sent.id, status="pending"),
        ConnectionInvitation(sender_id=received.id, recipient_id=me.id, status="pending"),
        Block(blocker_id=me.id, blocked_id=blocked.id),
        Block(blocker_id=blocker.id, blocked_id=me.id),
        UserPrivacySettings(user_id=hidden.id, discoverability="nobody"),
        UserPrivacySettings(user_id=conn_only.id, discoverability="connections"),
    ])
    await db.commit()

    h = await helpers.auth_headers(me.id)
    r = await client.post(f"{URL}/{dismissed.id}/dismiss", headers=h)
    assert r.status_code == 200, r.text
    # Dismissing twice is fine.
    assert (await client.post(f"{URL}/{dismissed.id}/dismiss", headers=h)).status_code == 200

    assert [n for n, _ in await _names(client, me)] == ["Dr Visible"]


async def test_dismiss_rejects_self_and_unknown(client, db):
    me = await helpers.create_user(db)
    h = await helpers.auth_headers(me.id)
    assert (await client.post(f"{URL}/{me.id}/dismiss", headers=h)).status_code == 404
    unknown = "00000000-0000-0000-0000-000000000001"
    assert (await client.post(f"{URL}/{unknown}/dismiss", headers=h)).status_code == 404


async def test_pages_with_a_cursor(client, db):
    me = await helpers.create_user(db)
    for i in range(3):
        await helpers.create_user(db, full_name=f"Dr {i}")
    h = await helpers.auth_headers(me.id)
    first = (await client.get(URL, params={"limit": 2}, headers=h)).json()
    assert len(first["data"]) == 2 and first["next_cursor"] == "2"
    rest = (
        await client.get(URL, params={"limit": 2, "cursor": "2"}, headers=h)
    ).json()
    assert len(rest["data"]) == 1 and rest["next_cursor"] is None


async def test_unfinished_sign_ups_are_never_suggested_or_found(client, db):
    # Verified a phone, never filled in their details: no name, PENDING NPI.
    me = await helpers.create_user(db, full_name="Dr Me", specialty="Cardiology")
    ghost = await helpers.create_user(db, full_name="", specialty="Cardiology")
    ghost.npi_number = "PENDING01"
    half = await helpers.create_user(db, full_name="Dr Half Done", specialty="Cardiology")
    half.npi_number = "PENDING02"
    await helpers.create_user(db, full_name="Dr Real", specialty="Cardiology")
    await db.commit()

    assert [n for n, _ in await _names(client, me)] == ["Dr Real"]
    r = await client.get(
        "/api/v1/people/search", params={"q": "Dr"},
        headers=await helpers.auth_headers(me.id),
    )
    assert [c["full_name"] for c in r.json()["data"]] == ["Dr Real"]
