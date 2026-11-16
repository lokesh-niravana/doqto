"""Batch 7 — compliance hardening: org policies, retention + legal hold,
durable hash-chained audit + read APIs, break-glass, org moderation,
scheduled list/cancel, .well-known, envelope encryption."""
from __future__ import annotations

import importlib.util
import os
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select, text, update

from app.core import crypto
from app.core.enums import (
    AccessRequestStatus,
    AuditAction,
    ConversationType,
    MessageType,
    OrgRole,
    TranscriptStatus,
    UserRole,
)
from app.core.security import encrypt_message
from app.models import (
    AccessRequest,
    AuditLog,
    Conversation,
    DataKey,
    Message,
    MessageEdit,
    Notification,
    ScheduledMessage,
)
from app.services.audit_service import AuditService
from app.services.compliance_service import RetentionService
from app.services.message_service import MessageService
from tests import helpers

ORGS = "/api/v1/orgs"
CONVS = "/api/v1/conversations"
MSGS = "/api/v1/messages"


async def _send(client, conv_id, headers, content):
    r = await client.post(f"{CONVS}/{conv_id}/messages", json={"content": content}, headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def _admin(db, org, name="Dr Admin"):
    user = await helpers.create_user(db, full_name=name)
    await helpers.add_org_member(db, org, user, role=OrgRole.ADMIN)
    return user, await helpers.auth_headers(user.id)


async def _super_admin(db):
    admin = await helpers.create_user(db, full_name="Ops")
    admin.role = UserRole.SUPER_ADMIN
    await db.commit()
    return admin, await helpers.auth_headers(admin.id)


def _old_message(conv, sender, seq, *, days: int, content="old", **kw) -> Message:
    return Message(
        conversation_id=conv.id,
        sender_id=sender.id,
        type=MessageType.TEXT,
        seq=seq,
        transcript_status=TranscriptStatus.NONE,
        content_encrypted=encrypt_message(content),
        created_at=datetime.now(tz=timezone.utc) - timedelta(days=days),
        **kw,
    )


# ================================================================ policies ==


async def test_policies_read_write_and_validation(client, chat, db):
    admin, admin_h = await _admin(db, chat.org)
    # Members read the effective set; defaults filled in.
    r = await client.get(f"{ORGS}/{chat.org.id}/policies", headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    assert r.json() == {
        "allow_forward_outside_org": True,
        "allow_copy": True,
        "allow_media_export": False,
        "block_screenshots": False,
        "show_preview_in_banners_default": False,
        "default_disappear_sec": None,
        "retention_days": None,
        "legal_hold": False,
    }
    # Members cannot write; outsiders cannot read.
    r = await client.patch(
        f"{ORGS}/{chat.org.id}/policies", json={"allow_copy": False}, headers=chat.alice_headers
    )
    assert r.status_code == 403
    outsider = await helpers.create_user(db, full_name="Out")
    r = await client.get(
        f"{ORGS}/{chat.org.id}/policies", headers=await helpers.auth_headers(outsider.id)
    )
    assert r.status_code == 403

    r = await client.patch(
        f"{ORGS}/{chat.org.id}/policies",
        json={
            "allow_copy": False,
            "retention_days": 90,
            "default_disappear_sec": 604800,
            "legal_hold": True,
            "show_preview_in_banners_default": True,
        },
        headers=admin_h,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["allow_copy"] is False and body["retention_days"] == 90
    assert body["default_disappear_sec"] == 604800 and body["legal_hold"] is True
    # The networking-settings route still reports and writes the same JSONB.
    r = await client.patch(
        f"{ORGS}/{chat.org.id}/settings/networking",
        json={"block_screenshots": True},
        headers=admin_h,
    )
    assert r.status_code == 200 and r.json()["policies"]["block_screenshots"] is True
    assert r.json()["policies"]["retention_days"] == 90
    # Audit carries only the diff.
    rows = (
        await db.scalars(
            select(AuditLog).where(AuditLog.action == AuditAction.ORG_POLICY_CHANGED.value)
        )
    ).all()
    assert rows[0].meta == {
        "allow_copy": False,
        "retention_days": 90,
        "default_disappear_sec": 604800,
        "legal_hold": True,
        "show_preview_in_banners_default": True,
    }
    # Same values again → no-op, no new audit row.
    r = await client.patch(f"{ORGS}/{chat.org.id}/policies", json={"allow_copy": False}, headers=admin_h)
    assert r.status_code == 200
    assert (
        len(
            (
                await db.scalars(
                    select(AuditLog).where(AuditLog.action == AuditAction.ORG_POLICY_CHANGED.value)
                )
            ).all()
        )
        == 2
    )
    # Validation: bad timer, retention out of range, unknown key, null clears.
    for bad in ({"default_disappear_sec": 42}, {"retention_days": 0}, {"bogus": True}):
        r = await client.patch(f"{ORGS}/{chat.org.id}/policies", json=bad, headers=admin_h)
        assert r.status_code == 422, bad
    r = await client.patch(
        f"{ORGS}/{chat.org.id}/policies", json={"retention_days": None}, headers=admin_h
    )
    assert r.status_code == 200 and r.json()["retention_days"] is None
    # Banner-preview default follows the org policy for members.
    r = await client.get("/api/v1/users/me/notifications", headers=chat.alice_headers)
    assert r.json()["messages_show_preview"] is True


async def test_org_group_starts_with_default_disappear_policy(client, chat, db):
    admin, admin_h = await _admin(db, chat.org)
    await client.patch(
        f"{ORGS}/{chat.org.id}/policies", json={"default_disappear_sec": 86400}, headers=admin_h
    )
    r = await client.post(
        CONVS,
        json={"type": "group", "name": "Ward 3", "member_ids": [str(chat.alice.id)]},
        headers=admin_h,
    )
    assert r.status_code == 200, r.text
    assert r.json()["disappear_after_sec"] == 86400


# ===================================================== retention / hold ==


async def test_retention_job_expires_old_messages_unless_held(client, chat, db):
    admin, admin_h = await _admin(db, chat.org)
    await client.patch(f"{ORGS}/{chat.org.id}/policies", json={"retention_days": 30}, headers=admin_h)
    org_id, conv_id, alice_h = chat.org.id, chat.conv.id, chat.alice_headers
    old = _old_message(chat.conv, chat.alice, 1, days=31)
    fresh = _old_message(chat.conv, chat.alice, 2, days=2)
    db.add_all([old, fresh])
    await db.commit()
    await db.refresh(chat.org)  # the PATCH above went through the app's own session

    touched = await RetentionService.apply(db)
    await db.commit()
    assert touched == {org_id: 1}
    await db.refresh(old)
    await db.refresh(fresh)
    assert old.is_deleted is True and old.expires_at is not None
    assert fresh.is_deleted is False
    # Hidden from the thread; content still intact until the grace shred.
    r = await client.get(f"{CONVS}/{conv_id}/messages", headers=alice_h)
    assert [m["seq"] for m in r.json()] == [2]
    assert old.content_encrypted is not None
    audit = await db.scalar(
        select(AuditLog).where(AuditLog.action == AuditAction.RETENTION_APPLIED.value)
    )
    assert audit.resource_id == org_id and audit.meta == {"retention_days": 30, "messages": 1}
    # Idempotent, and a legal hold pauses it entirely.
    assert await RetentionService.apply(db) == {}
    await client.patch(f"{ORGS}/{org_id}/policies", json={"legal_hold": True}, headers=admin_h)
    db.add(_old_message(chat.conv, chat.alice, 3, days=40))
    await db.commit()
    await db.refresh(chat.org)
    assert await RetentionService.apply(db) == {}


async def test_legal_hold_pauses_shred_but_tombstones(client, chat, db):
    admin, admin_h = await _admin(db, chat.org)
    await client.patch(f"{ORGS}/{chat.org.id}/policies", json={"legal_hold": True}, headers=admin_h)
    sent = await _send(client, chat.conv.id, chat.alice_headers, "keep me")
    # Delete for everyone: members see a bare tombstone, row keeps the body.
    r = await client.delete(f"{MSGS}/{sent['id']}", headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    assert r.json()["deleted_at"] and r.json()["content"] is None
    row = await db.get(Message, uuid.UUID(sent["id"]))
    assert row.content_encrypted is not None
    assert crypto.decrypt(row.content_encrypted, row.key_version) == "keep me"
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    tomb = next(m for m in r.json() if m["id"] == sent["id"])
    assert tomb["content"] is None and tomb["deleted_at"]
    audit = await db.scalar(
        select(AuditLog).where(AuditLog.action == AuditAction.MESSAGE_DELETED.value)
    )
    assert audit.meta == {"legal_hold": True}

    # The 30-day shred skips held conversations …
    old = _old_message(chat.conv, chat.alice, 50, days=40, is_deleted=True, s3_key="files/x")
    db.add(old)
    await db.commit()
    assert await MessageService.purge_content(db) == []
    await db.refresh(old)
    assert old.content_encrypted is not None and old.s3_key == "files/x"
    # … and account deletion tombstones without destroying the body.
    r = await client.delete("/api/v1/users/me", headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    await db.refresh(row)
    assert row.is_deleted is True and row.content_encrypted is not None
    # Lift the hold: the next purge pass shreds the old row.
    await client.patch(f"{ORGS}/{chat.org.id}/policies", json={"legal_hold": False}, headers=admin_h)
    assert "files/x" in await MessageService.purge_content(db)


# ================================================================== audit ==


async def test_audit_rows_survive_rollback_and_chain_verifies(db, chat):
    await db.execute(text("SELECT 1"))  # open a transaction on the caller's session …
    await AuditService.log(
        db, user_id=chat.alice.id, action=AuditAction.LOGIN, metadata={"attempt": 1}
    )
    await AuditService.log(db, user_id=chat.alice.id, action=AuditAction.MESSAGE_SENT)
    await db.rollback()  # … and throw it away: the audit rows must still be there.
    rows = (await db.scalars(select(AuditLog).order_by(AuditLog.seq))).all()
    assert [r.action for r in rows] == ["login", "message_sent"]
    assert [r.seq for r in rows] == [1, 2]
    assert rows[0].prev_hash == "0" * 64 and rows[1].prev_hash == rows[0].hash
    assert len(rows[1].hash) == 64
    assert await AuditService.verify_chain(db) == (2, None)
    # Tampering with a stored row breaks the chain at that row.
    await db.execute(
        update(AuditLog).where(AuditLog.seq == 1).values(meta={"attempt": 99})
    )
    await db.commit()
    assert await AuditService.verify_chain(db) == (0, 1)
    # Legacy (pre-0035) rows: numbered but unhashed, accepted as a prefix only.
    await db.execute(update(AuditLog).where(AuditLog.seq == 1).values(hash=None, prev_hash=None))
    await db.commit()
    checked, bad = await AuditService.verify_chain(db)
    assert bad == 2  # row 2 was chained onto row 1's (now missing) hash


async def test_verify_script_runs(db, chat, monkeypatch, capsys):
    await AuditService.log(db, user_id=chat.alice.id, action=AuditAction.LOGIN)
    spec = importlib.util.spec_from_file_location(
        "verify_audit_chain",
        os.path.join(os.path.dirname(__file__), "..", "scripts", "verify_audit_chain.py"),
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert await mod.main() == 0
    assert "1 hashed rows verified" in capsys.readouterr().out


async def test_admin_audit_api_filters_and_is_super_admin_only(client, chat, db):
    await _send(client, chat.conv.id, chat.alice_headers, "a")
    await _send(client, chat.conv.id, chat.bob_headers, "b")
    _, ops_h = await _super_admin(db)
    assert (await client.get("/api/v1/admin/audit", headers=chat.alice_headers)).status_code == 403
    r = await client.get("/api/v1/admin/audit", headers=ops_h)
    assert r.status_code == 200, r.text
    page = r.json()
    seqs = [row["seq"] for row in page["data"]]
    assert seqs == sorted(seqs, reverse=True)
    assert all("content" not in row for row in page["data"])
    assert any(row["ip_address"] for row in page["data"])
    # Filters: user, action, window, cursor.
    r = await client.get(
        "/api/v1/admin/audit",
        params={"user_id": str(chat.bob.id), "action": "message_sent"},
        headers=ops_h,
    )
    rows = r.json()["data"]
    assert len(rows) == 1 and rows[0]["user_id"] == str(chat.bob.id)
    r = await client.get("/api/v1/admin/audit", params={"limit": 1}, headers=ops_h)
    first = r.json()
    assert first["next_cursor"] == first["data"][0]["seq"]
    r = await client.get(
        "/api/v1/admin/audit", params={"limit": 1, "cursor": first["next_cursor"]}, headers=ops_h
    )
    assert r.json()["data"][0]["seq"] == first["next_cursor"] - 1
    future = (datetime.now(tz=timezone.utc) + timedelta(days=1)).isoformat()
    r = await client.get("/api/v1/admin/audit", params={"from": future}, headers=ops_h)
    assert r.json()["data"] == []
    # Reading the trail is itself on the trail.
    reads = (
        await db.scalars(select(AuditLog).where(AuditLog.action == AuditAction.AUDIT_READ.value))
    ).all()
    assert len(reads) == 5 and reads[0].meta["scope"] == "global"


async def test_org_audit_is_scoped_to_members_on_org_resources(client, chat, db):
    admin, admin_h = await _admin(db, chat.org)
    await _send(client, chat.conv.id, chat.alice_headers, "ours")
    # Another org, another conversation: invisible to this org's admin.
    other_org = await helpers.create_org(db, name="Elsewhere")
    carol = await helpers.create_user(db, full_name="Dr Carol")
    dave = await helpers.create_user(db, full_name="Dr Dave")
    await helpers.add_org_member(db, other_org, carol)
    await helpers.add_org_member(db, other_org, dave)
    other_conv = await helpers.create_conversation(db, other_org, [carol, dave])
    await _send(client, other_conv.id, await helpers.auth_headers(carol.id), "theirs")
    # A member's action on a non-org resource (login) is excluded too.
    await AuditService.log(db, user_id=chat.alice.id, action=AuditAction.LOGIN)

    assert (await client.get(f"{ORGS}/{chat.org.id}/audit", headers=chat.alice_headers)).status_code == 403
    r = await client.get(f"{ORGS}/{chat.org.id}/audit", headers=admin_h)
    assert r.status_code == 200, r.text
    rows = r.json()["data"]
    assert {row["user_id"] for row in rows} == {str(chat.alice.id)}
    assert {row["action"] for row in rows} == {"message_sent"}
    assert rows[0]["ip_address"] is None and rows[0]["user_agent"] is None
    r = await client.get(f"{ORGS}/{other_org.id}/audit", headers=admin_h)
    assert r.status_code == 403


# ============================================================ break-glass ==


async def _file_request(client, org_id, conv_id, headers, reason="Patient safety review"):
    return await client.post(
        f"{ORGS}/{org_id}/access-requests",
        json={"conversation_id": str(conv_id), "reason": reason},
        headers=headers,
    )


async def test_break_glass_full_flow(client, chat, db):
    requester, req_h = await _admin(db, chat.org, "Dr Requester")
    approver, app_h = await _admin(db, chat.org, "Dr Approver")
    await client.patch(f"{ORGS}/{chat.org.id}/policies", json={"legal_hold": True}, headers=req_h)
    m1 = await _send(client, chat.conv.id, chat.alice_headers, "bp 180/110 — called cardiology")
    m2 = await _send(client, chat.conv.id, chat.bob_headers, "on my way")
    await client.delete(f"{MSGS}/{m2['id']}", headers=chat.bob_headers)  # held tombstone

    # Guards: doctors cannot file, reason required, foreign conversation 404.
    assert (
        await _file_request(client, chat.org.id, chat.conv.id, chat.alice_headers)
    ).status_code == 403
    assert (await _file_request(client, chat.org.id, chat.conv.id, req_h, reason="  ")).status_code == 422
    stranger_org = await helpers.create_org(db, name="Other")
    s1 = await helpers.create_user(db, full_name="S1")
    s2 = await helpers.create_user(db, full_name="S2")
    await helpers.add_org_member(db, stranger_org, s1)
    await helpers.add_org_member(db, stranger_org, s2)
    foreign = await helpers.create_conversation(db, stranger_org, [s1, s2])
    r = await _file_request(client, chat.org.id, foreign.id, req_h)
    assert r.status_code == 404 and r.json()["detail"] == "conversation_not_found"

    r = await _file_request(client, chat.org.id, chat.conv.id, req_h)
    assert r.status_code == 201, r.text
    req = r.json()
    assert req["status"] == "pending" and req["requester_id"] == str(requester.id)
    rid = req["id"]
    # Duplicate pending → 409; the other admin got a feed notification.
    assert (await _file_request(client, chat.org.id, chat.conv.id, req_h)).status_code == 409
    note = await db.scalar(select(Notification).where(Notification.user_id == approver.id))
    assert note.type == "access_request_pending" and note.payload == {"org_id": str(chat.org.id)}
    # Nothing readable before approval; self-approval refused; doctors refused.
    r = await client.get(f"{ORGS}/{chat.org.id}/access-requests/{rid}/messages", headers=req_h)
    assert r.status_code == 403 and r.json()["detail"] == "access_request_not_approved"
    r = await client.post(f"{ORGS}/{chat.org.id}/access-requests/{rid}/approve", headers=req_h)
    assert r.status_code == 403 and r.json()["detail"] == "self_approval_forbidden"
    assert (
        await client.post(
            f"{ORGS}/{chat.org.id}/access-requests/{rid}/approve", headers=chat.alice_headers
        )
    ).status_code == 403

    r = await client.post(f"{ORGS}/{chat.org.id}/access-requests/{rid}/approve", headers=app_h)
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "approved" and r.json()["decided_by"] == str(approver.id)
    expires = datetime.fromisoformat(r.json()["expires_at"])
    assert timedelta(hours=23) < expires - datetime.now(tz=timezone.utc) <= timedelta(hours=24)
    # Approving twice / rejecting after approval → 409.
    r = await client.post(f"{ORGS}/{chat.org.id}/access-requests/{rid}/reject", headers=app_h)
    assert r.status_code == 409
    note = await db.scalar(select(Notification).where(Notification.user_id == requester.id))
    assert note.type == "access_request_decided" and note.payload["approved"] is True

    # Only the requester may read, even though the approver is an admin.
    r = await client.get(f"{ORGS}/{chat.org.id}/access-requests/{rid}/messages", headers=app_h)
    assert r.status_code == 403 and r.json()["detail"] == "not_requester"
    r = await client.get(f"{ORGS}/{chat.org.id}/access-requests/{rid}/messages", headers=req_h)
    assert r.status_code == 200, r.text
    page = r.json()["data"]
    by_id = {m["id"]: m for m in page}
    assert by_id[m1["id"]]["content"] == "bp 180/110 — called cardiology"
    # The held tombstone is readable here and only here.
    assert by_id[m2["id"]]["content"] == "on my way" and by_id[m2["id"]]["deleted_at"]
    # The members got the policy line, once, as a normal system message.
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    systems = [m for m in r.json() if m["type"] == "system"]
    assert [m["content"] for m in systems] == [
        "An administrator accessed this conversation under policy"
    ]
    await client.get(f"{ORGS}/{chat.org.id}/access-requests/{rid}/messages", headers=req_h)
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    assert len([m for m in r.json() if m["type"] == "system"]) == 1
    reads = (
        await db.scalars(
            select(AuditLog).where(AuditLog.action == AuditAction.BREAK_GLASS_READ.value)
        )
    ).all()
    assert len(reads) == 2 and reads[0].resource_id == chat.conv.id
    assert reads[0].meta["access_request_id"] == rid
    # List for admins; status mirrors the effective state.
    r = await client.get(f"{ORGS}/{chat.org.id}/access-requests", headers=app_h)
    assert [x["id"] for x in r.json()["data"]] == [rid]
    assert r.json()["data"][0]["first_read_at"]

    # Expiry: past the window the read is refused and the job stamps it.
    await db.execute(
        update(AccessRequest)
        .where(AccessRequest.id == uuid.UUID(rid))
        .values(expires_at=datetime.now(tz=timezone.utc) - timedelta(minutes=1))
    )
    await db.commit()
    r = await client.get(f"{ORGS}/{chat.org.id}/access-requests/{rid}/messages", headers=req_h)
    assert r.status_code == 403 and r.json()["detail"] == "access_request_expired"
    r = await client.get(f"{ORGS}/{chat.org.id}/access-requests", headers=app_h)
    assert r.json()["data"][0]["status"] == "expired"
    from app.services.compliance_service import BreakGlassService

    lapsed = await BreakGlassService.expire(db)
    await db.commit()
    assert [x.id for x in lapsed] == [uuid.UUID(rid)]
    assert (await db.get(AccessRequest, uuid.UUID(rid))).status == AccessRequestStatus.EXPIRED
    # Unknown id / other org's id → 404.
    assert (
        await client.get(f"{ORGS}/{chat.org.id}/access-requests/{uuid.uuid4()}/messages", headers=req_h)
    ).status_code == 404


async def test_break_glass_reject(client, chat, db):
    requester, req_h = await _admin(db, chat.org, "Dr Requester")
    approver, app_h = await _admin(db, chat.org, "Dr Approver")
    rid = (await _file_request(client, chat.org.id, chat.conv.id, req_h)).json()["id"]
    r = await client.post(f"{ORGS}/{chat.org.id}/access-requests/{rid}/reject", headers=app_h)
    assert r.status_code == 200 and r.json()["status"] == "rejected"
    assert r.json()["expires_at"] is None
    r = await client.get(f"{ORGS}/{chat.org.id}/access-requests/{rid}/messages", headers=req_h)
    assert r.status_code == 403 and r.json()["detail"] == "access_request_not_approved"
    actions = {
        a.action
        for a in (await db.scalars(select(AuditLog).where(AuditLog.resource_id == uuid.UUID(rid)))).all()
    }
    assert actions == {"access_request_created", "access_request_rejected"}
    # A network conversation that involves one org member is in scope too.
    outsider = await helpers.create_user(db, full_name="Dr Out")
    net = Conversation(org_id=None, type=ConversationType.DIRECT, created_by=outsider.id)
    db.add(net)
    await db.flush()
    from app.models import ConversationMember

    db.add_all(
        [
            ConversationMember(conversation_id=net.id, user_id=outsider.id),
            ConversationMember(conversation_id=net.id, user_id=chat.alice.id),
        ]
    )
    await db.commit()
    assert (await _file_request(client, chat.org.id, net.id, req_h)).status_code == 201


# ============================================================ org reports ==


async def test_org_reports_scoped_and_patchable(client, chat, db):
    admin, admin_h = await _admin(db, chat.org)
    msg = await _send(client, chat.conv.id, chat.bob_headers, "x")
    # 1) member reports a member's message; 2) outsider reports a member;
    # 3) a report with nobody from the org.
    r = await client.post(
        "/api/v1/network/reports",
        json={"subject_type": "message", "subject_id": msg["id"], "reason": "spam"},
        headers=chat.alice_headers,
    )
    assert r.status_code == 201
    outsider = await helpers.create_user(db, full_name="Out")
    out_h = await helpers.auth_headers(outsider.id)
    r = await client.post(
        "/api/v1/network/reports",
        json={"subject_id": str(chat.bob.id), "reason": "harassment"},
        headers=out_h,
    )
    assert r.status_code == 201
    stranger = await helpers.create_user(db, full_name="Stranger")
    r = await client.post(
        "/api/v1/network/reports",
        json={"subject_id": str(stranger.id), "reason": "other"},
        headers=out_h,
    )
    assert r.status_code == 201
    from app.models import Report

    unrelated_id = await db.scalar(select(Report.id).where(Report.subject_id == stranger.id))

    assert (await client.get(f"{ORGS}/{chat.org.id}/reports", headers=chat.alice_headers)).status_code == 403
    r = await client.get(f"{ORGS}/{chat.org.id}/reports", headers=admin_h)
    assert r.status_code == 200, r.text
    rows = r.json()
    assert sorted(x["reason"] for x in rows) == ["harassment", "spam"]
    assert all("content" not in x for x in rows)
    rid = next(x["id"] for x in rows if x["reason"] == "spam")
    r = await client.patch(f"{ORGS}/{chat.org.id}/reports/{rid}", json={"status": "actioned"}, headers=admin_h)
    assert r.status_code == 200 and r.json()["resolved_by"] == str(admin.id)
    assert len((await client.get(f"{ORGS}/{chat.org.id}/reports", headers=admin_h)).json()) == 1
    assert len((await client.get(f"{ORGS}/{chat.org.id}/reports", params={"status": "all"}, headers=admin_h)).json()) == 2
    # A report with nobody from the org is invisible — 404, no oracle.
    r = await client.patch(
        f"{ORGS}/{chat.org.id}/reports/{unrelated_id}", json={"status": "dismissed"}, headers=admin_h
    )
    assert r.status_code == 404
    audit = await db.scalar(
        select(AuditLog).where(AuditLog.action == AuditAction.REPORT_STATUS_CHANGED.value)
    )
    assert audit.meta["org_id"] == str(chat.org.id)


# ============================================================== scheduled ==


async def test_scheduled_list_and_cancel(client, chat, db):
    tomorrow = (datetime.now(tz=timezone.utc) + timedelta(days=1)).date()

    async def _schedule(headers, content):
        r = await client.post(
            f"{CONVS}/{chat.conv.id}/messages/schedule",
            json={"content": content, "scheduled_local": f"{tomorrow}T10:00:00", "timezone": "UTC"},
            headers=headers,
        )
        assert r.status_code == 200, r.text
        return r.json()["id"]

    mine = await _schedule(chat.alice_headers, "alice later")
    theirs = await _schedule(chat.bob_headers, "bob later")
    r = await client.get(f"{CONVS}/{chat.conv.id}/scheduled", headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    assert [x["id"] for x in r.json()] == [mine]
    assert "content" not in r.json()[0] and r.json()[0]["status"] == "pending"
    outsider = await helpers.create_user(db, full_name="Out")
    assert (
        await client.get(f"{CONVS}/{chat.conv.id}/scheduled", headers=await helpers.auth_headers(outsider.id))
    ).status_code == 403
    # Cancel: others' → 404, own → gone, sent → 404.
    assert (await client.delete(f"/api/v1/scheduled/{theirs}", headers=chat.alice_headers)).status_code == 404
    assert (await client.delete(f"/api/v1/scheduled/{mine}", headers=chat.alice_headers)).status_code == 200
    assert await db.get(ScheduledMessage, uuid.UUID(mine)) is None
    await db.execute(
        update(ScheduledMessage).where(ScheduledMessage.id == uuid.UUID(theirs)).values(status="sent")
    )
    await db.commit()
    assert (await client.delete(f"/api/v1/scheduled/{theirs}", headers=chat.bob_headers)).status_code == 404
    assert (await client.get(f"{CONVS}/{chat.conv.id}/scheduled", headers=chat.bob_headers)).json() == []


# ============================================================= well-known ==


async def test_well_known_routes(client):
    r = await client.get("/.well-known/apple-app-site-association")
    assert r.status_code == 200 and r.headers["content-type"].startswith("application/json")
    details = r.json()["applinks"]["details"][0]
    assert details["appIDs"] == ["3N7394B3B9.com.doqto.ios"]
    assert [c["/"] for c in details["components"]] == ["/g/*", "/c/*", "/u/*"]
    r = await client.get("/.well-known/assetlinks.json")
    assert r.status_code == 200
    target = r.json()[0]["target"]
    assert target["package_name"] == "com.doqto.app" and target["sha256_cert_fingerprints"] == []


# ================================================================= crypto ==


class FakeKms:
    """Stands in for boto3's KMS client: XOR-"wraps" with a fixed pad and
    records the encryption context, so tests prove the KMS path is taken."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []

    def encrypt(self, *, KeyId, Plaintext, EncryptionContext):
        self.calls.append(("encrypt", EncryptionContext))
        return {"CiphertextBlob": b"kms:" + bytes(b ^ 0x5A for b in Plaintext)}

    def decrypt(self, *, CiphertextBlob, EncryptionContext):
        self.calls.append(("decrypt", EncryptionContext))
        assert CiphertextBlob.startswith(b"kms:")
        return {"Plaintext": bytes(b ^ 0x5A for b in CiphertextBlob[4:])}


@pytest.fixture
def fresh_crypto():
    crypto.set_wrapper(None)
    yield
    crypto.set_wrapper(None)


async def test_new_messages_use_org_data_key_and_legacy_rows_migrate(client, chat, db, fresh_crypto):
    carol = await helpers.create_user(db, full_name="Dr Carol")
    await helpers.connect_users(db, chat.alice, carol)
    sent = await _send(client, chat.conv.id, chat.alice_headers, "hello")
    row = await db.get(Message, uuid.UUID(sent["id"]))
    key = await db.get(DataKey, row.key_version)
    assert key.scope == f"org:{chat.org.id}" and key.wrapper == "static"
    # The blob is NOT readable with the static key any more.
    from app.core.security import decrypt_message

    with pytest.raises(Exception):
        decrypt_message(row.content_encrypted)
    assert crypto.decrypt(row.content_encrypted, row.key_version) == "hello"

    # A legacy row (version 0) reads fine and moves to the org key on edit.
    legacy = _old_message(chat.conv, chat.alice, 99, days=0, content="legacy body")
    db.add(legacy)
    await db.commit()
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    assert "legacy body" in [m["content"] for m in r.json()]
    r = await client.patch(f"{MSGS}/{legacy.id}", json={"content": "edited"}, headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    await db.refresh(legacy)
    assert legacy.key_version == row.key_version
    edit = await db.scalar(select(MessageEdit).where(MessageEdit.message_id == legacy.id))
    assert edit.key_version == 0  # history keeps the version it was written under
    r = await client.get(f"{MSGS}/{legacy.id}/edits", headers=chat.bob_headers)
    assert r.json()[0]["content"] == "legacy body"
    # Forwarding into a network chat re-encrypts under the network key.
    r = await client.post(CONVS, json={"type": "direct", "member_ids": [str(carol.id)]}, headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    net_id = r.json()["id"]
    r = await client.post(f"{MSGS}/{sent['id']}/forward", json={"conversation_ids": [net_id]}, headers=chat.alice_headers)
    assert r.status_code == 200, r.text
    copy = await db.get(Message, uuid.UUID(r.json()[0]["id"]))
    assert (await db.get(DataKey, copy.key_version)).scope == "network"
    assert crypto.decrypt(copy.content_encrypted, copy.key_version) == "hello"


async def test_kms_wrapper_is_used_when_configured(client, chat, db, fresh_crypto):
    fake = FakeKms()
    crypto.set_wrapper(crypto.KmsKeyWrapper("arn:aws:kms:us-east-1:1:key/abc", client=fake))
    sent = await _send(client, chat.conv.id, chat.alice_headers, "via kms")
    row = await db.get(Message, uuid.UUID(sent["id"]))
    key = await db.get(DataKey, row.key_version)
    assert key.wrapper == "kms" and key.kms_key_id.endswith("key/abc")
    assert key.wrapped_key.startswith(b"kms:")
    assert ("encrypt", {"scope": f"org:{chat.org.id}"}) in fake.calls
    # A cold process (empty cache) unwraps through KMS again and reads the row.
    crypto.reset_cache()
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    assert r.json()[0]["content"] == "via kms"
    assert ("decrypt", {"scope": f"org:{chat.org.id}"}) in fake.calls


async def test_rotation_and_rewrap(client, chat, db, fresh_crypto):
    first = await _send(client, chat.conv.id, chat.alice_headers, "before rotation")
    v1 = (await db.get(Message, uuid.UUID(first["id"]))).key_version
    scope = f"org:{chat.org.id}"
    spec = importlib.util.spec_from_file_location(
        "rotate_keys", os.path.join(os.path.dirname(__file__), "..", "scripts", "rotate_keys.py")
    )
    rotate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rotate)
    await rotate.cmd_rotate(db, [scope])
    retired = await db.get(DataKey, v1)
    assert retired.retired_at is not None
    assert (await db.scalar(select(AuditLog).where(AuditLog.action == "key_rotated"))).meta["scope"] == scope
    # New sends use the new version; the old row still decrypts.
    second = await _send(client, chat.conv.id, chat.alice_headers, "after rotation")
    v2 = (await db.get(Message, uuid.UUID(second["id"]))).key_version
    assert v2 > v1
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    assert {m["content"] for m in r.json()} == {"before rotation", "after rotation"}
    # Rewrap moves everything (incl. a legacy row) to the active version.
    db.add(_old_message(chat.conv, chat.alice, 77, days=0, content="legacy"))
    await db.commit()
    await rotate.cmd_rewrap(db, [scope], 100)
    versions = (await db.scalars(select(Message.key_version).where(Message.conversation_id == chat.conv.id))).all()
    assert set(versions) == {v2}
    r = await client.get(f"{CONVS}/{chat.conv.id}/messages", headers=chat.bob_headers)
    assert {m["content"] for m in r.json()} == {"before rotation", "after rotation", "legacy"}
    # to-legacy puts them back under the static key for a downgrade.
    conv_id = chat.conv.id
    await rotate.cmd_to_legacy(db, [scope], 100)
    from app.core.security import decrypt_message

    rows = (
        await db.scalars(
            select(Message)
            .where(Message.conversation_id == conv_id)
            .execution_options(populate_existing=True)
        )
    ).all()
    assert all(r.key_version == 0 for r in rows)
    assert sorted(decrypt_message(r.content_encrypted) for r in rows) == [
        "after rotation", "before rotation", "legacy"
    ]


async def test_cold_cache_loads_key_from_db_synchronously(client, chat, db, fresh_crypto):
    """to_out is sync: a version this process has never seen is fetched on a
    helper thread and cached, instead of failing."""
    sent = await _send(client, chat.conv.id, chat.alice_headers, "cold")
    row = await db.get(Message, uuid.UUID(sent["id"]))
    crypto.reset_cache()
    assert crypto.describe()["cached_versions"] == []
    assert MessageService.to_out(row).content == "cold"
    assert crypto.describe()["cached_versions"] == [row.key_version]


async def test_audit_user_without_fk_and_migration_shape(db):
    """Audit rows may name a user id that is not (yet / any more) a row."""
    ghost = uuid.uuid4()
    await AuditService.log(db, user_id=ghost, action=AuditAction.LOGIN)
    assert (await db.scalar(select(AuditLog).where(AuditLog.user_id == ghost))) is not None
    cols = {
        r[0]
        for r in (
            await db.execute(
                text("SELECT column_name FROM information_schema.columns WHERE table_name='messages'")
            )
        ).all()
    }
    assert "key_version" in cols
