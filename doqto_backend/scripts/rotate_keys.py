#!/usr/bin/env python3
"""Data-key rotation and re-encryption (batch 7 envelope encryption).

    venv/bin/python scripts/rotate_keys.py status
    venv/bin/python scripts/rotate_keys.py rotate [--scope network|org:<uuid>|all]
    venv/bin/python scripts/rotate_keys.py rewrap [--scope ...] [--batch 500]
    venv/bin/python scripts/rotate_keys.py to-legacy [--scope ...]   # before a downgrade

* `rotate` mints a new active data key per scope (retiring the current one)
  and audits KEY_ROTATED. New writes pick it up within
  ACTIVE_VERSION_TTL_SEC on every replica; old rows keep decrypting under
  their retired version.
* `rewrap` re-encrypts every row (messages, message_edits,
  scheduled_messages, poll_options) whose key_version is not the scope's
  active one — including legacy version-0 rows — in batches, committing per
  batch so it can be stopped and resumed. Run it after `rotate`, or on its
  own to finish the lazy migration off the static key.
* `to-legacy` is the escape hatch for `alembic downgrade`: it puts rows back
  under version 0 (the static key) so pre-0035 code can read them.

Scopes default to `all` (the shared `network` key plus one per org). The
master-key choice (KMS vs static) follows AWS_KMS_KEY_ID exactly like the
API; to move from the static wrapper to KMS, set the variable and run
`rotate` — new keys are KMS-wrapped, old ones stay readable because each
data_keys row remembers which wrapper sealed it. (Re-wrapping existing keys
under KMS is not needed for correctness: retire them with `rotate` and
`rewrap` the rows.)
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from sqlalchemy import func, select  # noqa: E402

from app.core import crypto  # noqa: E402
from app.core.enums import AuditAction  # noqa: E402
from app.db.postgres import SessionLocal  # noqa: E402
from app.models import (  # noqa: E402
    Conversation,
    DataKey,
    Message,
    MessageEdit,
    Organization,
    PollOption,
    ScheduledMessage,
)
from app.services.audit_service import AuditService  # noqa: E402


async def all_scopes(db) -> list[str]:
    orgs = (await db.scalars(select(Organization.id))).all()
    return [crypto.NETWORK_SCOPE, *(crypto.scope_for(o) for o in orgs)]


def org_of_scope(scope: str) -> uuid.UUID | None:
    return None if scope == crypto.NETWORK_SCOPE else uuid.UUID(scope.split(":", 1)[1])


async def cmd_status(db, scopes: list[str]) -> None:
    for scope in scopes:
        rows = (
            await db.scalars(select(DataKey).where(DataKey.scope == scope).order_by(DataKey.version))
        ).all()
        active = next((r.version for r in rows if r.retired_at is None), None)
        print(f"{scope}: active={active} versions={[r.version for r in rows]} "
              f"wrappers={sorted({r.wrapper for r in rows})}")
    legacy = await db.scalar(select(func.count()).select_from(Message).where(Message.key_version == 0))
    print(f"messages still on legacy key_version 0: {legacy}")
    print(f"wrapper in use for new keys: {crypto.describe()['wrapper']}")


async def cmd_rotate(db, scopes: list[str]) -> None:
    for scope in scopes:
        row = await crypto.create_key(db, scope, retire_current=True)
        await db.commit()
        await AuditService.log(
            db,
            user_id=None,
            action=AuditAction.KEY_ROTATED,
            resource_type="data_key",
            metadata={"scope": scope, "version": row.version, "wrapper": row.wrapper},
        )
        print(f"{scope}: new active version {row.version} ({row.wrapper})")


async def _rewrap_scope(db, scope: str, target: int, batch: int) -> int:
    """Move every row of `scope` to `target`. Returns rows rewritten."""
    org_id = org_of_scope(scope)
    conv_ids = select(Conversation.id).where(
        Conversation.org_id == org_id if org_id is not None else Conversation.org_id.is_(None)
    )
    total = 0
    while True:
        msgs = (
            await db.scalars(
                select(Message)
                .where(Message.conversation_id.in_(conv_ids), Message.key_version != target)
                .limit(batch)
            )
        ).all()
        if not msgs:
            break
        for m in msgs:
            old = m.key_version
            m.content_encrypted = crypto.reencrypt(m.content_encrypted, old, target)
            m.transcript_encrypted = crypto.reencrypt(m.transcript_encrypted, old, target)
            m.caption_encrypted = crypto.reencrypt(m.caption_encrypted, old, target)
            m.key_version = target
            edits = (await db.scalars(select(MessageEdit).where(MessageEdit.message_id == m.id))).all()
            for e in edits:
                e.content_encrypted = crypto.reencrypt(e.content_encrypted, e.key_version, target)
                e.key_version = target
            opts = (await db.scalars(select(PollOption).where(PollOption.message_id == m.id))).all()
            for o in opts:
                o.text_encrypted = crypto.reencrypt(o.text_encrypted, o.key_version, target)
                o.key_version = target
        await db.commit()
        total += len(msgs)
        print(f"  {scope}: {total} messages rewrapped…")
    sched = (
        await db.scalars(
            select(ScheduledMessage).where(
                ScheduledMessage.conversation_id.in_(conv_ids), ScheduledMessage.key_version != target
            )
        )
    ).all()
    for s in sched:
        s.content_encrypted = crypto.reencrypt(s.content_encrypted, s.key_version, target)
        s.key_version = target
    await db.commit()
    return total + len(sched)


async def cmd_rewrap(db, scopes: list[str], batch: int) -> None:
    for scope in scopes:
        target = await crypto.ensure_active_key(db, scope)
        await db.commit()
        n = await _rewrap_scope(db, scope, target, batch)
        print(f"{scope}: {n} rows now on version {target}")


async def cmd_to_legacy(db, scopes: list[str], batch: int) -> None:
    for scope in scopes:
        n = await _rewrap_scope(db, scope, crypto.LEGACY_KEY_VERSION, batch)
        print(f"{scope}: {n} rows back on the static key (version 0)")


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["status", "rotate", "rewrap", "to-legacy"])
    ap.add_argument("--scope", default="all", help="all | network | org:<uuid>")
    ap.add_argument("--batch", type=int, default=500)
    args = ap.parse_args()
    async with SessionLocal() as db:
        scopes = await all_scopes(db) if args.scope == "all" else [args.scope]
        if args.command == "status":
            await cmd_status(db, scopes)
        elif args.command == "rotate":
            await cmd_rotate(db, scopes)
        elif args.command == "rewrap":
            await cmd_rewrap(db, scopes, args.batch)
        else:
            await cmd_to_legacy(db, scopes, args.batch)
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
