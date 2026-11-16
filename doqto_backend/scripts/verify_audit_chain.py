#!/usr/bin/env python3
"""Walk the audit_logs hash chain and report the first break (batch 7).

    cd doqto_backend && venv/bin/python scripts/verify_audit_chain.py

Exit 0 when every hashed row's `prev_hash` matches its predecessor and its
`hash` recomputes from the canonical payload; exit 1 on the first mismatch
(printing the offending `seq`); exit 2 on a gap in `seq`. Rows numbered by
migration 0035 before hashing existed (hash NULL) are accepted only as a
prefix of the chain. Uses the DATABASE_URL from the environment / .env —
read-only. Run it from cron and page on non-zero.
"""
from __future__ import annotations

import asyncio
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app.db.postgres import SessionLocal  # noqa: E402
from app.services.audit_service import AuditService  # noqa: E402


async def main() -> int:
    async with SessionLocal() as db:
        checked, bad = await AuditService.verify_chain(db)
    if bad is None:
        print(f"audit chain OK — {checked} hashed rows verified")
        return 0
    print(f"audit chain BROKEN at seq={bad} after {checked} good rows", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
