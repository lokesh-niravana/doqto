"""Prepare the dev DB for the on-device batch-7 compliance walk
(doqto_app/integration_test/compliance_test.dart) and print its dart-defines.
Run with the local API up on :8010 (needs FIREBASE_PROJECT_ID):

    venv/bin/python scripts/compliance_device_prep.py

  me   = +1 650-555-0198 "Second Tester" — org ADMIN of the shared org
  peer = +1 650-555-0199 "Demo Reviewer" — also an org ADMIN of that org,
         acts over REST (approves my break-glass request, files a report,
         reads the policies as a member would)
Both belong to one ACTIVE organisation (mine if I have one, else the peer's,
else a fresh "Batch 7 Clinic"). Its policies are reset to the defaults and
its pending access requests dropped so the walk starts flat. A legacy org
group chat "Batch 7 Walk" (org_id set, both members) exists for the
allow_copy and legal-hold steps; the direct chat exists too. Redis
rate-limit / network-cache / presence keys are dropped.
"""
from __future__ import annotations

import asyncio
import os
import sys
import uuid
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
os.chdir(BACKEND)
sys.path.insert(0, str(BACKEND))

from sqlalchemy import text  # noqa: E402

from app.core.constants import ACCESS_TOKEN_TTL_SECONDS  # noqa: E402
from app.core.enums import JwtTokenType  # noqa: E402
from app.core.redis_keys import session_key  # noqa: E402
from app.core.security import create_token  # noqa: E402
from app.db.postgres import SessionLocal  # noqa: E402
from app.db.redis import get_redis  # noqa: E402

ME, PEER = "+16505550198", "+16505550199"
ORG_NAME = "Batch 7 Clinic"
GROUP_NAME = "Batch 7 Walk"


async def mint(user_id) -> str:
    token, jti = create_token(user_id, JwtTokenType.ACCESS)
    redis = await get_redis()
    await redis.setex(session_key(jti), ACCESS_TOKEN_TTL_SECONDS, "1")
    return token


async def ensure_direct(db, a, b, created_by):
    lo, hi = sorted((a, b), key=str)
    conv_id = await db.scalar(
        text("select conversation_id from direct_conversation_keys where user_lo=:lo and user_hi=:hi"),
        {"lo": lo, "hi": hi},
    )
    if conv_id is None:
        conv_id = uuid.uuid4()
        await db.execute(
            text(
                "insert into conversations (id, org_id, type, created_by, access) "
                "values (:id, null, 'direct', :by, 'open')"
            ),
            {"id": conv_id, "by": created_by},
        )
        await db.execute(
            text(
                "insert into direct_conversation_keys (conversation_id, user_lo, user_hi) "
                "values (:c, :lo, :hi)"
            ),
            {"c": conv_id, "lo": lo, "hi": hi},
        )
        for uid in (a, b):
            await db.execute(
                text("insert into conversation_members (conversation_id, user_id) values (:c, :u)"),
                {"c": conv_id, "u": uid},
            )
    return conv_id


async def ensure_connected(db, a, b):
    exists = await db.scalar(
        text("select 1 from connections where user_id=:a and connected_user_id=:b"),
        {"a": a, "b": b},
    )
    if not exists:
        pair = uuid.uuid4()
        for x, y in ((a, b), (b, a)):
            await db.execute(
                text(
                    "insert into connections (user_id, connected_user_id, pair_id) "
                    "values (:a, :b, :p)"
                ),
                {"a": x, "b": y, "p": pair},
            )


