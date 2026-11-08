"""Prepare the dev DB for the on-device settings walk
(doqto_app/integration_test/settings_test.dart) and print its dart-defines.
Run with the local API up on :8011 against the doqto_b4 database and Redis
db 3 — the same env vars as the server:

    URL=$(grep "^DATABASE_URL" .env | sed 's#/[a-z_]*$#/doqto_b4#')
    ENVIRONMENT=local FIREBASE_PROJECT_ID=doqto-90684 \
      DATABASE_URL="${URL#DATABASE_URL=}" REDIS_URL=redis://:doqto-dev@localhost:6379/3 \
      venv/bin/python scripts/settings_device_prep.py

  me   = +1 650-555-0198 "Second Tester" (org forced ACTIVE)
  peer = +1 650-555-0199 "Demo Reviewer", acts over REST with PEER_TOKEN
The two are connected, no block stands between them, a direct conversation
exists, my notification settings / PIN / status / sessions are reset, and a
second "iPad" session row is minted for ME (ME_OTHER_TOKEN) so the
linked-devices walk has something to revoke.
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


async def mint(user_id) -> tuple[str, str]:
    token, jti = create_token(user_id, JwtTokenType.ACCESS)
    redis = await get_redis()
    await redis.setex(session_key(jti), ACCESS_TOKEN_TTL_SECONDS, "1")
    return token, jti


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
        # Batch 6 rows back to the defaults.
        await db.execute(text("delete from user_notification_settings where user_id in (:a, :b)"), {"a": me_id, "b": peer_id})
        await db.execute(
            text(
                "update users set pin_hash=null, pin_reset_at=null, status_text=null, "
                "status_expires_at=null where id in (:a, :b)"
            ),
            {"a": me_id, "b": peer_id},
        )
        await db.execute(text("delete from sessions where user_id in (:a, :b)"), {"a": me_id, "b": peer_id})
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
        lo, hi = sorted((me_id, peer_id), key=str)
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
                {"id": conv_id, "by": me_id},
            )
            await db.execute(
                text(
                    "insert into direct_conversation_keys (conversation_id, user_lo, user_hi) "
                    "values (:c, :lo, :hi)"
                ),
                {"c": conv_id, "lo": lo, "hi": hi},
            )
            for uid in (me_id, peer_id):
                await db.execute(
                    text("insert into conversation_members (conversation_id, user_id) values (:c, :u)"),
                    {"c": conv_id, "u": uid},
                )
        # Per-chat prefs back to defaults for the theme / wallpaper walk.
        await db.execute(
            text("delete from conversation_prefs where conversation_id=:c and user_id=:u"),
            {"c": conv_id, "u": me_id},
        )
        # A second live session for ME ("iPad") so revoke-others has a victim.
        other_token, other_jti = await mint(me_id)
        await db.execute(
            text(
                "insert into sessions (id, user_id, device_name, platform, app_version, "
                "refresh_jti, access_jti, pin_verified_at, created_at, last_seen_at) values "
                "(:id, :u, 'iPad Pro (iPadOS 18.1)', 'ios', '1.0.0+45', :j, :j, now(), now(), now())"
            ),
            {"id": uuid.uuid4(), "u": me_id, "j": other_jti},
        )
        await db.commit()
    redis = await get_redis()
    for pattern in ("rate_limit:*", "net:*", "presence:*"):
        for key in await redis.keys(pattern):
            await redis.delete(key)
    peer_token, _ = await mint(peer_id)
    print(
        f"--dart-define=ME_ID={me_id} --dart-define=PEER_ID={peer_id} "
        f"--dart-define=CONV_ID={conv_id} --dart-define=PEER_TOKEN={peer_token} "
        f"--dart-define=ME_OTHER_TOKEN={other_token}"
    )


asyncio.run(main())
