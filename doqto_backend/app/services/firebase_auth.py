"""Firebase ID token verification.

Firebase is the identity broker: phone, Google, Facebook and Apple sign-in all
resolve to one ID token, and this is the only place it is inspected. It answers
*who is this*; the backend still decides what they may do.

Verification uses google-auth, already a dependency for FCM v1 — no
firebase-admin, no service-account JSON, and no hand-rolled JWKS on a
security-critical path. verify_firebase_token checks signature, issuer,
audience and expiry against Google's rotating certs (which it caches).

HIPAA: a Firebase ID token carries the minimum needed to sign in — uid, and
phone or email. No PHI is stored in or read from Firebase.

Log policy: NEVER log the token or the full phone number.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from google.auth.transport import requests as google_requests
from google.oauth2 import id_token as google_id_token

from app.core.config import settings

log = logging.getLogger("doqto.firebase")

# google-auth caches Google's signing certs on the Request session, so this is
# reused rather than rebuilt per call.
_request = google_requests.Request()


class FirebaseAuthError(Exception):
    """The token was absent, malformed, expired, or not ours."""


@dataclass(frozen=True)
class FirebaseIdentity:
    uid: str
    phone: str | None = None
    email: str | None = None


def verify_id_token(id_token: str) -> FirebaseIdentity:
    """Verify a Firebase ID token and return the identity it asserts.

    Blocking (google-auth fetches certs over HTTP), so callers run it in a
    threadpool rather than on the event loop.
    """
    project = settings.FIREBASE_PROJECT_ID
    if not project:
        raise RuntimeError("FIREBASE_PROJECT_ID is required to verify Firebase ID tokens")
    try:
        claims = google_id_token.verify_firebase_token(id_token, _request, audience=project)
    except Exception as e:  # google-auth raises ValueError and transport errors alike
        log.info("[FIREBASE] token rejected: %s", type(e).__name__)
        raise FirebaseAuthError("firebase_token_invalid") from e
    if not claims:
        raise FirebaseAuthError("firebase_token_invalid")
    uid = claims.get("sub") or claims.get("user_id")
    if not uid:
        raise FirebaseAuthError("firebase_token_invalid")
    return FirebaseIdentity(
        uid=uid,
        phone=claims.get("phone_number"),
        email=(claims.get("email") or None),
    )
