"""Prepare the dev DB for the on-device conversation-preferences walk
(doqto_app/integration_test/conversation_prefs_test.dart) and print its
dart-defines. Run with the local API up on :8010 (needs FIREBASE_PROJECT_ID):

    venv/bin/python scripts/conversation_prefs_device_prep.py

  me   = +1 650-555-0198 "Second Tester" (org forced ACTIVE)
  peer = +1 650-555-0199 "Demo Reviewer", acts over REST (sends messages)
The two are connected, no block / mute stands between them, every
conversation_prefs row of mine is reset (nothing pinned / archived / muted),
and a direct conversation exists so the thread opens. A second direct chat
with a third doctor ("Dr Prefs Filler") gives the list something to sort
against; its messages are left as they are.
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
FILLER_PHONE, FILLER_NPI = "+16505550911", "3000000911"


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
        await db.execute(text("delete from mutes where user_id in (:a, :b)"), {"a": me_id, "b": peer_id})
        # A third doctor so the list has two direct chats to order.
        filler_id = await db.scalar(text("select id from users where phone=:p"), {"p": FILLER_PHONE})
        if filler_id is None:
            filler_id = uuid.uuid4()
            await db.execute(
                text(
                    "insert into users (id, phone, full_name, npi_number, role) "
                    "values (:id, :phone, 'Dr Prefs Filler', :npi, 'doctor')"
                ),
                {"id": filler_id, "phone": FILLER_PHONE, "npi": FILLER_NPI},
            )
        await ensure_connected(db, me_id, peer_id)
        await ensure_connected(db, me_id, filler_id)
        conv_id = await ensure_direct(db, me_id, peer_id, me_id)
        filler_conv = await ensure_direct(db, me_id, filler_id, me_id)
        # Everything of mine back to defaults: nothing pinned / archived /
        # muted / cleared, so the walk starts from a clean list.
        await db.execute(text("delete from conversation_prefs where user_id=:u"), {"u": me_id})
        await db.commit()
    redis = await get_redis()
    for pattern in ("rate_limit:*", "net:*", "presence:*"):
        for key in await redis.keys(pattern):
            await redis.delete(key)
    print(
        f"--dart-define=ME_ID={me_id} --dart-define=PEER_ID={peer_id} "
        f"--dart-define=CONV_ID={conv_id} --dart-define=FILLER_CONV_ID={filler_conv} "
        f"--dart-define=PEER_TOKEN={await mint(peer_id)}"
    )


asyncio.run(main())
