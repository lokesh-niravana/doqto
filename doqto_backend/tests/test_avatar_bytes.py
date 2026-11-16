"""Stable avatar endpoints (2026-11-09): GET /users/{id}/avatar and
GET /groups/{id}/avatar stream the stored picture under the same audience
rules as the profile / group reads, with an ETag the app can revalidate.
Presigned links expire after five minutes and the app painted them from
cached state far older than that, so pictures kept vanishing."""

from __future__ import annotations

from sqlalchemy import select

from app.core.enums import ProfileFieldVisibility
from app.models import Group, UserPrivacySettings
from tests import helpers

USERS = "/api/v1/users"
PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32


async def _user(db, org, name):
    u = await helpers.create_user(db, full_name=name)
    if org is not None:
        await helpers.add_org_member(db, org, u)
    return u, await helpers.auth_headers(u.id)


async def test_user_avatar_bytes_cache_headers_and_audience(client, db, fake_s3):
    org = await helpers.create_org(db)
    owner, oh = await _user(db, org, "Dr Owner")
    stranger, sh = await _user(db, None, "Dr Stranger")
    colleague, colh = await _user(db, org, "Dr Colleague")

    # No picture yet: 404 (the app shows initials).
    assert (await client.get(f"{USERS}/{owner.id}/avatar", headers=sh)).status_code == 404

    owner.avatar_url = "avatars/owner/pic.png"
    await db.commit()
    fake_s3.put("avatars/owner/pic.png", PNG)

    r = await client.get(f"{USERS}/{owner.id}/avatar", headers=sh)
    assert r.status_code == 200, r.text
    assert r.content == PNG
    assert r.headers["content-type"].startswith("image/png")
    assert r.headers["cache-control"] == "private, max-age=86400"
    etag = r.headers["etag"]
    assert etag
    r2 = await client.get(f"{USERS}/{owner.id}/avatar", headers={**sh, "If-None-Match": etag})
    assert r2.status_code == 304

    # Own picture always renders.
    assert (await client.get(f"{USERS}/{owner.id}/avatar", headers=oh)).status_code == 200

    # Connections-only photo: the stranger loses it, the colleague keeps it.
    privacy = await db.scalar(
        select(UserPrivacySettings).where(UserPrivacySettings.user_id == owner.id)
    )
    if privacy is None:
        privacy = UserPrivacySettings(user_id=owner.id)
        db.add(privacy)
    privacy.profile_photo_visibility = ProfileFieldVisibility.CONNECTIONS
    await db.commit()
    assert (await client.get(f"{USERS}/{owner.id}/avatar", headers=sh)).status_code == 404
    assert (await client.get(f"{USERS}/{owner.id}/avatar", headers=colh)).status_code == 200

    # Unauthenticated: never.
    assert (await client.get(f"{USERS}/{owner.id}/avatar")).status_code in (401, 403)


async def test_group_avatar_bytes_for_members_and_invitees_only(client, db, fake_s3):
    owner, oh = await _user(db, None, "Dr Owner")
    invitee, ih = await _user(db, None, "Dr Invitee")
    outsider, xh = await _user(db, None, "Dr Outsider")
    await helpers.connect_users(db, owner, invitee)  # direct invites need a relationship
    r = await client.post(
        "/api/v1/groups",
        json={"name": "Rounds", "post_policy": "all_members", "member_dm_policy": "request"},
        headers=oh,
    )
    assert r.status_code == 201, r.text
    gid = r.json()["id"]
    group = await db.scalar(select(Group).where(Group.id == gid))
    group.avatar_url = "groups/g/pic.jpg"
    await db.commit()
    fake_s3.put("groups/g/pic.jpg", b"\xff\xd8jpeg")

    r = await client.post(f"/api/v1/groups/{gid}/invites", json={"user_id": str(invitee.id)}, headers=oh)
    assert r.status_code == 201, r.text
    # The invite row names the invitee, so Group info can list pending invites.
    assert r.json()["invitee_name"] == "Dr Invitee"
    listed = (await client.get(f"/api/v1/groups/{gid}/invites", headers=oh)).json()
    assert [i["invitee_name"] for i in listed] == ["Dr Invitee"]

    assert (await client.get(f"/api/v1/groups/{gid}/avatar", headers=oh)).status_code == 200
    assert (await client.get(f"/api/v1/groups/{gid}/avatar", headers=ih)).status_code == 200
    assert (await client.get(f"/api/v1/groups/{gid}/avatar", headers=xh)).status_code == 404
