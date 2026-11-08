"""Prepare the dev DB for the on-device groups walk
(doqto_app/integration_test/groups_test.dart) and print its dart-defines.
Run with the local API up on :8010 (needs FIREBASE_PROJECT_ID):

    venv/bin/python scripts/groups_device_prep.py

  me   = +1 650-555-0198 "Second Tester" (org forced ACTIVE)
  peer = +1 650-555-0199 "Demo Reviewer", acts over REST (creates the group,
         invites me, promotes me, reads my message)
The two are connected, no block stands between them, and any group the peer
owns from an earlier run is deleted so the tab starts without leftovers.
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


async def mint(user_id) -> str:
    token, jti = create_token(user_id, JwtTokenType.ACCESS)
    redis = await get_redis()
    await redis.setex(session_key(jti), ACCESS_TOKEN_TTL_SECONDS, "1")
    return token


async def main():
    async with SessionLocal() as db:
        me_id, peer_id = [
            await db.scalar(text("select id from users where phone=:p"), {"p": p})
            for p in (ME, PEER)
        ]
        assert me_id and peer_id, "sign in once with both Firebase test numbers first"
        await db.execute(
            text(
                "update organizations set status='active', verified_at=now() where id in "
                "(select org_id from org_members where user_id in (:a, :b))"
            ),
            {"a": me_id, "b": peer_id},
        )
        await db.execute(
            text("delete from blocks where (blocker_id=:a and blocked_id=:b) or (blocker_id=:b and blocked_id=:a)"),
            {"a": me_id, "b": peer_id},
        )
        exists = await db.scalar(
            text("select 1 from connections where user_id=:a and connected_user_id=:b"),
            {"a": me_id, "b": peer_id},
        )
        if not exists:
            pair = uuid.uuid4()
            for a, b in ((me_id, peer_id), (peer_id, me_id)):
                await db.execute(
                    text(
                        "insert into connections (user_id, connected_user_id, pair_id) "
                        "values (:a, :b, :p)"
                    ),
                    {"a": a, "b": b, "p": pair},
                )
        # Leftover groups from earlier walks (either of us owns them): drop the
        # group row and its conversation so the Groups tab starts clean.
        stale = [
            r[0]
            for r in (
                await db.execute(
                    text(
                        "select conversation_id from groups where owner_id in (:a, :b) "
                        "and name like 'Walk %'"
                    ),
                    {"a": me_id, "b": peer_id},
                )
            ).all()
        ]
        for conv_id in stale:
            for table in (
                "message_reactions where message_id in (select id from messages where conversation_id=:c)",
                "message_edits where message_id in (select id from messages where conversation_id=:c)",
                "message_hides where message_id in (select id from messages where conversation_id=:c)",
                "message_receipts where message_id in (select id from messages where conversation_id=:c)",
                "scheduled_messages where conversation_id=:c",
                "messages where conversation_id=:c",
                "conversation_members where conversation_id=:c",
                "groups where conversation_id=:c",
                "conversations where id=:c",
            ):
                await db.execute(text(f"delete from {table}"), {"c": conv_id})
        await db.commit()
    redis = await get_redis()
    for key in await redis.keys("rate_limit:*"):
        await redis.delete(key)
    for key in await redis.keys("net:*"):
        await redis.delete(key)
    print(
        f"--dart-define=ME_ID={me_id} --dart-define=PEER_ID={peer_id} "
        f"--dart-define=PEER_TOKEN={await mint(peer_id)}"
    )


asyncio.run(main())
