"""Audit trail (batch 7: durable + tamper-evident).

Why a separate session
----------------------
`log()` opens its own short-lived `SessionLocal()` and commits before
returning, instead of adding the row to the caller's transaction. A request
that later fails or rolls back therefore still leaves its attempt in the
trail (HIPAA §164.312(b)). The `db` parameter is kept for call-site
compatibility and for tests that run inside an open transaction — it is
not used for the write. Audit rows reference `users.id` without a foreign
key, because the row may be committed before the user's own transaction is.

Hash chain
----------
Rows are numbered densely (`seq`) under a transaction-scoped Postgres
advisory lock, so there is exactly one chain. Each row stores
`prev_hash` (the previous row's `hash`, 64 zeros for the first row) and
`hash = sha256(prev_hash + canonical_json(row))` where the canonical form is
`canonical_payload()` below — the row minus the two hash fields, keys
sorted, no whitespace, UUIDs and timestamps as strings.
`scripts/verify_audit_chain.py` walks the chain and reports the first break.
"""
from __future__ import annotations

import hashlib
import ipaddress
import json
import logging
import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import Request
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.enums import AuditAction
from app.db.postgres import SessionLocal
from app.models import AuditLog

log = logging.getLogger("doqto.audit")

GENESIS_HASH = "0" * 64
# Any constant; pg_advisory_xact_lock serialises chain appends.
_CHAIN_LOCK_ID = 7_201_001


def request_meta(request: Request) -> tuple[str | None, str | None]:
    """(ip, user_agent) for audit rows. IP honours the first X-Forwarded-For hop."""
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        ip = fwd.split(",")[0].strip() or None
    else:
        ip = request.client.host if request.client else None
    return ip, request.headers.get("user-agent")


def canonical_payload(row: AuditLog | dict[str, Any]) -> str:
    """The exact bytes that are hashed. Shared with the verification script."""
    if isinstance(row, AuditLog):
        data = {
            "id": row.id,
            "seq": row.seq,
            "user_id": row.user_id,
            "action": row.action,
            "resource_type": row.resource_type,
            "resource_id": row.resource_id,
            "ip_address": row.ip_address,
            "user_agent": row.user_agent,
            "metadata": row.meta,
            "created_at": row.created_at,
        }
    else:
        data = dict(row)

    def _norm(v: Any) -> Any:
        if isinstance(v, uuid.UUID):
            return str(v)
        if isinstance(v, datetime):
            return v.astimezone(timezone.utc).isoformat(timespec="microseconds")
        if isinstance(v, (ipaddress.IPv4Address, ipaddress.IPv6Address)):
            return str(v)
        return v

    return json.dumps(
        {k: _norm(v) for k, v in data.items()}, sort_keys=True, separators=(",", ":")
    )


def chain_hash(prev_hash: str, payload: str) -> str:
    return hashlib.sha256((prev_hash + payload).encode()).hexdigest()


class AuditService:
    @staticmethod
    async def log(
        db: AsyncSession | None,
        *,
        user_id: uuid.UUID | None,
        action: AuditAction,
        resource_type: str | None = None,
        resource_id: uuid.UUID | None = None,
        ip_address: str | None = None,
        user_agent: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        """Append one row in its own committed transaction. `db` is unused
        (see module docstring) but kept so call sites read the same."""
        entry = AuditLog(
            id=uuid.uuid4(),
            user_id=user_id,
            action=action.value,
            resource_type=resource_type,
            resource_id=resource_id,
            ip_address=ip_address,
            user_agent=user_agent,
            meta=metadata,
            created_at=datetime.now(tz=timezone.utc),
        )
        async with SessionLocal() as session:
            async with session.begin():
                await session.execute(
                    text("SELECT pg_advisory_xact_lock(:k)"), {"k": _CHAIN_LOCK_ID}
                )
                head = (
                    await session.execute(
                        select(AuditLog.seq, AuditLog.hash)
                        .where(AuditLog.seq.is_not(None))
                        .order_by(AuditLog.seq.desc())
                        .limit(1)
                    )
                ).first()
                entry.seq = (head.seq + 1) if head is not None else 1
                entry.prev_hash = (head.hash or GENESIS_HASH) if head is not None else GENESIS_HASH
                entry.hash = chain_hash(entry.prev_hash, canonical_payload(entry))
                session.add(entry)

    @staticmethod
    async def log_request(
        request: Request,
        *,
        user_id: uuid.UUID | None,
        action: AuditAction,
        db: AsyncSession | None = None,
        resource_type: str | None = None,
        resource_id: uuid.UUID | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        """Like log(), but populates ip_address/user_agent from the request."""
        ip, user_agent = request_meta(request)
        await AuditService.log(
            db,
            user_id=user_id,
            action=action,
            resource_type=resource_type,
            resource_id=resource_id,
            ip_address=ip,
            user_agent=user_agent,
            metadata=metadata,
        )

    @staticmethod
    async def verify_chain(db: AsyncSession, *, batch: int = 1000) -> tuple[int, int | None]:
        """Walk the chain in seq order. Returns (rows checked, first bad seq or
        None). Rows numbered by migration 0035 before hashing existed carry
        `hash IS NULL`; they are allowed only as a prefix of the chain and are
        not counted as checked. Used by scripts/verify_audit_chain.py."""
        prev = GENESIS_HASH
        expected_seq = 1
        checked = 0
        last_seq = 0
        in_prefix = True
        while True:
            rows = (
                await db.scalars(
                    select(AuditLog)
                    .where(AuditLog.seq > last_seq)
                    .order_by(AuditLog.seq.asc())
                    .limit(batch)
                )
            ).all()
            if not rows:
                return checked, None
            for row in rows:
                if row.seq != expected_seq:
                    return checked, row.seq
                if row.hash is None:
                    if not in_prefix:
                        return checked, row.seq
                    expected_seq += 1
                    last_seq = row.seq
                    continue
                in_prefix = False
                if row.prev_hash != prev:
                    return checked, row.seq
                if row.hash != chain_hash(prev, canonical_payload(row)):
                    return checked, row.seq
                prev = row.hash
                expected_seq += 1
                checked += 1
                last_seq = row.seq
