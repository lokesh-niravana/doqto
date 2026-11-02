"""Protocol-level realtime E2E against a live backend.

Boots `uvicorn main:app --port 8010` against the dev DB, seeds four users
straight into Postgres (Alice, Bob — who never joins an org —, Carol, and a
super-admin), opens an authenticated /ws socket per user, drives every
mutation through REST and asserts that the right frame lands on the right
socket. Run from doqto_backend with its venv:

    venv/bin/python scripts/ws_e2e.py
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
os.chdir(BACKEND)
sys.path.insert(0, str(BACKEND))

import httpx  # noqa: E402
import websockets  # noqa: E402

from app.core.constants import ACCESS_TOKEN_TTL_SECONDS  # noqa: E402
from app.core.enums import JwtTokenType, UserRole  # noqa: E402
from app.core.redis_keys import session_key  # noqa: E402
from app.core.security import create_token  # noqa: E402
from app.db.postgres import SessionLocal  # noqa: E402
from app.db.redis import get_redis  # noqa: E402
from tests import helpers  # noqa: E402

PORT = 8010
BASE = f"http://localhost:{PORT}"
WS = f"ws://localhost:{PORT}/ws"
API = f"{BASE}/api/v1"

RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + (f"  — {detail}" if detail and not ok else ""))


class Sock:
    """One user's /ws connection with a frame inbox."""

    def __init__(self, name: str, token: str, url: str = WS):
        self.name, self.token, self.url = name, token, url
        self.frames: list[dict] = []
        self.ws = None

    async def open(self) -> dict:
        self.ws = await websockets.connect(self.url)
        await self.ws.send(json.dumps({"type": "auth", "token": self.token}))
        first = json.loads(await asyncio.wait_for(self.ws.recv(), 5))
        return first

    async def expect(self, type_: str, timeout: float = 5.0, **where) -> dict | None:
        """Wait for a frame of `type_` whose data matches `where`; other
        frames are kept in the inbox so nothing is silently dropped."""
        deadline = time.monotonic() + timeout
        for f in self.frames:
            if _match(f, type_, where):
                self.frames.remove(f)
                return f
        while time.monotonic() < deadline:
            try:
                raw = await asyncio.wait_for(self.ws.recv(), deadline - time.monotonic())
            except asyncio.TimeoutError:
                break
            f = json.loads(raw)
            if _match(f, type_, where):
                return f
            self.frames.append(f)
        return None

    async def expect_silence(self, type_: str, seconds: float = 1.0, **where) -> bool:
        f = await self.expect(type_, timeout=seconds, **where)
        if f is not None:
            self.frames.append(f)
        return f is None

    async def close(self):
        if self.ws is not None:
            await self.ws.close()


def _match(frame: dict, type_: str, where: dict) -> bool:
    if frame.get("type") != type_:
        return False
    data = frame.get("data") or {}
    return all(str(data.get(k)) == str(v) for k, v in where.items())


async def mint(user_id: uuid.UUID) -> str:
    token, jti = create_token(user_id, JwtTokenType.ACCESS)
    redis = await get_redis()
    await redis.setex(session_key(jti), ACCESS_TOKEN_TTL_SECONDS, "1")
    return token


async def seed():
    async with SessionLocal() as db:
        alice = await helpers.create_user(db, full_name="E2E Alice")
        bob = await helpers.create_user(db, full_name="E2E Bob")
        carol = await helpers.create_user(db, full_name="E2E Carol")
        staff = await helpers.create_user(db, full_name="E2E Staff")
        staff.role = UserRole.SUPER_ADMIN
        await db.commit()
        ids = {u: x.id for u, x in dict(alice=alice, bob=bob, carol=carol, staff=staff).items()}
    tokens = {k: await mint(v) for k, v in ids.items()}
    return ids, tokens


def boot_server() -> subprocess.Popen:
    env = dict(os.environ, ENVIRONMENT="local")
    proc = subprocess.Popen(
        [str(BACKEND / "venv/bin/uvicorn"), "main:app", "--port", str(PORT), "--log-level", "warning"],
        cwd=BACKEND,
        env=env,
        stdout=open("/tmp/doqto_e2e_uvicorn.log", "w"),
        stderr=subprocess.STDOUT,
    )
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            if httpx.get(f"{BASE}/health", timeout=1).status_code == 200:
                return proc
        except Exception:
            pass
        if proc.poll() is not None:
            raise SystemExit("uvicorn died, see /tmp/doqto_e2e_uvicorn.log")
        time.sleep(0.5)
    raise SystemExit("uvicorn never became healthy")


