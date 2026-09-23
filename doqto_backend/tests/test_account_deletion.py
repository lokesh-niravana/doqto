"""App Store 5.1.1(v) account deletion.

The account must become unusable and personal data must be gone, while the
audit trail survives (HIPAA §164.316(b)(2), six-year retention).
"""
from __future__ import annotations

from types import SimpleNamespace

import pytest
from sqlalchemy import select

from app.core.enums import AuditAction
from app.models import AuditLog, Connection, Message, User
from app.services.account_deletion_service import AccountDeletionService
from app.services.stripe_client import Subscription
from tests.helpers import (
    add_org_member,
    auth_headers,
    connect_users,
    create_conversation,
    create_org,
    create_user,
)


@pytest.fixture
async def deleted_setup(db):
    """Returns plain UUIDs — ORM instances expire on commit and re-loading
    them from a sync context raises MissingGreenlet."""
    org = await create_org(db)
    alice = await create_user(db, full_name="Dr Alice", specialty="Cardiology", city="Austin")
    bob = await create_user(db, full_name="Dr Bob")
    await add_org_member(db, org, alice)
    await add_org_member(db, org, bob)
    await connect_users(db, alice, bob)
    conv = await create_conversation(db, org, [alice, bob])
    db.add(
        Message(
            conversation_id=conv.id,
            sender_id=alice.id,
            type="text",
            seq=1,
            content_encrypted=b"patient in bed 12 is stable",
        )
    )
    await db.commit()
    return SimpleNamespace(alice_id=alice.id, bob_id=bob.id)


async def test_delete_scrubs_identity_and_content(client, db, deleted_setup):
    alice_id = deleted_setup.alice_id
    headers = await auth_headers(alice_id)

    r = await client.delete("/api/v1/users/me", headers=headers)
    assert r.status_code == 200, r.text

    db.expire_all()
    row = await db.scalar(select(User).where(User.id == alice_id))
    assert row is not None, "tombstone must survive — audit rows FK to it"
    assert row.deleted_at is not None
    assert row.full_name == "Deleted user"
    assert row.email is None and row.specialty is None and row.city is None
    assert "Alice" not in (row.full_name or "")
    # Identity fields are rewritten, not merely blanked (both are UNIQUE).
    assert row.phone.startswith("d") and len(row.phone) <= 20
    assert len(row.npi_number) == 10

    msg = await db.scalar(select(Message).where(Message.sender_id == alice_id))
    assert msg.content_encrypted is None, "PHI must not survive deletion"
    assert msg.is_deleted is True


async def test_deleted_account_cannot_authenticate(client, db, deleted_setup):
    alice_id = deleted_setup.alice_id
    headers = await auth_headers(alice_id)
    assert (await client.get("/api/v1/users/me", headers=headers)).status_code == 200

    await client.delete("/api/v1/users/me", headers=headers)

    # Same still-valid token, now refused: the session was never revoked, the
    # tombstone check is what stops it.
    r = await client.get("/api/v1/users/me", headers=headers)
    assert r.status_code == 401
    assert r.json()["detail"] == "account_deleted"


async def test_graph_removed_but_audit_retained(client, db, deleted_setup):
    alice_id, bob_id = deleted_setup.alice_id, deleted_setup.bob_id
    headers = await auth_headers(alice_id)
    await client.delete("/api/v1/users/me", headers=headers)

    db.expire_all()
    conns = (await db.scalars(select(Connection).where(Connection.user_id == alice_id))).all()
    assert conns == [], "connections must be dropped in both directions"
    mirrored = (
        await db.scalars(select(Connection).where(Connection.connected_user_id == alice_id))
    ).all()
    assert mirrored == []

    logged = await db.scalar(
        select(AuditLog).where(
            AuditLog.user_id == alice_id, AuditLog.action == AuditAction.ACCOUNT_DELETED
        )
    )
    assert logged is not None, "HIPAA retention: the deletion itself must be auditable"


async def test_deleted_user_absent_from_directory(client, db, deleted_setup):
    alice_id, bob_id = deleted_setup.alice_id, deleted_setup.bob_id
    await client.delete("/api/v1/users/me", headers=await auth_headers(alice_id))

    r = await client.get("/api/v1/people/search?q=Alice", headers=await auth_headers(bob_id))
    assert r.status_code == 200, r.text
    names = [c["full_name"] for c in r.json()["data"]]
    assert not any("Alice" in n or "Deleted" in n for n in names)


async def test_deleting_a_social_only_account_without_a_phone(db):
    """Social sign-in produces users with phone NULL. The audit metadata used
    to slice user.phone[-4:], which raises on None and aborts the deletion."""
    user = await create_user(db)
    user.phone = None
    user.email = "social@example.com"
    user.firebase_uid = "uid-social"
    await db.commit()

    await AccountDeletionService.delete_account(user=user, db=db)
    await db.commit()

    assert user.deleted_at is not None


async def test_deletion_clears_the_firebase_uid(db):
    """Otherwise the provider account still maps to the tombstone, and signing
    in with the same Google account would adopt a deleted user."""
    user = await create_user(db)
    user.firebase_uid = "uid-to-scrub"
    await db.commit()

    await AccountDeletionService.delete_account(user=user, db=db)
    await db.commit()

    assert user.firebase_uid is None


def _sub(sub_id: str, status: str) -> Subscription:
    return Subscription(sub_id, "cus_fake0", status, None, None)


async def test_deletion_cancels_a_live_subscription(client, db, stripe_gateway):
    # Otherwise a deleted doctor keeps being charged for an account that no
    # longer exists.
    user = await create_user(db)
    user.stripe_customer_id = "cus_fake0"
    user.stripe_subscription_id = "sub_1"
    user.billing_status = "active"
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = _sub("sub_1", "active")
    # Paid a second time before the first webhook landed: the mirror never
    # heard of it, and it must still stop.
    stripe_gateway.subscriptions["sub_2"] = _sub("sub_2", "active")

    r = await client.delete("/api/v1/users/me", headers=await auth_headers(user.id))

    assert r.status_code == 200, r.text
    assert sorted(stripe_gateway.cancelled) == ["sub_1", "sub_2"]


async def test_deletion_leaves_a_finished_subscription_alone(client, db, stripe_gateway):
    user = await create_user(db)
    user.stripe_customer_id = "cus_fake0"
    user.stripe_subscription_id = "sub_1"
    user.billing_status = "canceled"
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = _sub("sub_1", "canceled")

    await client.delete("/api/v1/users/me", headers=await auth_headers(user.id))

    assert stripe_gateway.cancelled == []


async def test_deletion_survives_a_stripe_error(client, db, stripe_gateway):
    user = await create_user(db)
    user.stripe_customer_id = "cus_fake0"
    user.stripe_subscription_id = "sub_1"
    user.billing_status = "past_due"
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = _sub("sub_1", "past_due")
    stripe_gateway.cancel_error = RuntimeError("stripe is down")
    user_id = user.id

    r = await client.delete("/api/v1/users/me", headers=await auth_headers(user_id))

    assert r.status_code == 200, r.text
    db.expire_all()
    row = await db.scalar(select(User).where(User.id == user_id))
    assert row.deleted_at is not None


async def test_deletion_works_without_stripe_configured(client, db):
    # No stripe_gateway fixture: billing is switched off in this deployment.
    user = await create_user(db)
    user.stripe_subscription_id = "sub_1"
    user.billing_status = "active"
    await db.commit()

    r = await client.delete("/api/v1/users/me", headers=await auth_headers(user.id))

    assert r.status_code == 200, r.text
