"""The only module that imports Apple's App Store server library.

The app buys with StoreKit 2 and hands us the transaction's JWS; Apple's
server notifications send the same JWS inside a signed payload. Both are
verified against Apple's root certificate here, and everything else speaks
in `AppleTransaction`.
"""
from __future__ import annotations

from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import NamedTuple

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.signed_data_verifier import (
    SignedDataVerifier,
    VerificationException,
    VerificationStatus,
)

from app.core.config import settings

_ROOT = Path(__file__).resolve().parent.parent / "certs" / "AppleRootCA-G3.cer"


class AppleTransaction(NamedTuple):
    original_id: str
    product_id: str
    expires_at: datetime | None
    revoked: bool
    # Our user id, set by the app at purchase. None for a purchase made
    # before the app set it, or outside the app.
    account_token: str | None


class AppleSignatureError(Exception):
    pass


def _ts(ms: int | None) -> datetime | None:
    return datetime.fromtimestamp(ms / 1000, timezone.utc) if ms else None


def _txn(decoded) -> AppleTransaction:
    return AppleTransaction(
        original_id=decoded.originalTransactionId or "",
        product_id=decoded.productId or "",
        expires_at=_ts(decoded.expiresDate),
        revoked=decoded.revocationDate is not None,
        account_token=decoded.appAccountToken,
    )


class AppleGateway:
    """Synchronous (online certificate checks hit the network); endpoints call
    it through `run_in_threadpool`."""

    def __init__(self) -> None:
        root = _ROOT.read_bytes()
        # Production first. App Review and TestFlight buy in the sandbox
        # against the production build, so a sandbox transaction is accepted
        # too. ponytail: TestFlight testers can "subscribe" free in the
        # sandbox; those renew fast and lapse within days. Reject SANDBOX
        # here if that ever matters.
        self._verifiers = [
            SignedDataVerifier(
                [root], True, env, settings.APPLE_BUNDLE_ID, settings.APPLE_APP_ID
            )
            for env in (Environment.PRODUCTION, Environment.SANDBOX)
        ]

    def _first(self, verify):
        for verifier in self._verifiers:
            try:
                return verify(verifier)
            except VerificationException as e:
                if e.status != VerificationStatus.INVALID_ENVIRONMENT:
                    raise AppleSignatureError(e.status.name) from e
        raise AppleSignatureError("INVALID_ENVIRONMENT")

    def transaction(self, signed_transaction: str) -> AppleTransaction:
        return _txn(
            self._first(lambda v: v.verify_and_decode_signed_transaction(signed_transaction))
        )

    def notification(self, signed_payload: str) -> AppleTransaction | None:
        """The transaction a server notification is about, or None for the
        ones that carry none (TEST, summaries)."""

        def verify(v: SignedDataVerifier):
            payload = v.verify_and_decode_notification(signed_payload)
            info = payload.data.signedTransactionInfo if payload.data else None
            return v.verify_and_decode_signed_transaction(info) if info else None

        decoded = self._first(verify)
        return _txn(decoded) if decoded else None


@lru_cache
def get_apple() -> AppleGateway:
    return AppleGateway()