async def main() -> int:
    ids, tokens = await seed()
    H = {k: {"Authorization": f"Bearer {v}"} for k, v in tokens.items()}
    A, B, C = str(ids["alice"]), str(ids["bob"]), str(ids["carol"])

    async with httpx.AsyncClient(base_url=API, timeout=10) as http:
        def ok(r, code=None):
            assert 200 <= r.status_code < 300, f"{r.request.method} {r.request.url} → {r.status_code} {r.text}"
            return r.json() if r.content else None

        # ---- 1. handshake: every user, org or not, gets `connected` first
        alice, bob, carol = Sock("alice", tokens["alice"]), Sock("bob", tokens["bob"]), Sock("carol", tokens["carol"])
        for s, uid in ((alice, A), (bob, B), (carol, C)):
            first = await s.open()
            check(f"handshake: {s.name} (no org) first frame is connected",
                  first == {"type": "connected", "data": {"user_id": uid}}, json.dumps(first))

        # ---- 2. invitation received / accepted
        inv = ok(await http.post("/network/invitations", json={"recipient_id": B}, headers=H["alice"]), 201)
        inv_id = inv["invitation"]["id"]
        f = await bob.expect("invitation_received", sender_id=A)
        check("invite: Bob's socket gets invitation_received", f is not None)
        ok(await http.post(f"/network/invitations/{inv_id}/accept", headers=H["bob"]))
        f = await alice.expect("invitation_accepted", user_id=B)
        check("accept: Alice's socket gets invitation_accepted", f is not None)

        # ---- 3. messaging both ways + read receipts
        conv = ok(await http.post("/conversations", json={"type": "direct", "member_ids": [B]}, headers=H["alice"]), 201)
        conv_id = conv["id"]
        ok(await http.post(f"/conversations/{conv_id}/messages", json={"content": "hi bob"}, headers=H["alice"]), 201)
        f = await bob.expect("new_message", conversation_id=conv_id)
        check("message: Bob's socket gets new_message", f is not None)
        ok(await http.post(f"/conversations/{conv_id}/read", headers=H["bob"]))
        f = await alice.expect("message_read", conversation_id=conv_id)
        check("read: Alice's socket gets message_read", f is not None)
        ok(await http.post(f"/conversations/{conv_id}/messages", json={"content": "hi alice"}, headers=H["bob"]), 201)
        f = await alice.expect("new_message", conversation_id=conv_id)
        check("message: Alice's socket gets Bob's new_message", f is not None)

        # ---- 4. withdraw (new event)
        inv2 = ok(await http.post("/network/invitations", json={"recipient_id": C}, headers=H["alice"]), 201)
        inv2_id = inv2["invitation"]["id"]
        check("invite: Carol gets invitation_received", await carol.expect("invitation_received", sender_id=A) is not None)
        ok(await http.delete(f"/network/invitations/{inv2_id}", headers=H["alice"]))
        f = await carol.expect("invitation_withdrawn", invitation_id=inv2_id, sender_id=A)
        check("withdraw: Carol's socket gets invitation_withdrawn", f is not None)

        # ---- 5. profile edits (new event) reach connections only
        ok(await http.patch("/users/me", json={"headline": "Realtime cardiology"}, headers=H["alice"]))
        check("profile: Bob (connected) gets profile_updated", await bob.expect("profile_updated", user_id=A) is not None)
        check("profile: Carol (not connected) gets nothing", await carol.expect_silence("profile_updated", user_id=A))

        # ---- 6. org lifecycle (new event) incl. admin verify — no polling
        org = ok(await http.post("/orgs", json={"name": "E2E Clinic"}, headers=H["alice"]))
        org_id = org["id"]
        f = await alice.expect("org_updated", org_id=org_id, status="pending")
        check("org: creator gets org_updated(pending)", f is not None)
        ok(await http.patch(f"/admin/orgs/{org_id}/verify", headers=H["staff"]))
        f = await alice.expect("org_updated", org_id=org_id, status="active")
        check("org: admin verify pushes org_updated(active) to the member", f is not None)

        # ---- 7. groups: invite, join, rename, role, removal
        grp = ok(await http.post("/groups", json={"name": "E2E Rounds"}, headers=H["alice"]), 201)
        gid = grp["id"]
        ginv = ok(await http.post(f"/groups/{gid}/invites", json={"user_id": B}, headers=H["alice"]), 201)
        check("group: Bob gets group_invite_received", await bob.expect("group_invite_received", group_id=gid) is not None)
        ok(await http.post(f"/groups/{gid}/invites/{ginv['id']}/accept", headers=H["bob"]))
        check("group: Alice gets group_member_joined", await alice.expect("group_member_joined", group_id=gid) is not None)
        ok(await http.patch(f"/groups/{gid}", json={"name": "E2E Rounds v2"}, headers=H["alice"]))
        check("group: rename pushes group_updated to Bob", await bob.expect("group_updated", group_id=gid) is not None)
        ok(await http.patch(f"/groups/{gid}/members/{B}", json={"role": "moderator"}, headers=H["alice"]))
        check("group: role change pushes group_updated to Bob", await bob.expect("group_updated", group_id=gid) is not None)
        ok(await http.delete(f"/groups/{gid}/members/{B}", headers=H["alice"]))
        check("group: removal pushes member_removed to Bob", await bob.expect("member_removed", user_id=B) is not None)
        check("group: removal pushes group_updated to Bob", await bob.expect("group_updated", group_id=gid) is not None)

        # ---- 8. block looks like a removal, nothing more
        ok(await http.post(f"/network/blocks/{B}", headers=H["alice"]))
        check("block: Bob sees connection_removed", await bob.expect("connection_removed", user_id=A) is not None)

        # ---- 9. legacy alias still handshakes
        legacy = Sock("alice-legacy", tokens["alice"], url=f"ws://localhost:{PORT}/ws/{org_id}")
        first = await legacy.open()
        check("handshake: legacy /ws/{org_id} alias answers connected", first.get("type") == "connected")
        await legacy.close()

        # ---- 10. a bad token is rejected with 4401 and no frame
        bad = Sock("bad", tokens["alice"][:-4] + "xxxx")
        try:
            await bad.open()
            check("auth: bad token rejected", False, "got a frame")
        except websockets.exceptions.ConnectionClosed as e:
            check("auth: bad token closes with 4401", e.rcvd is not None and e.rcvd.code == 4401, str(e))

        for s in (alice, bob, carol):
            await s.close()
            if s.frames:
                print(f"  ({s.name} inbox leftovers: {[f['type'] for f in s.frames]})")

    failed = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    server = boot_server()
    try:
        code = asyncio.run(main())
    finally:
        server.terminate()
        try:
            server.wait(10)
        except subprocess.TimeoutExpired:
            server.kill()
    sys.exit(code)
