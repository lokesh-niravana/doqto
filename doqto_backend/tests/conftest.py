"""Test harness — real local docker-compose Postgres (separate doqto_test DB)
and real local Redis (separate DB index 1), wired in via env overrides BEFORE
any app import so every code path (get_db, SessionLocal in websocket/lifespan
helpers) hits test infrastructure.

httpx ASGITransport does NOT run the lifespan, so the purge/subscriber
background tasks never start — tests can't hang on them.
"""
from __future__ import annotations

import os

TEST_DATABASE_URL = "postgresql+asyncpg://doqto:doqto@localhost:5432/doqto_test"
# Env vars beat .env in pydantic-settings — repoint the whole app at test infra.
# ENVIRONMENT must be explicit: the code default is the fail-safe "production".
os.environ["ENVIRONMENT"] = "local"
os.environ["DATABASE_URL"] = TEST_DATABASE_URL
os.environ["REDIS_URL"] = "redis://:doqto-dev@localhost:6379/1"

import asyncio  # noqa: E402
from types import SimpleNamespace  # noqa: E402

import asyncpg  # noqa: E402
import pytest  # noqa: E402
import sqlalchemy as sa  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402
from sqlalchemy.ext.asyncio import create_async_engine  # noqa: E402
from sqlalchemy.pool import NullPool  # noqa: E402

import app.db.postgres as pg  # noqa: E402
import app.db.redis as redis_mod  # noqa: E402
from app.core.config import settings  # noqa: E402
from app.db.postgres import Base, SessionLocal  # noqa: E402
from app.db.redis import close_redis, get_redis  # noqa: E402
from app.models import *  # noqa: E402,F401,F403 — register models on Base.metadata
from app.services.stripe_client import Subscription, get_stripe  # noqa: E402

# Tests run each function in its own event loop while the starlette TestClient
# (websocket tests) runs the app in a portal thread — a pooled asyncpg
# connection must never cross loops, so tests use NullPool.
pg.engine = create_async_engine(TEST_DATABASE_URL, echo=False, poolclass=NullPool)
SessionLocal.configure(bind=pg.engine)

from main import app  # noqa: E402
from tests import helpers  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def _test_database():
    """Create doqto_test (idempotent) and rebuild the schema once per run."""

    async def _setup() -> None:
        conn = await asyncpg.connect(
            user="doqto", password="doqto", database="doqto", host="localhost", port=5432
        )
        exists = await conn.fetchval(
            "SELECT 1 FROM pg_database WHERE datname = 'doqto_test'"
        )
        if not exists:
            await conn.execute("CREATE DATABASE doqto_test")
        await conn.close()

        engine = create_async_engine(TEST_DATABASE_URL, poolclass=NullPool)
        async with engine.begin() as c:
            await c.run_sync(Base.metadata.drop_all)
            await c.run_sync(Base.metadata.create_all)
            # Indexes that live only in migrations (0007, 0009).
            await c.execute(
                sa.text(
                    "CREATE UNIQUE INDEX uq_messages_conv_client_id ON messages "
                    "(conversation_id, client_id) WHERE client_id IS NOT NULL"
                )
            )
            await c.execute(
                sa.text(
                    "CREATE UNIQUE INDEX uq_messages_conv_seq ON messages "
                    "(conversation_id, seq)"
                )
            )
        await engine.dispose()

    asyncio.run(_setup())


@pytest.fixture(autouse=True)
async def _clean():
    """Empty all tables + Redis DB 1 before each test; drop the loop-bound
    Redis client afterwards so the next test's loop builds a fresh one."""
    async with pg.engine.begin() as c:
        tables = ", ".join(t.name for t in Base.metadata.sorted_tables)
        await c.execute(sa.text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))
    redis = await get_redis()
    await redis.flushdb()
    yield
    try:
        await close_redis()
    except Exception:
        redis_mod._redis = None


@pytest.fixture
async def db(_clean):
    async with SessionLocal() as session:
        yield session


@pytest.fixture
async def client(_clean):
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest.fixture
async def chat(db):
    """Standard scenario: one org, two doctors in a direct conversation."""
    org = await helpers.create_org(db)
    alice = await helpers.create_user(db, full_name="Dr Alice")
    bob = await helpers.create_user(db, full_name="Dr Bob")
    await helpers.add_org_member(db, org, alice)
    await helpers.add_org_member(db, org, bob)
    conv = await helpers.create_conversation(db, org, [alice, bob])
    return SimpleNamespace(
        org=org,
        alice=alice,
        bob=bob,
        conv=conv,
        alice_headers=await helpers.auth_headers(alice.id),
        bob_headers=await helpers.auth_headers(bob.id),
    )


@pytest.fixture
def firebase(monkeypatch):
    """Stub the Firebase ID-token verifier.

    Every sign-in path goes through /auth/firebase now, so any test that needs
    a signed-in session starts here. Returns an installer so each test picks
    the claims it wants.
    """
    from app.core.config import settings as _settings
    from app.services import firebase_auth

    monkeypatch.setattr(_settings, "FIREBASE_PROJECT_ID", "doqto-test")

    def _install(*, uid: str = "firebase-uid-abc123", phone: str | None = None,
                 email: str | None = None, raises: Exception | None = None):
        def _verify(id_token: str) -> firebase_auth.FirebaseIdentity:
            if raises is not None:
                raise raises
            return firebase_auth.FirebaseIdentity(uid=uid, phone=phone, email=email)

        monkeypatch.setattr(firebase_auth, "verify_id_token", _verify)

    return _install


class FakeStripe:
    """Stands in for Stripe everywhere. Records what it was asked for so tests
    can assert on the parameters, and hands back objects the real gateway
    would return."""

    def __init__(self) -> None:
        self.customers: list[str] = []
        self.checkouts: list[dict] = []
        self.portals: list[str] = []
        self.subscriptions: dict[str, Subscription] = {}
        self.event: dict | None = None
        self.signature_valid = True

    def ensure_customer(self, user) -> str:
        if user.stripe_customer_id:
            return user.stripe_customer_id
        customer_id = f"cus_fake{len(self.customers)}"
        self.customers.append(customer_id)
        return customer_id

    def checkout_url(self, *, customer_id: str, price_id: str, user_id: str) -> str:
        self.checkouts.append(
            {"customer_id": customer_id, "price_id": price_id, "user_id": user_id}
        )
        return "https://checkout.stripe.test/session"

    def portal_url(self, customer_id: str) -> str:
        self.portals.append(customer_id)
        return "https://portal.stripe.test/session"

    def subscription(self, subscription_id: str) -> Subscription:
        return self.subscriptions[subscription_id]

    def construct_event(self, payload: bytes, signature: str) -> dict:
        if not self.signature_valid:
            import stripe

            raise stripe.SignatureVerificationError("bad signature", signature)
        return self.event


@pytest.fixture
def stripe_gateway(monkeypatch):
    """A configured, faked Stripe. Also sets the price ids and a secret key so
    endpoints don't take the 503 path."""
    monkeypatch.setattr(settings, "STRIPE_SECRET_KEY", "sk_test_fake", raising=False)
    monkeypatch.setattr(settings, "STRIPE_PRICE_MONTHLY", "price_monthly", raising=False)
    monkeypatch.setattr(settings, "STRIPE_PRICE_YEARLY", "price_yearly", raising=False)
    monkeypatch.setattr(settings, "STRIPE_WEBHOOK_SECRET", "whsec_fake", raising=False)
    fake = FakeStripe()
    app.dependency_overrides[get_stripe] = lambda: fake
    yield fake
    app.dependency_overrides.pop(get_stripe, None)
