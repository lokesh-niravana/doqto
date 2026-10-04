"""Messaging connections needs no organization; groups still do."""
from __future__ import annotations

from app.core.enums import OrgStatus
from tests import helpers


async def test_no_org_doctor_messages_a_connection(client, db):
    alice = await helpers.create_user(db, full_name="Dr Alice")
    bob = await helpers.create_user(db, full_name="Dr Bob")
    await helpers.connect_users(db, alice, bob)
    h = await helpers.auth_headers(alice.id)

    r = await client.post(
        "/api/v1/conversations",
        json={"type": "direct", "member_ids": [str(bob.id)]},
        headers=h,
    )
    assert r.status_code == 200, r.text
    conv_id = r.json()["id"]

    send = await client.post(
        f"/api/v1/conversations/{conv_id}/messages", json={"content": "hi"}, headers=h
    )
    assert send.status_code == 200, send.text

    # Tapping the same person again reopens the same chat.
    again = await client.post(
        "/api/v1/conversations",
        json={"type": "direct", "member_ids": [str(bob.id)]},
        headers=h,
    )
    assert again.json()["id"] == conv_id


async def test_no_org_doctor_cannot_message_a_stranger(client, db):
    alice = await helpers.create_user(db, full_name="Dr Alice")
    carol = await helpers.create_user(db, full_name="Dr Carol")
    r = await client.post(
        "/api/v1/conversations",
        json={"type": "direct", "member_ids": [str(carol.id)]},
        headers=await helpers.auth_headers(alice.id),
    )
    assert r.status_code == 403
    assert r.json()["detail"] == "not_connected"


async def test_groups_still_need_an_org(client, db):
    alice = await helpers.create_user(db)
    bob = await helpers.create_user(db)
    carol = await helpers.create_user(db)
    r = await client.post(
        "/api/v1/conversations",
        json={"type": "group", "name": "Team", "member_ids": [str(bob.id), str(carol.id)]},
        headers=await helpers.auth_headers(alice.id),
    )
    assert r.status_code == 400
    assert r.json()["detail"] == "user_not_in_any_org"


async def test_group_uses_the_active_org_over_a_pending_one(client, db):
    active = await helpers.create_org(db)
    pending = await helpers.create_org(db, status=OrgStatus.PENDING)
    alice, bob, carol = [await helpers.create_user(db) for _ in range(3)]
    await helpers.add_org_member(db, pending, alice)
    for u in (alice, bob, carol):
        await helpers.add_org_member(db, active, u)

    r = await client.post(
        "/api/v1/conversations",
        json={"type": "group", "name": "Team", "member_ids": [str(bob.id), str(carol.id)]},
        headers=await helpers.auth_headers(alice.id),
    )
    assert r.status_code == 200, r.text
    assert r.json()["org_id"] == str(active.id)
