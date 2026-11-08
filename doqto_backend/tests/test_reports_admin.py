"""Message reports + the super-admin moderation queue (batch 4)."""
from __future__ import annotations

import uuid

from sqlalchemy import select

from app.core.enums import AuditAction, ReportStatus, UserRole
from app.models import AuditLog, Report
from tests import helpers

REPORTS = "/api/v1/network/reports"
ADMIN = "/api/v1/admin/reports"


async def _send(client, conv_id, headers, content):
    r = await client.post(
        f"/api/v1/conversations/{conv_id}/messages", json={"content": content}, headers=headers
    )
    assert r.status_code == 200, r.text
    return r.json()


async def _super_admin(db):
    admin = await helpers.create_user(db, full_name="Ops")
    admin.role = UserRole.SUPER_ADMIN
    await db.commit()
    return await helpers.auth_headers(admin.id)


async def test_message_report_stores_context_ids_only(client, chat, db):
    m1 = await _send(client, chat.conv.id, chat.bob_headers, "spam one")
    m2 = await _send(client, chat.conv.id, chat.bob_headers, "spam two")
    stray = str(uuid.uuid4())
    r = await client.post(
        REPORTS,
        json={
            "subject_type": "message",
            "subject_id": m2["id"],
            "reason": "spam",
            "details": "keeps posting ads",
            "context_message_ids": [m1["id"], m2["id"], stray],
        },
        headers=chat.alice_headers,
    )
    assert r.status_code == 201, r.text
    rep = (await db.scalars(select(Report))).one()
    assert rep.subject_type == "message" and rep.subject_id == uuid.UUID(m2["id"])
    assert rep.reason == "spam" and rep.status == ReportStatus.OPEN
    # Ids outside the conversation are dropped; bodies are never stored.
    assert rep.context_message_ids == [uuid.UUID(m1["id"]), uuid.UUID(m2["id"])]
    assert "spam one" not in str(rep.__dict__)
    audit = await db.scalar(select(AuditLog).where(AuditLog.action == AuditAction.REPORT_FILED.value))
    assert audit.meta == {"reason": "spam"}


async def test_message_report_security(client, chat, db):
    msg = await _send(client, chat.conv.id, chat.bob_headers, "x")
    outsider = await helpers.create_user(db, full_name="Dr Out")
    # Outsider → same 404 as a missing id (no oracle for message ids).
    r = await client.post(
        REPORTS,
        json={"subject_type": "message", "subject_id": msg["id"], "reason": "harassment"},
        headers=await helpers.auth_headers(outsider.id),
    )
    assert r.status_code == 404 and r.json()["detail"] == "message_not_found"
    r = await client.post(
        REPORTS,
        json={"subject_type": "message", "subject_id": str(uuid.uuid4()), "reason": "harassment"},
        headers=chat.alice_headers,
    )
    assert r.status_code == 404
    # Unknown reason / too many context ids / unknown subject type → 422.
    r = await client.post(
        REPORTS, json={"subject_id": str(chat.bob.id), "reason": "rude"}, headers=chat.alice_headers
    )
    assert r.status_code == 422
    r = await client.post(
        REPORTS,
        json={
            "subject_type": "message",
            "subject_id": msg["id"],
            "reason": "spam",
            "context_message_ids": [str(uuid.uuid4()) for _ in range(6)],
        },
        headers=chat.alice_headers,
    )
    assert r.status_code == 422
    r = await client.post(
        REPORTS, json={"subject_type": "group", "subject_id": msg["id"], "reason": "spam"},
        headers=chat.alice_headers,
    )
    assert r.status_code == 422
    # Reporting yourself or a ghost user.
    r = await client.post(
        REPORTS, json={"subject_id": str(chat.alice.id), "reason": "other"}, headers=chat.alice_headers
    )
    assert r.status_code == 404
    # Every reason the picker offers is accepted for a user report.
    for reason in ("spam", "harassment", "phi_misuse", "impersonation", "other"):
        r = await client.post(
            REPORTS, json={"subject_id": str(chat.bob.id), "reason": reason}, headers=chat.alice_headers
        )
        assert r.status_code == 201, reason


async def test_admin_queue_lists_filters_and_sets_status(client, chat, db):
    msg = await _send(client, chat.conv.id, chat.bob_headers, "x")
    for reason in ("spam", "phi_misuse"):
        r = await client.post(
            REPORTS,
            json={"subject_type": "message", "subject_id": msg["id"], "reason": reason},
            headers=chat.alice_headers,
        )
        assert r.status_code == 201
    admin_h = await _super_admin(db)

    # Doctors are refused; super-admins see the open queue newest first.
    assert (await client.get(ADMIN, headers=chat.alice_headers)).status_code == 403
    r = await client.get(ADMIN, headers=admin_h)
    assert r.status_code == 200, r.text
    rows = r.json()
    assert [x["reason"] for x in rows] == ["phi_misuse", "spam"]
    assert rows[0]["status"] == "open" and rows[0]["context_message_ids"] is None
    assert "content" not in rows[0]

    # Move one through the lifecycle.
    rid = rows[1]["id"]
    r = await client.patch(f"{ADMIN}/{rid}", json={"status": "reviewing"}, headers=admin_h)
    assert r.status_code == 200 and r.json()["status"] == "reviewing"
    assert r.json()["resolved_at"] is None
    r = await client.patch(f"{ADMIN}/{rid}", json={"status": "actioned"}, headers=admin_h)
    assert r.json()["status"] == "actioned" and r.json()["resolved_by"] and r.json()["resolved_at"]
    # Same status again is a no-op (no extra audit row).
    r = await client.patch(f"{ADMIN}/{rid}", json={"status": "actioned"}, headers=admin_h)
    assert r.status_code == 200
    changes = (
        await db.scalars(
            select(AuditLog).where(AuditLog.action == AuditAction.REPORT_STATUS_CHANGED.value)
        )
    ).all()
    assert [(a.meta["from"], a.meta["to"]) for a in changes] == [
        ("open", "reviewing"), ("reviewing", "actioned")
    ]

    # Filters: default open (1 left), explicit actioned, all.
    assert len((await client.get(ADMIN, headers=admin_h)).json()) == 1
    assert len((await client.get(ADMIN, params={"status": "actioned"}, headers=admin_h)).json()) == 1
    assert len((await client.get(ADMIN, params={"status": "all"}, headers=admin_h)).json()) == 2
    assert (await client.get(ADMIN, params={"status": "bogus"}, headers=admin_h)).status_code == 422
    # Unknown report / doctor patching.
    assert (
        await client.patch(f"{ADMIN}/{uuid.uuid4()}", json={"status": "dismissed"}, headers=admin_h)
    ).status_code == 404
    assert (
        await client.patch(f"{ADMIN}/{rid}", json={"status": "dismissed"}, headers=chat.alice_headers)
    ).status_code == 403
