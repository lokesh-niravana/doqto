"""Scheduled messages — long-press send → deliver later."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.core.enums import ScheduledMessageStatus
from app.core import crypto
from app.models import ScheduledMessage


async def _schedule(client, chat, *, content="later", local, tz):
    return await client.post(
        f"/api/v1/conversations/{chat.conv.id}/messages/schedule",
        json={"content": content, "scheduled_local": local, "timezone": tz},
        headers=chat.alice_headers,
    )


async def test_schedule_resolves_timezone_to_utc(client, chat, db):
    # 14:30 IST == 09:00 UTC (IST is fixed +05:30, no DST).
    tomorrow = (datetime.now(tz=timezone.utc) + timedelta(days=1)).date()
    resp = await _schedule(
        client, chat, local=f"{tomorrow}T14:30:00", tz="Asia/Kolkata"
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["timezone"] == "Asia/Kolkata"
    assert body["status"] == "pending"
    scheduled = datetime.fromisoformat(body["scheduled_at"])
    assert scheduled.astimezone(timezone.utc).hour == 9

    row = await db.scalar(
        select(ScheduledMessage).where(ScheduledMessage.id == body["id"])
    )
    assert row is not None
    assert row.status == ScheduledMessageStatus.PENDING
    assert row.key_version > 0  # batch 7: under the org's data key, not the static key
    assert crypto.decrypt(row.content_encrypted, row.key_version) == "later"


async def test_schedule_rejects_past_and_bad_zone(client, chat):
    resp = await _schedule(
        client, chat, local="2020-01-01T00:00:00", tz="Asia/Kolkata"
    )
    assert resp.status_code == 400
    assert resp.json()["detail"] == "invalid_schedule_time"

    tomorrow = (datetime.now(tz=timezone.utc) + timedelta(days=1)).date()
    resp = await _schedule(client, chat, local=f"{tomorrow}T10:00:00", tz="Mars/Olympus")
    assert resp.status_code == 400
    assert resp.json()["detail"] == "invalid_schedule_time"
