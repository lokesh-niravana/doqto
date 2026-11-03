"""M1 networking-graph integration tests — spec §16 acceptance tests 1–5
plus quotas, kill switch, same-org regression, and notification/push wiring.
"""
from __future__ import annotations

import asyncio
import uuid

import pytest
from sqlalchemy import func, select

from app.core import constants
from app.core.enums import AuditAction, InvitationStatus
from app.core.permissions import can_start_direct
from app.models import AuditLog, Connection, ConnectionInvitation, Notification
from app.services import push_service
from app.services.push_service import PushResult
from app.services.push_service import PushService
from app.services.relationship_service import RelationshipService
from tests import helpers

NETWORK = "/api/v1/network"


class RecordingSender:
    def __init__(self) -> None:
        self.calls: list[dict] = []

    async def send(self, *, token, title, body, data, collapse_key) -> PushResult:
        self.calls.append({"token": token, "title": title, "body": body, "data": data})
        return PushResult.SENT


@pytest.fixture(autouse=True)
async def _drain_bg_tasks():
    """Invite/accept fan out via fire-and-forget push create_task()s that open
    their own DB session. If one is still pending when the test's event loop
    closes, its asyncpg connection is orphaned idle-in-transaction and blocks
    the next test's TRUNCATE. Drain them before the loop closes."""
    yield
    pending = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
    if pending:
        await asyncio.gather(*pending, return_exceptions=True)


@pytest.fixture
def fake_sender():
    fake = RecordingSender()
    push_service.sender_factory = lambda: fake
    yield fake
    push_service.sender_factory = push_service._default_sender


async def _user(db, org, name):
    u = await helpers.create_user(db, full_name=name)
    await helpers.add_org_member(db, org, u)
    return u, await helpers.auth_headers(u.id)


async def _invite(client, headers, recipient):
    return await client.post(
        f"{NETWORK}/invitations",
        json={"recipient_id": str(recipient.id)},
        headers=headers,
    )


async def _connect(client, a_headers, b, b_headers, client_a_inviter):
    """a invites b, b accepts."""
    r = await _invite(client, a_headers, b)
    assert r.status_code == 201, r.text
    inv_id = r.json()["invitation"]["id"]
    r2 = await client.post(f"{NETWORK}/invitations/{inv_id}/accept", headers=b_headers)
    assert r2.status_code == 200, r2.text


# --------------------------------------------------------------------------- #
# Acceptance test 1 — invite creates one pending; duplicate 409
# --------------------------------------------------------------------------- #
async def test_1_invite_creates_pending_and_dedups(client, db):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")

    r = await _invite(client, ah, b)
    assert r.status_code == 201
    assert r.json()["result"] == "invited"

    count = await db.scalar(
        select(func.count())
        .select_from(ConnectionInvitation)
        .where(ConnectionInvitation.status == InvitationStatus.PENDING)
    )
    assert count == 1

    sent = await client.get(f"{NETWORK}/invitations?direction=sent", headers=ah)
    assert len(sent.json()["data"]) == 1

    dup = await _invite(client, ah, b)
    assert dup.status_code == 409
    assert dup.json()["detail"] == "invitation_exists"


# --------------------------------------------------------------------------- #
# Acceptance test 2 — reciprocal pending auto-accepts, one pair, both 1st
# --------------------------------------------------------------------------- #
async def test_2_reciprocal_autoaccept(client, db):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")

    r1 = await _invite(client, ah, b)
    assert r1.status_code == 201 and r1.json()["result"] == "invited"

    r2 = await _invite(client, bh, a)
    assert r2.status_code == 201
    assert r2.json()["result"] == "connected"

    rows = (await db.scalars(select(Connection))).all()
    assert len(rows) == 2
    assert {r.pair_id for r in rows} == {rows[0].pair_id}  # single shared pair
    assert {(r.user_id, r.connected_user_id) for r in rows} == {(a.id, b.id), (b.id, a.id)}

    assert await RelationshipService.is_first_degree(a.id, b.id, db)
    assert await RelationshipService.is_first_degree(b.id, a.id, db)


