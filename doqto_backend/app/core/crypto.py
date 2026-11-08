"""Envelope encryption for stored PHI (batch 7).

Layout
------
* A **data key** (AES-256) per scope — one per organisation (`org:<uuid>`)
  and one shared `network` key for conversations with no org. Rows carry a
  `key_version` that names the `data_keys` row used to encrypt them.
* Every data key is stored **wrapped** by a master key: AWS KMS when
  `AWS_KMS_KEY_ID` is set (`kms:Encrypt` / `kms:Decrypt`, encryption
  context `{"scope": ...}`), otherwise the static `MESSAGE_ENCRYPTION_KEY`
  acts as the wrapping key, so local/test/CI keep working with no AWS at all.
* `key_version = 0` is the **legacy** format: nonce + ciphertext under the
  static key directly (`app.core.security.encrypt_message`). Legacy rows keep
  decrypting; any write re-encrypts the whole row under the scope's active
  key (lazy migration). `scripts/rotate_keys.py` retires keys and can
  re-encrypt everything in the background.

Blob format for version ≥ 1 is unchanged on purpose (12-byte nonce +
AES-GCM ciphertext) — the version lives in the row, never in the blob, so a
blob alone tells an attacker nothing about which key protects it.

Caching
-------
Unwrapped data keys live in a process-wide dict. Decrypt sites are sync
(`MessageService.to_out`), so a cache miss — a version first seen in this
process, created by another replica — is loaded by a helper thread running
its own event loop against a throw-away engine. That blocks the caller for
one SELECT + one unwrap, at most once per key version per process.
"""

from __future__ import annotations

import asyncio
import logging
import os
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Protocol

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.security import _encryption_key, decrypt_message, encrypt_message

log = logging.getLogger("doqto.crypto")

LEGACY_KEY_VERSION = 0
NETWORK_SCOPE = "network"
WRAPPER_STATIC = "static"
WRAPPER_KMS = "kms"
# How long a replica keeps using a cached "active version" per scope before
# asking the DB again (bounds how long a rotation takes to reach every replica).
ACTIVE_VERSION_TTL_SEC = 60
_NONCE_LEN = 12


class CryptoError(Exception):
    pass


def scope_for(org_id: uuid.UUID | None) -> str:
    return f"org:{org_id}" if org_id is not None else NETWORK_SCOPE


# ---------------------------------------------------------------- wrappers --


class KeyWrapper(Protocol):
    name: str

    def wrap(self, *, plain_key: bytes, scope: str) -> bytes: ...

    def unwrap(self, *, wrapped: bytes, scope: str) -> bytes: ...


class StaticKeyWrapper:
    """Wraps data keys with the static MESSAGE_ENCRYPTION_KEY (AES-GCM, the
    scope as associated data). The fallback when no KMS is configured."""

    name = WRAPPER_STATIC

    def wrap(self, *, plain_key: bytes, scope: str) -> bytes:
        nonce = os.urandom(_NONCE_LEN)
        return nonce + AESGCM(_encryption_key()).encrypt(nonce, plain_key, scope.encode())

    def unwrap(self, *, wrapped: bytes, scope: str) -> bytes:
        nonce, ct = wrapped[:_NONCE_LEN], wrapped[_NONCE_LEN:]
        return AESGCM(_encryption_key()).decrypt(nonce, ct, scope.encode())


class KmsKeyWrapper:
    """Wraps data keys with an AWS KMS customer master key. boto3 is sync; the
    calls happen rarely (key creation, first use of a version per process)."""

    name = WRAPPER_KMS

    def __init__(self, key_id: str, client=None) -> None:
        self.key_id = key_id
        self._client = client

    def _kms(self):
        if self._client is None:
            import boto3

            self._client = boto3.client(
                "kms",
                region_name=settings.AWS_REGION,
                aws_access_key_id=settings.AWS_ACCESS_KEY_ID or None,
                aws_secret_access_key=settings.AWS_SECRET_ACCESS_KEY or None,
            )
        return self._client

    def wrap(self, *, plain_key: bytes, scope: str) -> bytes:
        out = self._kms().encrypt(
            KeyId=self.key_id, Plaintext=plain_key, EncryptionContext={"scope": scope}
        )
        return out["CiphertextBlob"]

    def unwrap(self, *, wrapped: bytes, scope: str) -> bytes:
        out = self._kms().decrypt(CiphertextBlob=wrapped, EncryptionContext={"scope": scope})
        return out["Plaintext"]


_wrapper: KeyWrapper | None = None


def get_wrapper() -> KeyWrapper:
    global _wrapper
    if _wrapper is None:
        _wrapper = (
            KmsKeyWrapper(settings.AWS_KMS_KEY_ID) if settings.AWS_KMS_KEY_ID else StaticKeyWrapper()
        )
    return _wrapper


def set_wrapper(wrapper: KeyWrapper | None) -> None:
    """Tests inject a fake KMS here; None restores the settings-driven choice."""
    global _wrapper
    _wrapper = wrapper
    reset_cache()


# ------------------------------------------------------------------- cache --


@dataclass(frozen=True)
class LoadedKey:
    version: int
    scope: str
    key: bytes


