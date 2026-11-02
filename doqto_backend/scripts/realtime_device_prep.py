"""Reset the two Firebase test users in the dev DB for the on-device realtime
walk (doqto_app/integration_test/realtime_test.dart) and print the dart-defines
it needs. Run with the local API up on :8010 (needs FIREBASE_PROJECT_ID):

    venv/bin/python scripts/realtime_device_prep.py

  me   = +1 650-555-0198 "Second Tester" (org Mayo Clinic, forced back to PENDING)
  peer = +1 650-555-0199 "Demo Reviewer" (active org), acts over REST
  staff = fresh super-admin, verifies Mayo Clinic over REST
"""
from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
os.chdir(BACKEND)
sys.path.insert(0, str(BACKEND))

from sqlalchemy import text  # noqa: E402

from app.core.constants import ACCESS_TOKEN_TTL_SECONDS  # noqa: E402
from app.core.enums import JwtTokenType, UserRole  # noqa: E402
from app.core.redis_keys import session_key  # noqa: E402
from app.core.security import create_token  # noqa: E402
from app.db.postgres import SessionLocal  # noqa: E402
from app.db.redis import get_redis  # noqa: E402
from tests import helpers  # noqa: E402

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
        org_id = await db.scalar(
            text("select org_id from org_members where user_id=:u"), {"u": me_id}
        )
        await db.execute(
            text("update organizations set status='pending', verified_at=null where id=:o"),
            {"o": org_id},
        )
        # Not connected, no pending invitations (an old DM may stay; it is reused).
        await db.execute(
            text(
                "delete from connections where (user_id=:a and connected_user_id=:b) "
                "or (user_id=:b and connected_user_id=:a)"
            ),
            {"a": me_id, "b": peer_id},
        )
        await db.execute(
            text(
                "delete from connection_invitations where "
                "(sender_id=:a and recipient_id=:b) or (sender_id=:b and recipient_id=:a)"
            ),
            {"a": me_id, "b": peer_id},
        )
        # The last walk ends with a removal, which starts a 30-day re-invite
        # cooldown; clear it so the peer may invite again.
        await db.execute(
            text("delete from connection_removals where (user_a=:a and user_b=:b) or (user_a=:b and user_b=:a)"),
            {"a": me_id, "b": peer_id},
        )
        staff = await helpers.create_user(db, full_name="Device Staff")
        staff.role = UserRole.SUPER_ADMIN
        await db.commit()
        staff_id = staff.id
    redis = await get_redis()
    for key in await redis.keys("net:*"):
        await redis.delete(key)
    peer_tok, staff_tok = await mint(peer_id), await mint(staff_id)
    print(
        f"--dart-define=ME_ID={me_id} --dart-define=PEER_ID={peer_id} "
        f"--dart-define=ORG_ID={org_id} --dart-define=PEER_TOKEN={peer_tok} "
        f"--dart-define=STAFF_TOKEN={staff_tok}"
    )


asyncio.run(main())
