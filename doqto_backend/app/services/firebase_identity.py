"""Deleting a sign-in identity from Firebase Auth.

Account deletion (App Store 5.1.1(v)) has to remove the sign-in record too:
Firebase Auth holds the phone number, email and provider links. The app tries
first, but Firebase refuses a client-side delete unless the sign-in is recent,
so the server finishes the job through the Identity Toolkit admin API.

Uses the same google-auth credential as FCM (FCM_SERVICE_ACCOUNT_JSON). That
service account needs the "Firebase Authentication Admin" role; without it the
call is refused, the refusal is logged, and the account deletion still stands.
"""
from __future__ import annotations

import functools
import json
import logging

import httpx
from fastapi.concurrency import run_in_threadpool

from app.core.config import settings

logger = logging.getLogger(__name__)

_SCOPES = [
    "https://www.googleapis.com/auth/identitytoolkit",
    "https://www.googleapis.com/auth/cloud-platform",
]


def _bearer() -> str:
    from google.auth import load_credentials_from_dict
    from google.auth.transport.requests import Request

    creds, _ = load_credentials_from_dict(
        json.loads(settings.FCM_SERVICE_ACCOUNT_JSON), scopes=_SCOPES
    )
    # google-auth waits up to two minutes by default.
    creds.refresh(functools.partial(Request(), timeout=8))
    return creds.token


async def delete_firebase_user(firebase_uid: str | None) -> bool:
    """Best effort. True when Firebase confirms the identity is gone (or was
    never there); False when it is not configured or the call failed."""
    project = settings.FIREBASE_PROJECT_ID or settings.FCM_PROJECT_ID
    if not firebase_uid or not project or not settings.FCM_SERVICE_ACCOUNT_JSON:
        return False
    try:
        token = await run_in_threadpool(_bearer)
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.post(
                f"https://identitytoolkit.googleapis.com/v1/projects/{project}/accounts:delete",
                headers={"Authorization": f"Bearer {token}"},
                json={"localId": firebase_uid},
            )
        if r.status_code == 200:
            return True
        # Already gone (the app deleted it first) is success too.
        if r.status_code == 400 and "USER_NOT_FOUND" in r.text:
            return True
        logger.warning("firebase identity delete refused status=%s", r.status_code)
        return False
    except Exception:
        logger.exception("firebase identity delete failed")
        return False
