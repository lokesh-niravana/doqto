"""Realtime sync: every mutation another user can observe publishes a
WebSocket event (post-commit), so the app never has to poll.

Each test swaps the `ws_manager` name in the module under test for a
recording fake — never `app.api.ws_manager` itself — and asserts on the
(recipients, event, payload) triples it captured.
"""
from __future__ import annotations

import uuid
from types import SimpleNamespace

import pytest
from sqlalchemy import select

import app.api.v1.orgs as orgs_module
import app.api.v1.users as users_module
import app.services.connection_service as connection_module
import app.services.group_service as group_service_module
from app.core.enums import (
    GroupMemberState,
    GroupRole,
    OrgStatus,
    UserRole,
    WsEventServer,
)
from app.models import ConversationMember, Group, GroupMember, Organization
from tests import helpers

NETWORK = "/api/v1/network"


# --------------------------------------------------------------------------- #
# recording fake
# --------------------------------------------------------------------------- #
def _recorder(monkeypatch, module):
    """Replace `module.ws_manager` with a fake whose publish_to_users records
    (set(user_ids), event, data). publish_org is swallowed."""
    sent: list[tuple[set[uuid.UUID], WsEventServer, dict]] = []

    async def publish_to_users(user_ids, event, data):
        sent.append((set(user_ids), event, data))

    async def publish_org(org_id, event, data):
        pass

    fake = SimpleNamespace(publish_to_users=publish_to_users, publish_org=publish_org)
    monkeypatch.setattr(module, "ws_manager", fake)
    return sent


def _of(sent, event: WsEventServer):
    return [(ids, data) for ids, ev, data in sent if ev == event]


@pytest.fixture
def connection_ws(monkeypatch):
    return _recorder(monkeypatch, connection_module)


@pytest.fixture
def org_ws(monkeypatch):
    # admin.py's verify/reject publish through orgs.publish_org_updated, so
    # the orgs module is the single patch point for every org_updated.
    return _recorder(monkeypatch, orgs_module)


@pytest.fixture
def group_ws(monkeypatch):
    # groups.py's PATCH route publishes via GroupService.publish_group_updated,
    # so group_service is the single patch point for every group_updated.
    return _recorder(monkeypatch, group_service_module)


@pytest.fixture
def users_ws(monkeypatch):
    return _recorder(monkeypatch, users_module)


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
async def _user(db, org, name):
    u = await helpers.create_user(db, full_name=name)
    if org is not None:
        await helpers.add_org_member(db, org, u)
    return u, await helpers.auth_headers(u.id)


async def _invite(client, headers, recipient):
    r = await client.post(
        f"{NETWORK}/invitations", json={"recipient_id": str(recipient.id)}, headers=headers
    )
    assert r.status_code == 201, r.text
    return r.json()["invitation"]["id"]


async def _super_admin(db):
    admin = await helpers.create_user(db, full_name="Dr Staff")
    admin.role = UserRole.SUPER_ADMIN
    await db.commit()
    return admin, await helpers.auth_headers(admin.id)


