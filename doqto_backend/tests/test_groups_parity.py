"""Groups parity batch (0029): invite accept/decline surfaces, member cap,
reaction purge on leave/remove/ban, read-by receipts, member DM policy
enforced on the direct-chat gate, owner-only group settings, group avatars,
voice-note duration bounds.

Security negatives throughout: outsider → 404 (no existence oracle), member
without the role → 403, repeated calls idempotent.
"""
from __future__ import annotations

import uuid
from types import SimpleNamespace

import pytest
from sqlalchemy import select

import app.services.push_service as push_service
from app.api.ws_manager import ws_manager
from app.core import constants
from app.core.enums import (
    ConversationType,
    GroupInviteState,
    GroupMemberState,
    GroupRole,
    WsEventServer,
)
from app.core.permissions import (
    RelationshipContext,
    can_message,
    can_start_direct,
)
from app.models import (
    AuditLog,
    ConversationMember,
    Group,
    GroupInvite,
    GroupMember,
    MessageReaction,
)
from app.services.push_service import PushResult
from tests import helpers


# --------------------------------------------------------------------------- #
# fixtures / helpers
# --------------------------------------------------------------------------- #
class _Sender:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    async def send(self, *, token, title, body, data, collapse_key, badge=None) -> PushResult:
        self.calls.append(
            {"token": token, "title": title, "body": body, "data": data, "collapse": collapse_key}
        )
        return PushResult.SENT


@pytest.fixture
def pushes():
    fake = _Sender()
    push_service.sender_factory = lambda: fake
    yield fake
    push_service.sender_factory = push_service._default_sender


@pytest.fixture
def ws(monkeypatch):
    """Every publish (group_service, conversations, messages share the one
    ws_manager object) recorded as (event, {user ids}, data)."""
    sent: list[tuple[str, set, dict]] = []

    async def fake(user_ids, event, data):
        sent.append((str(event), set(user_ids), data))

    monkeypatch.setattr(ws_manager, "publish_to_users", fake)
    return sent


@pytest.fixture
def no_s3(monkeypatch):
    from app.services.file_service import FileService

    uploaded: list[str] = []

    async def fake_upload(*, key, data, content_type):
        uploaded.append(key)

    async def fake_presign(*, key, **kw):
        return f"https://cdn.test/{key}"

    async def fake_delete(*, key):
        return None

    monkeypatch.setattr(FileService, "upload_bytes", staticmethod(fake_upload))
    monkeypatch.setattr(FileService, "presigned_url", staticmethod(fake_presign))
    monkeypatch.setattr(FileService, "delete_object", staticmethod(fake_delete))
    return uploaded


def _of(ws, event: WsEventServer):
    return [(uids, d) for ev, uids, d in ws if ev == event.value]


async def _user(db, name):
    u = await helpers.create_user(db, full_name=name)
    return u, await helpers.auth_headers(u.id)


