"""Attaching a phone number to an account that signed in another way.

A Google/Apple/Facebook user has no phone. Your Details offers an optional one,
and it must be proved — otherwise anyone could claim any number.

This is NOT sign-in: signing in with a phone signs you in *as* whoever owns it,
which would swap accounts mid-registration. Instead the client links the phone
to its existing Firebase user and sends the refreshed ID token, whose
phone_number claim is Google's word that the SMS was answered.
"""
from __future__ import annotations

import pytest

from tests import helpers

pytestmark = pytest.mark.asyncio

PHONE = "+13125339656"


async def test_a_verified_phone_is_attached_to_the_account(client, db, firebase):
    user = await helpers.create_user(db)
    user.phone = None
    user.email = "social@example.com"
    user.firebase_uid = "uid-1"
    await db.commit()
    firebase(uid="uid-1", phone=PHONE, email="social@example.com")

    r = await client.post(
        "/api/v1/users/me/phone",
        json={"id_token": "linked"},
        headers=await helpers.auth_headers(user.id),
    )

    assert r.status_code == 200
    assert r.json()["phone"] == PHONE
    await db.refresh(user)
    assert user.phone == PHONE


async def test_a_token_without_a_phone_claim_is_refused(client, db, firebase):
    """The link never happened — Firebase would assert the number if it had."""
    user = await helpers.create_user(db)
    user.firebase_uid = "uid-1"
    await db.commit()
    firebase(uid="uid-1", email="social@example.com")

    r = await client.post(
        "/api/v1/users/me/phone",
        json={"id_token": "not-linked"},
        headers=await helpers.auth_headers(user.id),
    )

    assert r.status_code == 400


async def test_a_token_for_a_different_firebase_user_is_refused(client, db, firebase):
    """Otherwise a token borrowed from another account could move its number."""
    user = await helpers.create_user(db)
    user.firebase_uid = "uid-mine"
    await db.commit()
    firebase(uid="uid-someone-else", phone=PHONE)

    r = await client.post(
        "/api/v1/users/me/phone",
        json={"id_token": "someone-elses"},
        headers=await helpers.auth_headers(user.id),
    )

    assert r.status_code == 403


async def test_a_number_already_on_another_account_is_refused(client, db, firebase):
    other = await helpers.create_user(db)
    other.phone = PHONE
    user = await helpers.create_user(db)
    user.firebase_uid = "uid-1"
    await db.commit()
    firebase(uid="uid-1", phone=PHONE)

    r = await client.post(
        "/api/v1/users/me/phone",
        json={"id_token": "linked"},
        headers=await helpers.auth_headers(user.id),
    )

    assert r.status_code == 409
    assert r.json()["detail"] == "phone_already_registered"
