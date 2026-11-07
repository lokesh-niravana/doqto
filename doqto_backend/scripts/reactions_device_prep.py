"""Prepare the dev DB for the on-device reactions walk
(doqto_app/integration_test/reactions_test.dart) and print its dart-defines.
Run with the local API up on :8010 (needs FIREBASE_PROJECT_ID):

    venv/bin/python scripts/reactions_device_prep.py

  me   = +1 650-555-0198 "Second Tester" (org forced ACTIVE)
  peer = +1 650-555-0199 "Demo Reviewer", acts over REST
The two are connected (so the DM is open) and no block stands between them.
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
        await db.commit()
    redis = await get_redis()
    for key in await redis.keys("net:*"):
        await redis.delete(key)
    print(
        f"--dart-define=ME_ID={me_id} --dart-define=PEER_ID={peer_id} "
        f"--dart-define=PEER_TOKEN={await mint(peer_id)}"
    )


asyncio.run(main())