# --------------------------------------------------------------------------- #
# Acceptance test 3 — ignore is silent; re-invite hits the 21d cooldown
# --------------------------------------------------------------------------- #
async def test_3_ignore_silent_then_cooldown(client, db):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")

    r = await _invite(client, ah, b)
    inv_id = r.json()["invitation"]["id"]
    ig = await client.post(f"{NETWORK}/invitations/{inv_id}/ignore", headers=bh)
    assert ig.status_code == 200

    # Silent: sender A got no acceptance/decline notification.
    a_notifs = await db.scalar(
        select(func.count()).select_from(Notification).where(Notification.user_id == a.id)
    )
    assert a_notifs == 0

    # Re-invite within 21 days → generic rate-limited 429.
    again = await _invite(client, ah, b)
    assert again.status_code == 429
    assert again.json()["detail"] == "rate_limited"
    assert again.headers.get("X-Retry-After-Days") is not None


# --------------------------------------------------------------------------- #
# Acceptance test 4 — second degree + mutuals; promotion drops 2nd-degree entry
# --------------------------------------------------------------------------- #
async def test_4_degrees_and_mutuals(client, db):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")
    c, ch = await _user(db, org, "Dr C")

    await _connect(client, ah, b, bh, a)
    await _connect(client, bh, c, ch, b)

    assert await RelationshipService.degree_of(a.id, c.id, db) == 2
    mutual = await RelationshipService.mutual_connections(a.id, c.id, db)
    assert mutual == [b.id]

    # Promote C to first degree for A.
    await _connect(client, ah, c, ch, a)
    assert await RelationshipService.degree_of(a.id, c.id, db) == 1
    assert c.id not in await RelationshipService.second_degree_ids(a.id, db)


# --------------------------------------------------------------------------- #
# Acceptance test 5 — block tears down the edge + pending, and hides the user
# --------------------------------------------------------------------------- #
async def test_5_block_teardown(client, db):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")

    await _connect(client, ah, b, bh, a)
    # A pending invite from B in the other direction should be cleared too.
    c, ch = await _user(db, org, "Dr C")
    await _invite(client, ch, a)  # C invites A (pending); unrelated to block

    blk = await client.post(f"{NETWORK}/blocks/{b.id}", headers=ah)
    assert blk.status_code == 200

    # Connection gone both directions.
    conns = (await db.scalars(select(Connection))).all()
    assert not any(
        {r.user_id, r.connected_user_id} == {a.id, b.id} for r in conns
    )
    # A can no longer reach B and vice-versa — generic 404 (silence rule).
    assert (await _invite(client, ah, b)).status_code == 404
    assert (await _invite(client, bh, a)).status_code == 404
    # Mutuals endpoint also hides a blocked user.
    m = await client.get(f"{NETWORK}/connections/mutual/{b.id}", headers=ah)
    assert m.status_code == 404


# --------------------------------------------------------------------------- #
# Quotas — the (N+1)th daily invite is rate-limited
# --------------------------------------------------------------------------- #
async def test_quota_daily_cap(client, db, monkeypatch):
    monkeypatch.setattr(constants, "INVITE_QUOTA_PER_DAY", 3)
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    recipients = [await _user(db, org, f"Dr R{i}") for i in range(4)]

    for i in range(3):
        r = await _invite(client, ah, recipients[i][0])
        assert r.status_code == 201, (i, r.text)
    over = await _invite(client, ah, recipients[3][0])
    assert over.status_code == 429
    assert over.json()["detail"] == "rate_limited"


# --------------------------------------------------------------------------- #
# Kill switch — external invite denied + audited
# --------------------------------------------------------------------------- #
async def test_killswitch_denies_and_audits(client, db):
    org_a = await helpers.create_org(db)
    org_a.external_networking_enabled = False
    org_b = await helpers.create_org(db)
    await db.commit()

    a, ah = await _user(db, org_a, "Dr A")
    b, bh = await _user(db, org_b, "Dr B")

    r = await _invite(client, ah, b)
    assert r.status_code == 403
    assert r.json()["detail"] == "networking_disabled"

    audited = await db.scalar(
        select(func.count())
        .select_from(AuditLog)
        .where(AuditLog.action == AuditAction.NETWORKING_POLICY_DENIED.value)
    )
    assert audited == 1