async def ensure_org(db, me_id, peer_id):
    """One active org with both as admins. Returns its id."""
    org_id = await db.scalar(
        text(
            "select o.id from organizations o join org_members m on m.org_id=o.id "
            "where m.user_id=:u order by (o.status='active') desc, o.created_at desc limit 1"
        ),
        {"u": me_id},
    )
    if org_id is None:
        org_id = await db.scalar(
            text(
                "select o.id from organizations o join org_members m on m.org_id=o.id "
                "where m.user_id=:u order by (o.status='active') desc, o.created_at desc limit 1"
            ),
            {"u": peer_id},
        )
    if org_id is None:
        org_id = uuid.uuid4()
        await db.execute(
            text(
                "insert into organizations (id, name, invite_code, status, verified_at, policies) "
                "values (:id, :name, :code, 'active', now(), '{}'::jsonb)"
            ),
            {"id": org_id, "name": ORG_NAME, "code": uuid.uuid4().hex[:9].upper()},
        )
    for uid in (me_id, peer_id):
        role = await db.scalar(
            text("select org_role from org_members where org_id=:o and user_id=:u"),
            {"o": org_id, "u": uid},
        )
        if role is None:
            await db.execute(
                text("insert into org_members (org_id, user_id, org_role) values (:o, :u, 'admin')"),
                {"o": org_id, "u": uid},
            )
        elif role != "admin":
            await db.execute(
                text("update org_members set org_role='admin' where org_id=:o and user_id=:u"),
                {"o": org_id, "u": uid},
            )
    # Flat start: active, default policies, no pending break-glass rows.
    await db.execute(
        text(
            "update organizations set status='active', verified_at=coalesce(verified_at, now()), "
            "policies='{}'::jsonb where id=:o"
        ),
        {"o": org_id},
    )
    await db.execute(text("delete from access_requests where org_id=:o"), {"o": org_id})
    return org_id


async def ensure_org_group(db, org_id, owner_id, member_id):
    """A legacy org group chat (conversations.org_id set) with both members."""
    conv_id = await db.scalar(
        text("select id from conversations where org_id=:o and type='group' and name=:n limit 1"),
        {"o": org_id, "n": GROUP_NAME},
    )
    if conv_id is None:
        conv_id = uuid.uuid4()
        await db.execute(
            text(
                "insert into conversations (id, org_id, type, name, created_by, access) "
                "values (:id, :o, 'group', :name, :by, 'open')"
            ),
            {"id": conv_id, "o": org_id, "name": GROUP_NAME, "by": owner_id},
        )
    for uid in (owner_id, member_id):
        member = await db.scalar(
            text("select 1 from conversation_members where conversation_id=:c and user_id=:u"),
            {"c": conv_id, "u": uid},
        )
        if not member:
            await db.execute(
                text("insert into conversation_members (conversation_id, user_id) values (:c, :u)"),
                {"c": conv_id, "u": uid},
            )
    return conv_id


async def main():
    async with SessionLocal() as db:
        me_id, peer_id = [
            await db.scalar(text("select id from users where phone=:p"), {"p": p})
            for p in (ME, PEER)
        ]
        assert me_id and peer_id, "sign in once with both Firebase test numbers first"
        await db.execute(
            text("delete from blocks where (blocker_id=:a and blocked_id=:b) or (blocker_id=:b and blocked_id=:a)"),
            {"a": me_id, "b": peer_id},
        )
        await db.execute(text("delete from mutes where user_id in (:a, :b)"), {"a": me_id, "b": peer_id})
        await ensure_connected(db, me_id, peer_id)
        org_id = await ensure_org(db, me_id, peer_id)
        # Every other org of mine goes inactive-neutral: the app picks the newest
        # ACTIVE org, so make sure ours is the only active one for me.
        await db.execute(
            text(
                "update organizations set status='pending' where id<>:o and status='active' and id in "
                "(select org_id from org_members where user_id=:u)"
            ),
            {"o": org_id, "u": me_id},
        )
        conv_id = await ensure_direct(db, me_id, peer_id, me_id)
        org_conv = await ensure_org_group(db, org_id, me_id, peer_id)
        await db.execute(
            text("update conversations set pinned_message_id=null, pinned_until=null, pinned_by=null where id in (:a, :b)"),
            {"a": conv_id, "b": org_conv},
        )
        await db.execute(text("delete from conversation_prefs where user_id=:u"), {"u": me_id})
        await db.execute(
            text("delete from scheduled_messages where sender_id=:u and status<>'sent'"), {"u": me_id}
        )
        await db.commit()
    redis = await get_redis()
    for pattern in ("rate_limit:*", "net:*", "presence:*"):
        for key in await redis.keys(pattern):
            await redis.delete(key)
    print(
        f"--dart-define=ME_ID={me_id} --dart-define=PEER_ID={peer_id} "
        f"--dart-define=ORG_ID={org_id} --dart-define=CONV_ID={conv_id} "
        f"--dart-define=ORG_CONV_ID={org_conv} "
        f"--dart-define=PEER_TOKEN={await mint(peer_id)}"
    )


asyncio.run(main())