async def _group(client, headers, **overrides):
    body = {"name": "Cardiology Rounds", "post_policy": "all_members", "member_dm_policy": "request"}
    body.update(overrides)
    r = await client.post("/api/v1/groups", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _join(db, gid, *users, role: GroupRole = GroupRole.MEMBER):
    """Direct membership for users the test only needs IN the group."""
    group = await db.scalar(select(Group).where(Group.id == gid))
    for u in users:
        db.add(GroupMember(group_id=group.id, user_id=u.id, role=role, state=GroupMemberState.ACTIVE))
        db.add(ConversationMember(conversation_id=group.conversation_id, user_id=u.id))
    group.member_count += len(users)
    await db.commit()


async def _member_state(db, gid, uid):
    m = await db.scalar(
        select(GroupMember).where(GroupMember.group_id == gid, GroupMember.user_id == uid)
    )
    return None if m is None else m.state


async def _send(client, conv_id, headers, text="hello"):
    r = await client.post(
        f"/api/v1/conversations/{conv_id}/messages", json={"content": text}, headers=headers
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.fixture
async def colleagues(db):
    """Owner + colleague share an org (so a direct invite is allowed); the
    stranger shares nothing with anyone."""
    org = await helpers.create_org(db)
    owner, owner_h = await _user(db, "Dr Owner")
    peer, peer_h = await _user(db, "Dr Peer")
    await helpers.add_org_member(db, org, owner)
    await helpers.add_org_member(db, org, peer)
    stranger, stranger_h = await _user(db, "Dr Stranger")
    return SimpleNamespace(
        org=org, owner=owner, owner_h=owner_h, peer=peer, peer_h=peer_h,
        stranger=stranger, stranger_h=stranger_h,
    )


# --------------------------------------------------------------------------- #
# A. Invite accept / decline surfaces + push
# --------------------------------------------------------------------------- #
async def test_invite_shows_up_with_invite_id_and_phi_free_push(db, client, colleagues, pushes, ws):
    c = colleagues
    g = await _group(client, c.owner_h)
    gid = g["id"]
    # Peer has a registered device.
    await push_service.PushService.register_token(
        user_id=c.peer.id, token="peer-device", platform="ios", db=db
    )
    await db.commit()

    inv = await client.post(
        f"/api/v1/groups/{gid}/invites", json={"user_id": str(c.peer.id)}, headers=c.owner_h
    )
    assert inv.status_code == 201, inv.text
    invite_id = inv.json()["id"]

    # Re-inviting while the first invite is live is idempotent (same row).
    again = await client.post(
        f"/api/v1/groups/{gid}/invites", json={"user_id": str(c.peer.id)}, headers=c.owner_h
    )
    assert again.status_code == 201 and again.json()["id"] == invite_id

    # The invited card and the detail both carry the invite id to act on.
    cards = await client.get("/api/v1/me/groups", params={"state": "invited"}, headers=c.peer_h)
    assert [row["invite_id"] for row in cards.json()] == [invite_id]
    detail = await client.get(f"/api/v1/groups/{gid}", headers=c.peer_h)
    assert detail.status_code == 200
    assert detail.json()["invite_id"] == invite_id
    assert detail.json()["my_role"] is None
    assert detail.json()["description"] is None  # not through the door yet

    # WS to the invitee + push: names only, never content; data = type + group id.
    assert _of(ws, WsEventServer.GROUP_INVITE_RECEIVED) == [
        ({c.peer.id}, {
            "group_id": gid, "invite_id": invite_id, "inviter_id": str(c.owner.id),
            "inviter_name": "Dr Owner", "group_name": "Cardiology Rounds",
        })
    ]
    import asyncio

    await asyncio.gather(*[t for t in asyncio.all_tasks() if t is not asyncio.current_task()])
    assert len(pushes.calls) == 1
    push = pushes.calls[0]
    assert push["token"] == "peer-device"
    assert push["body"] == "Dr Owner invited you to Cardiology Rounds"
    assert push["data"] == {"type": "group_invite", "group_id": gid}
    assert push["collapse"] == f"group_invite:{gid}"

    # Accept → member; invited bucket empties; a second accept is a 409.
    ok = await client.post(f"/api/v1/groups/{gid}/invites/{invite_id}/accept", headers=c.peer_h)
    assert ok.status_code == 200
    assert await _member_state(db, gid, c.peer.id) == GroupMemberState.ACTIVE
    cards = await client.get("/api/v1/me/groups", params={"state": "invited"}, headers=c.peer_h)
    assert cards.json() == []
    twice = await client.post(f"/api/v1/groups/{gid}/invites/{invite_id}/accept", headers=c.peer_h)
    assert twice.status_code == 409 and twice.json()["detail"] == "invite_not_pending"
    # Everyone in the group hears the join.
    assert any(uids == {c.owner.id} for uids, _ in _of(ws, WsEventServer.GROUP_MEMBER_JOINED))


async def test_decline_and_outsider_oracles(db, client, colleagues, ws):
    c = colleagues
    g = await _group(client, c.owner_h)
    gid = g["id"]
    inv = await client.post(
        f"/api/v1/groups/{gid}/invites", json={"user_id": str(c.peer.id)}, headers=c.owner_h
    )
    invite_id = inv.json()["id"]

    # Someone else cannot accept or decline my invite — and learns nothing.
    for verb in ("accept", "decline"):
        r = await client.post(
            f"/api/v1/groups/{gid}/invites/{invite_id}/{verb}", headers=c.stranger_h
        )
        assert r.status_code == 404, verb

    r = await client.post(f"/api/v1/groups/{gid}/invites/{invite_id}/decline", headers=c.peer_h)
    assert r.status_code == 200
    row = await db.scalar(select(GroupInvite).where(GroupInvite.id == uuid.UUID(invite_id)))
    assert row.state == GroupInviteState.DECLINED
    assert await _member_state(db, gid, c.peer.id) is None
    # The declined invitee is an outsider again: the group vanishes for them.
    assert (await client.get(f"/api/v1/groups/{gid}", headers=c.peer_h)).status_code == 404
    # Members see the pending invite disappear.
    assert any(uids == {c.owner.id} for uids, _ in _of(ws, WsEventServer.GROUP_UPDATED))


async def test_list_invites_admin_only_and_link_reopen(db, client, colleagues, ws):
    c = colleagues
    g = await _group(client, c.owner_h)
    gid = g["id"]
    await _join(db, gid, c.stranger)  # a plain member

    link = await client.post(
        f"/api/v1/groups/{gid}/invites", json={"link": True, "max_uses": 5}, headers=c.owner_h
    )
    assert link.status_code == 201
    direct = await client.post(
        f"/api/v1/groups/{gid}/invites", json={"user_id": str(c.peer.id)}, headers=c.owner_h
    )
    assert direct.status_code == 201

    listing = await client.get(f"/api/v1/groups/{gid}/invites", headers=c.owner_h)
    assert listing.status_code == 200
    assert {i["id"] for i in listing.json()} == {link.json()["id"], direct.json()["id"]}
    # A member may not see the invite list; a non-member sees no group at all.
    assert (await client.get(f"/api/v1/groups/{gid}/invites", headers=c.stranger_h)).status_code == 403
    outsider, outsider_h = await _user(db, "Dr Nobody")
    assert (await client.get(f"/api/v1/groups/{gid}/invites", headers=outsider_h)).status_code == 404
    # Members may not mint links either.
    assert (
        await client.post(f"/api/v1/groups/{gid}/invites", json={"link": True}, headers=c.stranger_h)
    ).status_code == 403

    # A member who follows the link again is simply let back in (no 409).
    token = link.json()["token"]
    r = await client.post(f"/api/v1/group-invites/{token}/accept", headers=c.stranger_h)
    assert r.status_code == 200
    assert r.json() == {"result": "already_member", "group_id": gid}
    # A newcomer joins through it.
    r = await client.post(f"/api/v1/group-invites/{token}/accept", headers=outsider_h)
    assert r.status_code == 200 and r.json()["result"] == "joined"
    row = await db.scalar(select(GroupInvite).where(GroupInvite.token == token))
    assert row.use_count == 1


# --------------------------------------------------------------------------- #
# E. Member cap
# --------------------------------------------------------------------------- #
async def test_group_full_on_invite_accept_and_link(db, client, colleagues, monkeypatch):
    c = colleagues
    g = await _group(client, c.owner_h)
    gid = g["id"]
    await _join(db, gid, c.stranger)  # owner + 1 = 2 active

    monkeypatch.setattr(constants, "GROUP_MAX_MEMBERS", 2)
    full = await client.post(
        f"/api/v1/groups/{gid}/invites", json={"user_id": str(c.peer.id)}, headers=c.owner_h
    )
    assert full.status_code == 409 and full.json()["detail"] == "group_full"

    # Room appears, the invite goes out, then the room is gone again by the
    # time the invitee accepts.
    monkeypatch.setattr(constants, "GROUP_MAX_MEMBERS", 3)
    inv = await client.post(
        f"/api/v1/groups/{gid}/invites", json={"user_id": str(c.peer.id)}, headers=c.owner_h
    )
    assert inv.status_code == 201
    link = await client.post(f"/api/v1/groups/{gid}/invites", json={"link": True}, headers=c.owner_h)
    monkeypatch.setattr(constants, "GROUP_MAX_MEMBERS", 2)
    acc = await client.post(
        f"/api/v1/groups/{gid}/invites/{inv.json()['id']}/accept", headers=c.peer_h
    )
    assert acc.status_code == 409 and acc.json()["detail"] == "group_full"
    # The invite stays pending so they can accept once someone leaves.
    row = await db.scalar(select(GroupInvite).where(GroupInvite.id == uuid.UUID(inv.json()["id"])))
    assert row.state == GroupInviteState.PENDING
    via_link = await client.post(
        f"/api/v1/group-invites/{link.json()['token']}/accept", headers=c.peer_h
    )
    assert via_link.status_code == 409 and via_link.json()["detail"] == "group_full"
    assert await _member_state(db, gid, c.peer.id) is None


# --------------------------------------------------------------------------- #
# F. Reactions leave with the member; banned members are shut out
# --------------------------------------------------------------------------- #
async def test_leave_remove_ban_purge_reactions_and_broadcast(db, client, colleagues, ws):
    c = colleagues
    g = await _group(client, c.owner_h)
    gid, conv_id = g["id"], g["conversation_id"]
    third, third_h = await _user(db, "Dr Third")
    await _join(db, gid, c.peer, c.stranger, third)

    msg = await _send(client, conv_id, c.owner_h, "rounds at 8")
    mid = msg["id"]
    for h, emoji in ((c.peer_h, "👍"), (c.stranger_h, "❤️"), (third_h, "👍")):
        r = await client.put(f"/api/v1/messages/{mid}/reaction", json={"emoji": emoji}, headers=h)
        assert r.status_code == 200, r.text
    ws.clear()

    # Peer leaves: their 👍 goes, the other 👍 stays.
    r = await client.delete(f"/api/v1/groups/{gid}/members/{c.peer.id}", headers=c.peer_h)
    assert r.status_code == 200
    reacted = _of(ws, WsEventServer.MESSAGE_REACTED)
    assert len(reacted) == 1
    uids, data = reacted[0]
    assert uids == {c.owner.id, c.stranger.id, third.id}  # remaining members only
    assert data["message_id"] == mid and data["actor_id"] == str(c.peer.id)
    assert data["emoji"] is None
    assert {(x["emoji"], x["count"]) for x in data["reactions"]} == {("👍", 1), ("❤️", 1)}
    assert data["changed_at"] is not None

    # The purge is visible on read and via changed_since catch-up.
    page = await client.get(f"/api/v1/conversations/{conv_id}/messages", headers=c.owner_h)
    row = next(m for m in page.json() if m["id"] == mid)
    assert {x["emoji"]: x["user_ids"] for x in row["reactions"]} == {
        "👍": [str(third.id)], "❤️": [str(c.stranger.id)],
    }
    assert row["changed_at"] is not None

    # Admin removes third → 👍 is gone entirely.
    ws.clear()
    r = await client.delete(f"/api/v1/groups/{gid}/members/{third.id}", headers=c.owner_h)
    assert r.status_code == 200
    (_, data), = _of(ws, WsEventServer.MESSAGE_REACTED)
    assert [x["emoji"] for x in data["reactions"]] == ["❤️"]

    # Ban stranger → nothing left; a member with no reactions produces no event.
    ws.clear()
    r = await client.post(f"/api/v1/groups/{gid}/members/{c.stranger.id}/ban", headers=c.owner_h)
    assert r.status_code == 200
    (_, data), = _of(ws, WsEventServer.MESSAGE_REACTED)
    assert data["reactions"] == []
    left = await db.scalar(select(MessageReaction).where(MessageReaction.message_id == uuid.UUID(mid)))
    assert left is None

    # Banned: cannot read, react, post, be re-invited, or come back by link.
    assert (await client.get(f"/api/v1/conversations/{conv_id}/messages", headers=c.stranger_h)).status_code == 403
    # Reactions answer an outsider like a missing message (no id oracle).
    r = await client.put(f"/api/v1/messages/{mid}/reaction", json={"emoji": "😮"}, headers=c.stranger_h)
    assert r.status_code == 404 and r.json()["detail"] == "message_not_found"
    assert (
        await client.post(f"/api/v1/conversations/{conv_id}/messages", json={"content": "hi"}, headers=c.stranger_h)
    ).status_code == 403
    assert (await client.get(f"/api/v1/groups/{gid}", headers=c.stranger_h)).status_code == 404
    reinvite = await client.post(
        f"/api/v1/groups/{gid}/invites", json={"user_id": str(c.stranger.id)}, headers=c.owner_h
    )
    assert reinvite.status_code == 403 and reinvite.json()["detail"] == "not_invitable"
    link = await client.post(f"/api/v1/groups/{gid}/invites", json={"link": True}, headers=c.owner_h)
    assert (
        await client.post(f"/api/v1/group-invites/{link.json()['token']}/accept", headers=c.stranger_h)
    ).status_code == 404
    assert await _member_state(db, gid, c.stranger.id) == GroupMemberState.BANNED


# --------------------------------------------------------------------------- #
# D. Message info / receipts
# --------------------------------------------------------------------------- #
async def test_receipts_direct_chat(db, client, chat):
    sent = await _send(client, chat.conv.id, chat.alice_headers, "ct ready?")
    mid = sent["id"]

    r = await client.get(f"/api/v1/messages/{mid}/receipts", headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    [row] = r.json()
    assert row["user_id"] == str(chat.bob.id) and row["full_name"] == "Dr Bob"
    assert row["delivered"] is False and row["read"] is False
    assert row["delivered_at"] is None and row["read_at"] is None

    await client.post(f"/api/v1/conversations/{chat.conv.id}/delivered", headers=chat.bob_headers)
    [row] = (await client.get(f"/api/v1/messages/{mid}/receipts", headers=chat.alice_headers)).json()
    assert row["delivered"] is True and row["read"] is False and row["delivered_at"]

    await client.post(f"/api/v1/conversations/{chat.conv.id}/read", headers=chat.bob_headers)
    [row] = (await client.get(f"/api/v1/messages/{mid}/receipts", headers=chat.alice_headers)).json()
    assert row["read"] is True and row["read_at"] and row["delivered_at"]

    # Only the sender sees message info; an outsider sees no message.
    r = await client.get(f"/api/v1/messages/{mid}/receipts", headers=chat.bob_headers)
    assert r.status_code == 403 and r.json()["detail"] == "not_message_sender"
    _, out_h = await _user(db, "Dr Out")
    assert (await client.get(f"/api/v1/messages/{mid}/receipts", headers=out_h)).status_code == 404
    assert (await client.get(f"/api/v1/messages/{uuid.uuid4()}/receipts", headers=chat.alice_headers)).status_code == 404

    # Audited as a read.
    rows = await db.scalars(
        select(AuditLog).where(
            AuditLog.action == "message_receipts_read", AuditLog.resource_id == uuid.UUID(mid)
        )
    )
    assert len(rows.all()) >= 1


async def test_receipts_group_from_cursors(db, client, colleagues):
    c = colleagues
    g = await _group(client, c.owner_h)
    gid, conv_id = g["id"], g["conversation_id"]
    await _join(db, gid, c.peer, c.stranger)
    sent = await _send(client, conv_id, c.owner_h, "all-hands")
    mid = sent["id"]

    await client.post(f"/api/v1/conversations/{conv_id}/delivered", headers=c.peer_h)
    await client.post(f"/api/v1/conversations/{conv_id}/read", headers=c.stranger_h)

    rows = (await client.get(f"/api/v1/messages/{mid}/receipts", headers=c.owner_h)).json()
    by = {r["user_id"]: r for r in rows}
    assert set(by) == {str(c.peer.id), str(c.stranger.id)}  # never the sender
    assert by[str(c.peer.id)]["delivered"] is True and by[str(c.peer.id)]["read"] is False
    assert by[str(c.stranger.id)]["read"] is True and by[str(c.stranger.id)]["read_at"]
    # Read rows sort first.
    assert rows[0]["user_id"] == str(c.stranger.id)
    # A member who is not the sender gets 403, not the list.
    assert (await client.get(f"/api/v1/messages/{mid}/receipts", headers=c.peer_h)).status_code == 403


# --------------------------------------------------------------------------- #
# C. member_dm_policy enforced on the direct-chat gate
# --------------------------------------------------------------------------- #
def _ctx(**kw):
    base = dict(viewer_id=uuid.uuid4(), target_id=uuid.uuid4())
    base.update(kw)
    return RelationshipContext(**base)


def test_permissions_shared_group_modes_pure():
    assert can_start_direct(_ctx(shared_group_dm_mode="open")).mode == "open"
    assert can_start_direct(_ctx(shared_group_dm_mode="request")).reason == "group_dm_request"
    assert can_message(_ctx(shared_group_dm_mode="denied")).reason == "group_dm_disabled"
    assert can_message(_ctx(shared_group_dm_mode=None)).reason == "not_connected"
    # A connection or a block still wins over any group policy.
    assert can_start_direct(_ctx(is_first_degree=True, shared_group_dm_mode="denied")).mode == "open"
    assert can_start_direct(_ctx(is_blocked_either_way=True, shared_group_dm_mode="open")).reason == "blocked"


@pytest.mark.parametrize(
    "policy,status_code,detail",
    [("open", 200, None), ("request", 403, "group_dm_request"), ("disabled", 403, "group_dm_disabled")],
)
async def test_group_dm_policy_gates_direct_chat(db, client, colleagues, policy, status_code, detail):
    """Owner and stranger share NOTHING but the group."""
    c = colleagues
    g = await _group(client, c.owner_h, member_dm_policy=policy)
    await _join(db, g["id"], c.stranger)

    r = await client.post(
        "/api/v1/conversations",
        json={"type": "direct", "member_ids": [str(c.owner.id)]},
        headers=c.stranger_h,
    )
    assert r.status_code == status_code, r.text
    if detail:
        assert r.json()["detail"] == detail


async def test_group_dm_policy_flip_freezes_existing_thread(db, client, colleagues):
    c = colleagues
    g = await _group(client, c.owner_h, member_dm_policy="open")
    gid = g["id"]
    await _join(db, gid, c.stranger)
    conv = await client.post(
        "/api/v1/conversations",
        json={"type": "direct", "member_ids": [str(c.stranger.id)]},
        headers=c.owner_h,
    )
    assert conv.status_code == 200
    conv_id = conv.json()["id"]
    await _send(client, conv_id, c.stranger_h, "hi")

    # Owner closes member DMs → the thread freezes both ways, with a clear code.
    r = await client.patch(f"/api/v1/groups/{gid}", json={"member_dm_policy": "disabled"}, headers=c.owner_h)
    assert r.status_code == 200
    blocked = await client.post(
        f"/api/v1/conversations/{conv_id}/messages", json={"content": "still there?"}, headers=c.stranger_h
    )
    assert blocked.status_code == 403 and blocked.json()["detail"] == "group_dm_disabled"

    # The most permissive shared group wins: a second open group reopens it.
    g2 = await _group(client, c.owner_h, name="Second", member_dm_policy="open")
    await _join(db, g2["id"], c.stranger)
    ok = await client.post(
        f"/api/v1/conversations/{conv_id}/messages", json={"content": "back"}, headers=c.stranger_h
    )
    assert ok.status_code == 200

    # Leaving the groups removes the relationship entirely.
    await client.delete(f"/api/v1/groups/{gid}/members/{c.stranger.id}", headers=c.stranger_h)
    await client.delete(f"/api/v1/groups/{g2['id']}/members/{c.stranger.id}", headers=c.stranger_h)
    gone = await client.post(
        f"/api/v1/conversations/{conv_id}/messages", json={"content": "?"}, headers=c.stranger_h
    )
    assert gone.status_code == 403 and gone.json()["detail"] == "not_connected"


# --------------------------------------------------------------------------- #
# C. post policy error + owner/admin-only group settings
# --------------------------------------------------------------------------- #
async def test_group_settings_owner_or_admin_only_legacy_untouched(db, client, colleagues):
    c = colleagues
    g = await _group(client, c.owner_h)
    gid, conv_id = g["id"], g["conversation_id"]
    await _join(db, gid, c.peer)

    body = {"disappear_after_sec": 86400}
    r = await client.patch(f"/api/v1/conversations/{conv_id}/settings", json=body, headers=c.peer_h)
    assert r.status_code == 403 and r.json()["detail"] == "not_authorized"
    r = await client.patch(f"/api/v1/conversations/{conv_id}/settings", json=body, headers=c.owner_h)
    assert r.status_code == 200
    # Promote peer to admin → allowed.
    await client.patch(f"/api/v1/groups/{gid}/members/{c.peer.id}", json={"role": "admin"}, headers=c.owner_h)
    r = await client.patch(
        f"/api/v1/conversations/{conv_id}/settings", json={"disappear_after_sec": None}, headers=c.peer_h
    )
    assert r.status_code == 200
    # Outsider: no conversation for them.
    r = await client.patch(f"/api/v1/conversations/{conv_id}/settings", json=body, headers=c.stranger_h)
    assert r.status_code == 403

    # Legacy org group chat (no groups row): any member still may.
    legacy = await helpers.create_conversation(
        db, c.org, [c.owner, c.peer], conv_type=ConversationType.GROUP, name="Ward"
    )
    r = await client.patch(f"/api/v1/conversations/{legacy.id}/settings", json=body, headers=c.peer_h)
    assert r.status_code == 200

    # admins_only post policy keeps its clear code for the composer notice.
    await client.patch(f"/api/v1/groups/{gid}", json={"post_policy": "admins_only"}, headers=c.owner_h)
    await client.patch(f"/api/v1/groups/{gid}/members/{c.peer.id}", json={"role": "member"}, headers=c.owner_h)
    r = await client.post(f"/api/v1/conversations/{conv_id}/messages", json={"content": "?"}, headers=c.peer_h)
    assert r.status_code == 403 and r.json()["detail"] == "post_restricted"


# --------------------------------------------------------------------------- #
# B. Group avatar
# --------------------------------------------------------------------------- #
async def test_group_avatar_upload_roles_and_presign(db, client, colleagues, no_s3, ws):
    c = colleagues
    g = await _group(client, c.owner_h)
    gid = g["id"]
    await _join(db, gid, c.peer)
    png = ("g.png", b"\x89PNG\r\n\x1a\n" + b"0" * 32, "image/png")

    r = await client.post(f"/api/v1/groups/{gid}/avatar", files={"file": png}, headers=c.peer_h)
    assert r.status_code == 403
    r = await client.post(f"/api/v1/groups/{gid}/avatar", files={"file": png}, headers=c.stranger_h)
    assert r.status_code == 404
    r = await client.post(
        f"/api/v1/groups/{gid}/avatar", files={"file": ("x.gif", b"GIF89a", "image/gif")}, headers=c.owner_h
    )
    assert r.status_code == 400 and r.json()["detail"] == "avatar_unsupported_type"

    r = await client.post(f"/api/v1/groups/{gid}/avatar", files={"file": png}, headers=c.owner_h)
    assert r.status_code == 200, r.text
    key = r.json()["avatar_url"]
    assert key.startswith(f"group-avatars/{gid}/") and key.endswith(".png")
    assert r.json()["avatar_presigned_url"] == f"https://cdn.test/{key}"
    assert no_s3 == [key]
    assert any(uids == {c.owner.id, c.peer.id} for uids, _ in _of(ws, WsEventServer.GROUP_UPDATED))

    cards = await client.get("/api/v1/me/groups", headers=c.peer_h)
    assert cards.json()[0]["avatar_presigned_url"] == f"https://cdn.test/{key}"

    r = await client.delete(f"/api/v1/groups/{gid}/avatar", headers=c.owner_h)
    assert r.status_code == 200 and r.json()["avatar_url"] is None


# --------------------------------------------------------------------------- #
# F. Voice-note duration bounds
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("duration", [0, -1, constants.VOICE_NOTE_MAX_DURATION_SECONDS + 1])
async def test_voice_note_duration_bounds(client, chat, duration):
    r = await client.post(
        f"/api/v1/messages/voice-notes/{chat.conv.id}",
        files={"file": ("note.m4a", b"\x00" * 64, "audio/mp4")},
        data={"duration_sec": str(duration)},
        headers=chat.alice_headers,
    )
    assert r.status_code == 422, r.text
    assert r.json()["detail"] == "voice_note_duration"