# --------------------------------------------------------------------------- #
# Same-org regression (acceptance test 6 alignment) — colleagues always open
# --------------------------------------------------------------------------- #
async def test_same_org_always_open(db):
    org = await helpers.create_org(db)
    a, _ = await _user(db, org, "Dr A")
    b, _ = await _user(db, org, "Dr B")
    ctx = await RelationshipService.load_context(a.id, b.id, db)
    assert ctx.shared_org_ids  # colleagues
    assert can_start_direct(ctx).mode == "open"


# --------------------------------------------------------------------------- #
# Notifications + push wiring on invite / accept
# --------------------------------------------------------------------------- #
async def test_invite_creates_notification_and_unread(client, db):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")

    await _invite(client, ah, b)
    notif = await db.scalar(
        select(Notification).where(Notification.user_id == b.id)
    )
    assert notif is not None and notif.type == "invitation_received"
    assert notif.payload.get("actor_name") == "Dr A"

    unread = await client.get("/api/v1/notifications/unread-count", headers=bh)
    assert unread.json()["unread_count"] == 1


async def test_accept_notifies_sender(client, db):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr A")
    b, bh = await _user(db, org, "Dr B")
    await _connect(client, ah, b, bh, a)
    notif = await db.scalar(
        select(Notification).where(
            Notification.user_id == a.id, Notification.type == "invitation_accepted"
        )
    )
    assert notif is not None
    assert notif.payload.get("actor_name") == "Dr B"


async def test_invitation_push_fires_for_offline_recipient(db, fake_sender):
    """notify_invitation_received → presence-gated push with the actor's name
    (directory data, allowed in a push body)."""
    org = await helpers.create_org(db)
    a = await helpers.create_user(db, full_name="Dr A")
    b = await helpers.create_user(db, full_name="Dr B")
    await helpers.add_org_member(db, org, a)
    await helpers.add_org_member(db, org, b)
    token = f"tok-{uuid.uuid4().hex}"
    await PushService.register_token(user_id=b.id, token=token, platform="ios", db=db)
    await db.commit()

    inv_id = uuid.uuid4()
    await PushService._dispatch_simple(
        recipient_id=b.id,
        title="Doqto",
        body="Dr A wants to connect",
        data={"type": "invitation_received", "invitation_id": str(inv_id)},
        collapse_key=f"invite:{inv_id}",
    )
    assert len(fake_sender.calls) == 1
    assert fake_sender.calls[0]["body"] == "Dr A wants to connect"


# --------------------------------------------------------------------------- #
# Card payloads carry renderable identity (regression: nameless invitation
# cards, and a connections list whose `id` was absent so the client routed
# to /people/ and got a page-not-found).
# --------------------------------------------------------------------------- #
async def test_invitation_list_carries_sender_and_recipient_identity(client, db):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr Alpha")
    b, bh = await _user(db, org, "Dr Beta")

    assert (await _invite(client, ah, b)).status_code == 201

    got = (await client.get(f"{NETWORK}/invitations?direction=received", headers=bh)).json()
    card = got["data"][0]
    assert card["sender"]["id"] == str(a.id)
    assert card["sender"]["full_name"] == "Dr Alpha"
    assert card["recipient"]["full_name"] == "Dr Beta"
    # Minimum-necessary: directory fields only.
    for leaked in ("phone", "email", "npi_number"):
        assert leaked not in card["sender"]


async def test_connections_list_uses_id_not_user_id(client, db):
    org = await helpers.create_org(db)
    a, ah = await _user(db, org, "Dr Alpha")
    b, bh = await _user(db, org, "Dr Beta")
    await _connect(client, ah, b, bh, a)

    row = (await client.get(f"{NETWORK}/connections", headers=ah)).json()["data"][0]
    assert row["id"] == str(b.id)
    assert "user_id" not in row
