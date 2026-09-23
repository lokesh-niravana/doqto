"""An expired doctor can read, but cannot send."""
from __future__ import annotations

import pytest

from tests import helpers

pytestmark = pytest.mark.asyncio


async def _expire(db, user) -> None:
    user.trial_ends_at = None
    user.billing_status = None
    await db.commit()


async def test_sending_needs_a_subscription(client, db, chat):
    await _expire(db, chat.alice)

    r = await client.post(
        f"/api/v1/conversations/{chat.conv.id}/messages",
        json={"content": "are you there"},
        headers=chat.alice_headers,
    )

    assert r.status_code == 402
    assert r.json()["detail"] == "subscription_required"


async def test_starting_a_conversation_needs_a_subscription(client, db, chat):
    await _expire(db, chat.alice)

    r = await client.post(
        "/api/v1/conversations",
        json={"type": "direct", "member_ids": [str(chat.bob.id)]},
        headers=chat.alice_headers,
    )

    assert r.status_code == 402


async def test_reading_always_works(client, db, chat):
    await _expire(db, chat.alice)

    r = await client.get(
        f"/api/v1/conversations/{chat.conv.id}/messages", headers=chat.alice_headers
    )

    # Nothing is ever held hostage: the history stays readable.
    assert r.status_code == 200


async def test_the_profile_stays_editable(client, db, chat):
    await _expire(db, chat.alice)

    r = await client.get("/api/v1/users/me", headers=chat.alice_headers)

    assert r.status_code == 200


async def test_a_doctor_in_their_trial_can_send(client, chat):
    # The default test user: proves the gate doesn't break every other suite.
    r = await client.post(
        f"/api/v1/conversations/{chat.conv.id}/messages",
        json={"content": "hello"},
        headers=chat.alice_headers,
    )

    assert r.status_code == 200