async def _create_group(client, headers, **overrides):
    body = {"name": "Rounds", "post_policy": "all_members", "member_dm_policy": "request"}
    body.update(overrides)
    r = await client.post("/api/v1/groups", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _add_members(db, gid, users, role=GroupRole.MEMBER):
    group = await db.scalar(select(Group).where(Group.id == gid))
    for u in users:
        db.add(
            GroupMember(
                group_id=group.id, user_id=u.id, role=role, state=GroupMemberState.ACTIVE
            )
        )
        db.add(ConversationMember(conversation_id=group.conversation_id, user_id=u.id))
    group.member_count += len(users)
    await db.commit()


# --------------------------------------------------------------------------- #
# Connections
# --------------------------------------------------------------------------- #
async def test_withdraw_tells_recipient(client, db, connection_ws):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, _ = await _user(db, org, "Dr B")
    inv_id = await _invite(client, ah, b)
    connection_ws.clear()

    r = await client.delete(f"{NETWORK}/invitations/{inv_id}", headers=ah)
    assert r.status_code == 200, r.text

    assert _of(connection_ws, WsEventServer.INVITATION_WITHDRAWN) == [
        ({b.id}, {"invitation_id": inv_id, "sender_id": str(a.id)})
    ]


async def test_ignore_is_silent(client, db, connection_ws):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")
    inv_id = await _invite(client, ah, b)
    connection_ws.clear()

    r = await client.post(f"{NETWORK}/invitations/{inv_id}/ignore", headers=bh)
    assert r.status_code == 200, r.text
    assert connection_ws == []


async def test_block_of_connected_pair_looks_like_a_removal(client, db, connection_ws):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")
    inv_id = await _invite(client, ah, b)
    r = await client.post(f"{NETWORK}/invitations/{inv_id}/accept", headers=bh)
    assert r.status_code == 200, r.text
    connection_ws.clear()

    r = await client.post(f"{NETWORK}/blocks/{b.id}", headers=ah)
    assert r.status_code == 200, r.text

    # Exactly one frame, identical to what remove_connection sends.
    assert connection_ws == [({b.id}, WsEventServer.CONNECTION_REMOVED, {"user_id": str(a.id)})]


async def test_block_with_outgoing_pending_invite_looks_like_a_withdraw(
    client, db, connection_ws
):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, _ = await _user(db, org, "Dr B")
    inv_id = await _invite(client, ah, b)
    connection_ws.clear()

    r = await client.post(f"{NETWORK}/blocks/{b.id}", headers=ah)
    assert r.status_code == 200, r.text

    assert connection_ws == [
        (
            {b.id},
            WsEventServer.INVITATION_WITHDRAWN,
            {"invitation_id": inv_id, "sender_id": str(a.id)},
        )
    ]


async def test_block_with_incoming_pending_invite_is_silent(client, db, connection_ws):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")
    await _invite(client, bh, a)  # B → A pending; A blocks B → ignored silently
    connection_ws.clear()

    r = await client.post(f"{NETWORK}/blocks/{b.id}", headers=ah)
    assert r.status_code == 200, r.text
    assert connection_ws == []


# --------------------------------------------------------------------------- #
# Orgs
# --------------------------------------------------------------------------- #
async def test_create_org_tells_creator(client, db, org_ws):
    creator, ch = await _user(db, None, "Dr Founder")
    r = await client.post("/api/v1/orgs", json={"name": "New Clinic"}, headers=ch)
    assert r.status_code == 200, r.text
    org_id = r.json()["id"]

    assert _of(org_ws, WsEventServer.ORG_UPDATED) == [
        ({creator.id}, {"org_id": org_id, "status": OrgStatus.PENDING.value})
    ]


@pytest.mark.parametrize(
    "action,body,expected_status",
    [
        ("verify", None, OrgStatus.ACTIVE),
        ("reject", {"reason": "Not a real practice"}, OrgStatus.SUSPENDED),
    ],
)
async def test_admin_verify_and_reject_tell_every_member(
    client, db, org_ws, action, body, expected_status
):
    org = await helpers.create_org(db, status=OrgStatus.PENDING)
    m1, _ = await _user(db, org, "Dr One")
    m2, _ = await _user(db, org, "Dr Two")
    outsider, _ = await _user(db, None, "Dr Out")
    _, admin_h = await _super_admin(db)

    r = await client.patch(f"/api/v1/admin/orgs/{org.id}/{action}", json=body, headers=admin_h)
    assert r.status_code == 200, r.text

    assert _of(org_ws, WsEventServer.ORG_UPDATED) == [
        ({m1.id, m2.id}, {"org_id": str(org.id), "status": expected_status.value})
    ]


async def test_join_org_tells_existing_and_new_members(client, db, org_ws):
    org = await helpers.create_org(db)
    m1, _ = await _user(db, org, "Dr One")
    newcomer, nh = await _user(db, None, "Dr New")

    r = await client.post("/api/v1/orgs/join", json={"invite_code": org.invite_code}, headers=nh)
    assert r.status_code == 200, r.text

    assert _of(org_ws, WsEventServer.ORG_UPDATED) == [
        ({m1.id, newcomer.id}, {"org_id": str(org.id), "status": OrgStatus.ACTIVE.value})
    ]


async def test_remove_member_tells_remaining_and_removed(client, db, org_ws):
    from app.core.enums import OrgRole

    org = await helpers.create_org(db)
    admin = await helpers.create_user(db, full_name="Dr Admin")
    await helpers.add_org_member(db, org, admin, role=OrgRole.ADMIN)
    admin_h = await helpers.auth_headers(admin.id)
    stays, _ = await _user(db, org, "Dr Stays")
    goes, _ = await _user(db, org, "Dr Goes")

    r = await client.delete(f"/api/v1/orgs/{org.id}/members/{goes.id}", headers=admin_h)
    assert r.status_code == 200, r.text

    assert _of(org_ws, WsEventServer.ORG_UPDATED) == [
        (
            {admin.id, stays.id, goes.id},
            {"org_id": str(org.id), "status": OrgStatus.ACTIVE.value},
        )
    ]


async def test_networking_settings_tell_members(client, db, org_ws):
    from app.core.enums import OrgRole

    org = await helpers.create_org(db)
    admin = await helpers.create_user(db, full_name="Dr Admin")
    await helpers.add_org_member(db, org, admin, role=OrgRole.ADMIN)
    admin_h = await helpers.auth_headers(admin.id)
    member, _ = await _user(db, org, "Dr Member")

    r = await client.patch(
        f"/api/v1/orgs/{org.id}/settings/networking",
        json={"external_networking_enabled": False},
        headers=admin_h,
    )
    assert r.status_code == 200, r.text

    assert _of(org_ws, WsEventServer.ORG_UPDATED) == [
        ({admin.id, member.id}, {"org_id": str(org.id), "status": OrgStatus.ACTIVE.value})
    ]

    # No-op PATCH → no commit, no event.
    org_ws.clear()
    r = await client.patch(
        f"/api/v1/orgs/{org.id}/settings/networking", json={}, headers=admin_h
    )
    assert r.status_code == 200, r.text
    assert org_ws == []


# --------------------------------------------------------------------------- #
# Groups
# --------------------------------------------------------------------------- #
@pytest.fixture
async def group_env(client, db):
    """Owner + admin + member in one verified org; group with all three active."""
    org = await helpers.create_org(db)
    owner, owner_h = await _user(db, org, "Dr Owner")
    admin, admin_h = await _user(db, org, "Dr Admin")
    member, member_h = await _user(db, org, "Dr Member")
    group = await _create_group(client, owner_h)
    gid = group["id"]
    await _add_members(db, gid, [admin], role=GroupRole.ADMIN)
    await _add_members(db, gid, [member])
    return SimpleNamespace(
        org=org,
        gid=gid,
        group_id=uuid.UUID(gid),
        owner=owner,
        owner_h=owner_h,
        admin=admin,
        admin_h=admin_h,
        member=member,
        member_h=member_h,
    )


def _group_updated(sent, env):
    return _of(sent, WsEventServer.GROUP_UPDATED)


async def test_change_role_tells_members(client, group_env, group_ws):
    env = group_env
    r = await client.patch(
        f"/api/v1/groups/{env.gid}/members/{env.member.id}",
        json={"role": "moderator"},
        headers=env.owner_h,
    )
    assert r.status_code == 200, r.text
    assert _group_updated(group_ws, env) == [
        ({env.owner.id, env.admin.id, env.member.id}, {"group_id": env.gid})
    ]


async def test_transfer_ownership_tells_members(client, group_env, group_ws):
    env = group_env
    r = await client.post(
        f"/api/v1/groups/{env.gid}/transfer-ownership",
        json={"user_id": str(env.admin.id)},
        headers=env.owner_h,
    )
    assert r.status_code == 200, r.text
    assert _group_updated(group_ws, env) == [
        ({env.owner.id, env.admin.id, env.member.id}, {"group_id": env.gid})
    ]


async def test_remove_member_tells_members_and_removed(client, group_env, group_ws):
    env = group_env
    r = await client.delete(
        f"/api/v1/groups/{env.gid}/members/{env.member.id}", headers=env.admin_h
    )
    assert r.status_code == 200, r.text
    # The pre-existing member_removed frame still goes out, then group_updated.
    assert [ev for _, ev, _ in group_ws] == [
        WsEventServer.MEMBER_REMOVED,
        WsEventServer.GROUP_UPDATED,
    ]
    assert _group_updated(group_ws, env) == [
        ({env.owner.id, env.admin.id, env.member.id}, {"group_id": env.gid})
    ]


async def test_ban_member_tells_members_and_banned(client, group_env, group_ws):
    env = group_env
    r = await client.post(
        f"/api/v1/groups/{env.gid}/members/{env.member.id}/ban", headers=env.admin_h
    )
    assert r.status_code == 200, r.text
    assert _group_updated(group_ws, env) == [
        ({env.owner.id, env.admin.id, env.member.id}, {"group_id": env.gid})
    ]


async def test_revoke_invite_tells_members_and_invitee(client, db, group_env, group_ws):
    env = group_env
    invitee, _ = await _user(db, env.org, "Dr Invitee")
    r = await client.post(
        f"/api/v1/groups/{env.gid}/invites",
        json={"user_id": str(invitee.id)},
        headers=env.owner_h,
    )
    assert r.status_code == 201, r.text
    invite_id = r.json()["id"]
    group_ws.clear()

    r = await client.delete(
        f"/api/v1/groups/{env.gid}/invites/{invite_id}", headers=env.owner_h
    )
    assert r.status_code == 200, r.text
    assert _group_updated(group_ws, env) == [
        (
            {env.owner.id, env.admin.id, env.member.id, invitee.id},
            {"group_id": env.gid},
        )
    ]


async def test_decline_invite_tells_members_only(client, db, group_env, group_ws):
    env = group_env
    invitee, invitee_h = await _user(db, env.org, "Dr Invitee")
    r = await client.post(
        f"/api/v1/groups/{env.gid}/invites",
        json={"user_id": str(invitee.id)},
        headers=env.owner_h,
    )
    assert r.status_code == 201, r.text
    invite_id = r.json()["id"]
    group_ws.clear()

    r = await client.post(
        f"/api/v1/groups/{env.gid}/invites/{invite_id}/decline", headers=invitee_h
    )
    assert r.status_code == 200, r.text
    assert _group_updated(group_ws, env) == [
        ({env.owner.id, env.admin.id, env.member.id}, {"group_id": env.gid})
    ]


async def test_patch_group_tells_members(client, group_env, group_ws):
    env = group_env
    r = await client.patch(
        f"/api/v1/groups/{env.gid}", json={"name": "Renamed"}, headers=env.owner_h
    )
    assert r.status_code == 200, r.text
    assert _group_updated(group_ws, env) == [
        ({env.owner.id, env.admin.id, env.member.id}, {"group_id": env.gid})
    ]


# --------------------------------------------------------------------------- #
# Profiles
# --------------------------------------------------------------------------- #
@pytest.fixture
async def profile_env(db):
    """`me` has one connection (other org), one org colleague, and a stranger."""
    org = await helpers.create_org(db, name="Mine")
    other_org = await helpers.create_org(db, name="Theirs")
    me, me_h = await _user(db, org, "Dr Me")
    colleague, _ = await _user(db, org, "Dr Colleague")
    friend, _ = await _user(db, other_org, "Dr Friend")
    stranger, _ = await _user(db, other_org, "Dr Stranger")
    await helpers.connect_users(db, me, friend)
    return SimpleNamespace(
        me=me, me_h=me_h, colleague=colleague, friend=friend, stranger=stranger
    )


async def test_patch_me_tells_connections_and_colleagues_not_me(
    client, profile_env, users_ws
):
    env = profile_env
    r = await client.patch(
        "/api/v1/users/me", json={"headline": "Interventional cardiology"}, headers=env.me_h
    )
    assert r.status_code == 200, r.text

    assert _of(users_ws, WsEventServer.PROFILE_UPDATED) == [
        ({env.colleague.id, env.friend.id}, {"user_id": str(env.me.id)})
    ]


async def test_delete_avatar_tells_audience(client, profile_env, users_ws):
    env = profile_env
    r = await client.delete("/api/v1/users/me/avatar", headers=env.me_h)
    assert r.status_code == 200, r.text
    assert _of(users_ws, WsEventServer.PROFILE_UPDATED) == [
        ({env.colleague.id, env.friend.id}, {"user_id": str(env.me.id)})
    ]


async def test_upload_avatar_tells_audience(client, profile_env, users_ws, monkeypatch):
    from app.services.file_service import FileService

    async def fake_upload(*, key, data, content_type):
        return None

    async def fake_presign(*, key, **kw):
        return f"https://cdn.test/{key}"

    monkeypatch.setattr(FileService, "upload_bytes", staticmethod(fake_upload))
    monkeypatch.setattr(FileService, "presigned_url", staticmethod(fake_presign))

    env = profile_env
    r = await client.post(
        "/api/v1/users/me/avatar",
        files={"file": ("me.png", b"\x89PNG\r\n\x1a\n" + b"0" * 32, "image/png")},
        headers=env.me_h,
    )
    assert r.status_code == 200, r.text
    assert _of(users_ws, WsEventServer.PROFILE_UPDATED) == [
        ({env.colleague.id, env.friend.id}, {"user_id": str(env.me.id)})
    ]


async def test_profile_update_with_no_audience_publishes_nothing(client, db, users_ws):
    loner, loner_h = await _user(db, None, "Dr Loner")
    r = await client.patch("/api/v1/users/me", json={"bio": "hi"}, headers=loner_h)
    assert r.status_code == 200, r.text
    assert users_ws == []


# --------------------------------------------------------------------------- #
# Read receipts under realtime load
# --------------------------------------------------------------------------- #
async def test_concurrent_mark_read_is_idempotent(client, db):
    """The thread screen marks a DM read on open and again as each live
    message lands, so two mark-read calls overlap routinely. Both must
    succeed and leave exactly one receipt per message."""
    import asyncio

    from app.models import MessageReceipt

    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")
    r = await client.post(
        "/api/v1/conversations", json={"type": "direct", "member_ids": [str(b.id)]}, headers=ah
    )
    assert r.status_code in (200, 201), r.text
    conv_id = r.json()["id"]
    for i in range(3):
        r = await client.post(
            f"/api/v1/conversations/{conv_id}/messages", json={"content": f"m{i}"}, headers=ah
        )
        assert r.status_code in (200, 201), r.text

    results = await asyncio.gather(
        *[client.post(f"/api/v1/conversations/{conv_id}/read", headers=bh) for _ in range(4)],
        *[client.post(f"/api/v1/conversations/{conv_id}/delivered", headers=bh) for _ in range(4)],
    )
    assert [x.status_code for x in results] == [200] * 8, [x.text for x in results]

    receipts = (
        await db.scalars(select(MessageReceipt).where(MessageReceipt.user_id == b.id))
    ).all()
    assert len(receipts) == 3
    assert all(x.read_at is not None and x.delivered_at is not None for x in receipts)

    # A second pass after the fact is a no-op, not an error.
    r = await client.post(f"/api/v1/conversations/{conv_id}/read", headers=bh)
    assert r.status_code == 200
    r = await client.post(f"/api/v1/conversations/{conv_id}/delivered", headers=bh)
    assert r.status_code == 200
