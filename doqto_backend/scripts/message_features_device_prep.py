"""Prepare the dev DB for the on-device batch-4 message-features walk
(doqto_app/integration_test/message_features_test.dart) and print its
dart-defines. Run with the local API up on :8010 (needs FIREBASE_PROJECT_ID):

    venv/bin/python scripts/message_features_device_prep.py

  me   = +1 650-555-0198 "Second Tester" (org forced ACTIVE)
  peer = +1 650-555-0199 "Demo Reviewer", acts over REST (sends, is forwarded
         to, owns the shared group so admin-delete and @mentions have a target)
The two are connected, no block / mute stands between them, a direct
conversation exists, and a network group "Batch 4 Walk" owned by the peer
with me as a plain member exists (one is reused when already there). Any pin
on either conversation and every star of mine are cleared so the walk starts
flat. Redis rate-limit and network-cache keys are dropped.
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
GROUP_NAME = "Batch 4 Walk"


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


async def ensure_group(db, owner_id, member_id):
    """A network group owned by [owner_id] with [member_id] as a member.
    Returns its conversation id."""
    row = (
        await db.execute(
            text("select id, conversation_id from groups where owner_id=:o and name=:n"),
            {"o": owner_id, "n": GROUP_NAME},
        )
    ).first()
    if row is None:
        group_id, conv_id = uuid.uuid4(), uuid.uuid4()
        await db.execute(
            text(
                "insert into conversations (id, org_id, type, name, created_by, access) "
                "values (:id, null, 'group', :name, :by, 'open')"
            ),
            {"id": conv_id, "name": GROUP_NAME, "by": owner_id},
        )
        await db.execute(
            text(
                "insert into groups (id, conversation_id, name, description, post_policy, "
                "member_dm_policy, owner_id, org_id, member_count) values "
                "(:id, :c, :name, 'Batch 4 device walk', 'all_members', 'request', :o, null, 0)"
            ),
            {"id": group_id, "c": conv_id, "name": GROUP_NAME, "o": owner_id},
        )
    else:
        group_id, conv_id = row
    for uid, role in ((owner_id, "owner"), (member_id, "member")):
        state = await db.scalar(
            text("select state from group_members where group_id=:g and user_id=:u"),
            {"g": group_id, "u": uid},
        )
        if state is None:
            await db.execute(
                text(
                    "insert into group_members (group_id, user_id, role, state) "
                    "values (:g, :u, :r, 'active')"
                ),
                {"g": group_id, "u": uid, "r": role},
            )
        elif state != "active":
            await db.execute(
                text("update group_members set state='active', role=:r where group_id=:g and user_id=:u"),
                {"g": group_id, "u": uid, "r": role},
            )
        member = await db.scalar(
            text("select 1 from conversation_members where conversation_id=:c and user_id=:u"),
            {"c": conv_id, "u": uid},
        )
        if not member:
            await db.execute(
                text("insert into conversation_members (conversation_id, user_id) values (:c, :u)"),
                {"c": conv_id, "u": uid},
            )
    await db.execute(
        text(
            "update groups set member_count=(select count(*) from group_members "
            "where group_id=:g and state='active') where id=:g"
        ),
        {"g": group_id},
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
        await ensure_connected(db, me_id, peer_id)
        conv_id = await ensure_direct(db, me_id, peer_id, me_id)
        group_conv = await ensure_group(db, peer_id, me_id)
        # Flat start: nothing pinned in either chat, no stars of mine, the DM
        # not archived / hidden so the thread opens and the forward target shows.
        await db.execute(
            text(
                "update conversations set pinned_message_id=null, pinned_until=null, pinned_by=null "
                "where id in (:a, :b)"
            ),
            {"a": conv_id, "b": group_conv},
        )
        await db.execute(text("delete from message_stars where user_id=:u"), {"u": me_id})
        await db.execute(text("delete from conversation_prefs where user_id=:u"), {"u": me_id})
        await db.commit()
    redis = await get_redis()
    for pattern in ("rate_limit:*", "net:*", "presence:*"):
        for key in await redis.keys(pattern):
            await redis.delete(key)
    print(
        f"--dart-define=ME_ID={me_id} --dart-define=PEER_ID={peer_id} "
        f"--dart-define=CONV_ID={conv_id} --dart-define=GROUP_CONV_ID={group_conv} "
        f"--dart-define=PEER_TOKEN={await mint(peer_id)}"
    )


asyncio.run(main())