_keys: dict[int, LoadedKey] = {}
_active: dict[str, tuple[int, float]] = {}  # scope -> (version, loaded_at)
_lock = threading.Lock()
_loader = ThreadPoolExecutor(max_workers=1, thread_name_prefix="doqto-keys")


def reset_cache() -> None:
    with _lock:
        _keys.clear()
        _active.clear()


def _remember(row) -> LoadedKey:
    loaded = LoadedKey(
        version=row.version,
        scope=row.scope,
        key=get_wrapper().unwrap(wrapped=row.wrapped_key, scope=row.scope),
    )
    with _lock:
        _keys[row.version] = loaded
    return loaded


async def _load_version(db: AsyncSession, version: int) -> LoadedKey:
    from app.models import DataKey

    row = await db.get(DataKey, version)
    if row is None:
        raise CryptoError(f"unknown key_version {version}")
    return _remember(row)


def _load_version_blocking(version: int) -> LoadedKey:
    """Cache miss from a sync call site: fetch + unwrap on a helper thread with
    its own loop and a one-off NullPool engine, block until done."""

    async def _run() -> LoadedKey:
        from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
        from sqlalchemy.pool import NullPool

        engine = create_async_engine(settings.DATABASE_URL, poolclass=NullPool)
        try:
            async with async_sessionmaker(engine, class_=AsyncSession)() as db:
                return await _load_version(db, version)
        finally:
            await engine.dispose()

    return _loader.submit(lambda: asyncio.run(_run())).result()


def key_for(version: int) -> bytes:
    with _lock:
        hit = _keys.get(version)
    if hit is None:
        hit = _load_version_blocking(version)
    return hit.key


# -------------------------------------------------------------- key rows --


async def ensure_active_key(db: AsyncSession, scope: str) -> int:
    """The active key version for `scope`, creating the first key on demand.
    Safe under concurrency: the partial unique index on (scope) WHERE
    retired_at IS NULL turns a lost race into a re-read inside a savepoint."""
    from app.models import DataKey

    now = time.monotonic()
    with _lock:
        cached = _active.get(scope)
    if cached is not None and now - cached[1] < ACTIVE_VERSION_TTL_SEC:
        return cached[0]

    row = await db.scalar(
        select(DataKey).where(DataKey.scope == scope, DataKey.retired_at.is_(None))
    )
    if row is None:
        row = await create_key(db, scope)
    _remember(row)
    with _lock:
        _active[scope] = (row.version, now)
    return row.version


async def create_key(db: AsyncSession, scope: str, *, retire_current: bool = False):
    """Mint a fresh data key for `scope` (optionally retiring the current one)
    and return the row. Rotation uses retire_current=True."""
    from datetime import datetime, timezone

    from app.models import DataKey

    wrapper = get_wrapper()
    plain = AESGCM.generate_key(bit_length=256)
    if retire_current:
        current = await db.scalar(
            select(DataKey).where(DataKey.scope == scope, DataKey.retired_at.is_(None))
        )
        if current is not None:
            current.retired_at = datetime.now(tz=timezone.utc)
            await db.flush()
    row = DataKey(
        scope=scope,
        wrapped_key=wrapper.wrap(plain_key=plain, scope=scope),
        wrapper=wrapper.name,
        kms_key_id=getattr(wrapper, "key_id", None),
    )
    try:
        async with db.begin_nested():
            db.add(row)
            await db.flush()
    except IntegrityError:
        # Another replica created this scope's key first — use theirs.
        row = await db.scalar(
            select(DataKey).where(DataKey.scope == scope, DataKey.retired_at.is_(None))
        )
        if row is None:
            raise CryptoError("key_create_race") from None
    with _lock:
        _active.pop(scope, None)
    return row


async def active_version(db: AsyncSession, org_id: uuid.UUID | None) -> int:
    """Shorthand used by every write path."""
    return await ensure_active_key(db, scope_for(org_id))


# ------------------------------------------------------- encrypt / decrypt --


def encrypt(plaintext: str, version: int) -> bytes:
    if version == LEGACY_KEY_VERSION:
        return encrypt_message(plaintext)
    nonce = os.urandom(_NONCE_LEN)
    return nonce + AESGCM(key_for(version)).encrypt(nonce, plaintext.encode(), None)


def decrypt(blob: bytes, version: int) -> str:
    if version == LEGACY_KEY_VERSION:
        return decrypt_message(blob)
    nonce, ct = blob[:_NONCE_LEN], blob[_NONCE_LEN:]
    return AESGCM(key_for(version)).decrypt(nonce, ct, None).decode()


def encrypt_opt(plaintext: str | None, version: int) -> bytes | None:
    return encrypt(plaintext, version) if plaintext else None


def decrypt_opt(blob: bytes | None, version: int) -> str | None:
    return decrypt(blob, version) if blob else None


def reencrypt(blob: bytes | None, from_version: int, to_version: int) -> bytes | None:
    if blob is None or from_version == to_version:
        return blob
    return encrypt(decrypt(blob, from_version), to_version)


def describe() -> dict:
    """For ops / tests: which wrapper is live and what is cached."""
    w = get_wrapper()
    return {
        "wrapper": w.name,
        "kms_key_id": getattr(w, "key_id", None),
        "cached_versions": sorted(_keys),
    }
