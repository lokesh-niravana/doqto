# Stripe Billing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Doctors subscribe to Doqto through Stripe Checkout in the browser, after a 14-day card-free trial, and lose the ability to send once both lapse.

**Architecture:** The backend owns the truth. It mirrors Stripe's subscription onto the `users` row from a signed webhook, exposes one entitlement rule, and returns 402 from content-creating endpoints when that rule says no. The app never talks to Stripe: it asks `GET /billing`, opens the Checkout or Portal URL the backend hands it in an external browser, and re-checks when it comes back.

**Tech Stack:** FastAPI, SQLAlchemy 2, Alembic, the official `stripe` Python SDK, Flutter with Riverpod and `url_launcher`, Terraform, Next.js static export for the landing page.

**Spec:** `docs/superpowers/specs/2026-09-22-stripe-billing-design.md`

## Global Constraints

- Prices: $8.99/month, $80/year, USD. Yearly saving is 26%, effective $6.67/mo.
- Trial: 14 days, no card, stored in our database as `users.trial_ends_at`.
- Grace after a failed renewal: 7 days past `current_period_end`.
- Stripe receives only the doctor's email and our user id. Never message content, NPI, specialty, org, or any patient data.
- Never log a webhook payload, a Stripe secret, or a Checkout URL's full query.
- Checkout and Portal URLs open in an external browser (`LaunchMode.externalApplication`). Never a web view: Apple's US link-out rule requires it.
- Every new backend setting has a safe default so local dev and tests run with no Stripe keys. With `STRIPE_SECRET_KEY` empty, entitlement still works and Stripe-calling endpoints return 503 `billing_unavailable`.
- Backend tests never touch the network. Stripe is always a fake injected through FastAPI's dependency overrides.
- Flutter: every new text input obeys the keyboard rule in `CLAUDE.md`. `flutter analyze lib test` and `flutter test` must be clean before any commit that touches the app.
- Run backend tests with `venv/bin/python -m pytest` from `doqto_backend/`, unpiped. Postgres and Redis come from `docker compose up -d postgres redis`.

## Review Focus

1. **A user whose trial has never been set** (registration abandoned half-way, `trial_ends_at IS NULL`, no subscription) must be refused by the paywall rather than crash the entitlement call. Task 2 pins it.
2. **The exact trial boundary.** At `now == trial_ends_at` the trial is over, not running. Task 2 pins both sides of the boundary.
3. **Every existing backend test** creates users through `tests/helpers.create_user`, which does not set a trial. Without a default there, the 402 gate breaks ~184 unrelated tests. Task 1 sets the default and Task 6 proves a gated endpoint still answers 200 for a normal test user.
4. **Webhooks arriving out of order or twice.** Stripe guarantees neither order nor exactly-once. The handler re-fetches the subscription, so a `deleted` followed by a stale `updated` must still end cancelled. Task 5 pins it.
5. **Stripe misconfigured in production** (empty or wrong key) must surface as 503 `billing_unavailable` and a readable message, never a 500 that the app renders as "Something went wrong". Tasks 4 and 9 pin it.

---

## File Structure

**Backend (`doqto_backend/`)**

| File | Responsibility |
|---|---|
| `alembic/versions/0023_billing.py` | Create: billing columns, backfill trials, demo account exemption. |
| `app/models/user.py` | Modify: six billing columns. |
| `app/services/billing_service.py` | Create: the entitlement rule. Pure, no I/O. |
| `app/services/stripe_client.py` | Create: the only file that imports `stripe`. |
| `app/api/v1/billing.py` | Create: the four endpoints. |
| `app/schemas/billing.py` | Create: request and response models. |
| `app/core/dependencies.py` | Modify: `require_entitled`. |
| `app/core/config.py` | Modify: seven settings. |
| `app/core/routes.py` | Modify: `ApiPrefix.BILLING` and four route constants. |
| `main.py` | Modify: register the billing router. |
| `tests/helpers.py` | Modify: `create_user` gets a default trial. |
| `tests/conftest.py` | Modify: `stripe` fixture (fake client + dependency override). |
| `tests/test_billing_entitlement.py` | Create. |
| `tests/test_billing_endpoints.py` | Create: status, checkout, portal. |
| `tests/test_billing_webhook.py` | Create. |
| `tests/test_billing_gating.py` | Create: the 402 wall. |

**App (`doqto_app/`)**

| File | Responsibility |
|---|---|
| `lib/data/models/billing.dart` | Create: `Billing` plus the saving calculation. |
| `lib/data/repositories/billing_repository.dart` | Create: three calls. |
| `lib/data/services/url_opener.dart` | Create: launches external URLs; fakeable. |
| `lib/state/billing_state.dart` | Create: cached billing status, refresh, post-checkout polling. |
| `lib/state/auth_state.dart` | Modify: `AuthStage.needsSubscription`, checked in the resolver. |
| `lib/core/router/app_router.dart` | Modify: `/paywall` route and its redirect. |
| `lib/ui/screens/payments/payments_screen.dart` | Modify: onboarding and paywall modes, Subscribe button. |
| `lib/ui/screens/settings/settings_screen.dart` | Modify: Subscription row. |
| `lib/core/constants/api_routes.dart`, `strings.dart`, `lib/core/utils/error_messages.dart`, `lib/core/di/providers.dart` | Modify: routes, copy, error text, providers. |
| `test/widgets/paywall_test.dart`, `test/billing_test.dart` | Create. |

**Infra and web**

| File | Responsibility |
|---|---|
| `infra/backend/main.tf` | Modify: two SSM secrets, three env values. |
| `landing/src/app/billing/done/page.tsx` | Create: the return page. |

---

### Task 1: Billing columns, migration, and the test default

**Files:**
- Modify: `doqto_backend/app/models/user.py`
- Create: `doqto_backend/alembic/versions/0023_billing.py`
- Modify: `doqto_backend/tests/helpers.py`
- Test: `doqto_backend/tests/test_billing_entitlement.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `User.trial_ends_at`, `User.stripe_customer_id`, `User.stripe_subscription_id`, `User.billing_status`, `User.billing_plan`, `User.current_period_end`. `helpers.create_user(db, *, trial_days: int | None = 14, **kw)`.

- [ ] **Step 1: Write the failing test**

Create `doqto_backend/tests/test_billing_entitlement.py`:

```python
"""Billing columns and the entitlement rule."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from tests import helpers

pytestmark = pytest.mark.asyncio


async def test_a_new_user_gets_a_trial_by_default(db):
    user = await helpers.create_user(db)

    assert user.trial_ends_at is not None
    assert user.trial_ends_at > datetime.now(timezone.utc) + timedelta(days=13)
    assert user.billing_status is None
    assert user.stripe_customer_id is None


async def test_a_user_can_be_created_without_a_trial(db):
    user = await helpers.create_user(db, trial_days=None)

    assert user.trial_ends_at is None
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd doqto_backend && venv/bin/python -m pytest tests/test_billing_entitlement.py -q`
Expected: FAIL, `TypeError: create_user() got an unexpected keyword argument 'trial_days'`.

- [ ] **Step 3: Add the columns to the model**

In `app/models/user.py`, after the `firebase_uid` column, add:

```python
    # Billing — mirrored from Stripe by the webhook, except trial_ends_at,
    # which is ours: the trial needs no card, so Stripe never sees it.
    trial_ends_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    stripe_customer_id: Mapped[str | None] = mapped_column(
        String(64), unique=True, nullable=True
    )
    stripe_subscription_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    billing_status: Mapped[str | None] = mapped_column(String(20), nullable=True)
    billing_plan: Mapped[str | None] = mapped_column(String(10), nullable=True)
    current_period_end: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
```

- [ ] **Step 4: Write the migration**

Create `alembic/versions/0023_billing.py`:

```python
"""Stripe billing on users.

Six columns. Five mirror Stripe; `trial_ends_at` is ours, because the 14-day
trial takes no card and so never exists in Stripe.

Backfill: everyone already registered starts their trial now rather than at
sign-up, so nobody wakes up locked out on deploy day. The App Review demo
account gets a trial that never ends.

Revision ID: 0023_billing
Revises: 0022_firebase_identity
Create Date: 2026-09-23
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0023_billing"
down_revision: Union[str, None] = "0022_firebase_identity"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

DEMO_PHONE = "+16505550199"


def upgrade() -> None:
    op.add_column("users", sa.Column("trial_ends_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("users", sa.Column("stripe_customer_id", sa.String(length=64), nullable=True))
    op.add_column("users", sa.Column("stripe_subscription_id", sa.String(length=64), nullable=True))
    op.add_column("users", sa.Column("billing_status", sa.String(length=20), nullable=True))
    op.add_column("users", sa.Column("billing_plan", sa.String(length=10), nullable=True))
    op.add_column(
        "users", sa.Column("current_period_end", sa.DateTime(timezone=True), nullable=True)
    )
    op.create_unique_constraint("uq_users_stripe_customer_id", "users", ["stripe_customer_id"])

    # Registered = has a name and a real NPI. Half-finished sign-ups get their
    # trial when they finish registering.
    op.execute(
        """
        UPDATE users
           SET trial_ends_at = now() + interval '14 days'
         WHERE full_name <> ''
           AND npi_number NOT LIKE 'PENDING%'
           AND deleted_at IS NULL
        """
    )
    op.execute(
        f"""
        UPDATE users
           SET trial_ends_at = TIMESTAMPTZ '2099-01-01 00:00:00+00'
         WHERE phone = '{DEMO_PHONE}'
        """
    )


def downgrade() -> None:
    op.drop_constraint("uq_users_stripe_customer_id", "users", type_="unique")
    for column in (
        "current_period_end",
        "billing_plan",
        "billing_status",
        "stripe_subscription_id",
        "stripe_customer_id",
        "trial_ends_at",
    ):
        op.drop_column("users", column)
```

- [ ] **Step 5: Give the test helper a trial**

In `tests/helpers.py`, change `create_user`. Add the import `from datetime import datetime, timedelta, timezone` if it is missing, add the parameter, and set the column:

```python
async def create_user(
    db: AsyncSession,
    *,
    full_name: str = "Dr Test",
    specialty: str | None = None,
    city: str | None = None,
    state: str | None = None,
    headline: str | None = None,
    handle: str | None = None,
    trial_days: int | None = 14,
) -> User:
    user = User(
        phone=f"+1{_digits(10)}",
        full_name=full_name,
        npi_number=_digits(10),
        specialty=specialty,
        city=city,
        state=state,
        headline=headline,
        handle=handle,
        # Every test user is a normal, entitled doctor unless a test says
        # otherwise. Without this the 402 gate would fail every suite.
        trial_ends_at=(
            None if trial_days is None
            else datetime.now(timezone.utc) + timedelta(days=trial_days)
        ),
    )
```

- [ ] **Step 6: Run the migration and the test**

Run:
```bash
cd doqto_backend && docker compose up -d postgres redis && venv/bin/python -m pytest tests/test_billing_entitlement.py -q
```
Expected: 2 passed. The test database is rebuilt from the models by `conftest.py`, so no manual `alembic upgrade` is needed for tests.

- [ ] **Step 7: Check the migration itself applies**

Run:
```bash
cd doqto_backend && venv/bin/python -m alembic upgrade head && venv/bin/python -m alembic downgrade -1 && venv/bin/python -m alembic upgrade head
```
Expected: no errors. This runs against the local dev database from `.env`.

- [ ] **Step 8: Run the whole backend suite**

Run: `cd doqto_backend && venv/bin/python -m pytest -q`
Expected: everything that passed before still passes.

- [ ] **Step 9: Commit**

```bash
git add doqto_backend/app/models/user.py doqto_backend/alembic/versions/0023_billing.py doqto_backend/tests/helpers.py doqto_backend/tests/test_billing_entitlement.py
git commit -m "billing: columns on users, migration, trial default for tests"
```

---

### Task 2: The entitlement rule

**Files:**
- Create: `doqto_backend/app/services/billing_service.py`
- Modify: `doqto_backend/app/core/config.py`
- Test: `doqto_backend/tests/test_billing_entitlement.py`

**Interfaces:**
- Consumes: the `User` columns from Task 1.
- Produces: `Entitlement(entitled: bool, reason: str)` and `entitlement(user: User, now: datetime | None = None) -> Entitlement`. Reasons are exactly `staff`, `trial`, `subscribed`, `grace`, `expired`. Settings `BILLING_TRIAL_DAYS`, `BILLING_GRACE_DAYS`, `BILLING_PRICE_MONTHLY_CENTS`, `BILLING_PRICE_YEARLY_CENTS`, `BILLING_RETURN_URL`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_MONTHLY`, `STRIPE_PRICE_YEARLY`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_billing_entitlement.py`:

```python
from app.core.enums import UserRole
from app.services.billing_service import entitlement

NOW = datetime(2026, 9, 23, 12, 0, tzinfo=timezone.utc)


async def test_a_running_trial_is_entitled(db):
    user = await helpers.create_user(db, trial_days=None)
    user.trial_ends_at = NOW + timedelta(seconds=1)

    assert entitlement(user, NOW) == (True, "trial")


async def test_the_trial_ends_exactly_at_its_deadline(db):
    user = await helpers.create_user(db, trial_days=None)
    user.trial_ends_at = NOW

    # Not "one more second of goodwill": the deadline IS the end.
    assert entitlement(user, NOW) == (False, "expired")


async def test_a_user_who_never_had_a_trial_is_refused(db):
    # Registration abandoned half-way: no trial, no subscription, no crash.
    user = await helpers.create_user(db, trial_days=None)

    assert entitlement(user, NOW) == (False, "expired")


@pytest.mark.parametrize("status", ["active", "trialing"])
async def test_a_live_subscription_is_entitled(db, status):
    user = await helpers.create_user(db, trial_days=None)
    user.billing_status = status

    assert entitlement(user, NOW) == (True, "subscribed")


async def test_a_failed_payment_keeps_access_for_the_grace_period(db):
    user = await helpers.create_user(db, trial_days=None)
    user.billing_status = "past_due"
    user.current_period_end = NOW - timedelta(days=6)

    assert entitlement(user, NOW) == (True, "grace")


async def test_grace_runs_out_after_seven_days(db):
    user = await helpers.create_user(db, trial_days=None)
    user.billing_status = "past_due"
    user.current_period_end = NOW - timedelta(days=7)

    assert entitlement(user, NOW) == (False, "expired")


async def test_a_cancelled_subscription_is_refused(db):
    user = await helpers.create_user(db, trial_days=None)
    user.billing_status = "canceled"

    assert entitlement(user, NOW) == (False, "expired")


async def test_staff_never_meet_the_paywall(db):
    user = await helpers.create_user(db, trial_days=None)
    user.role = UserRole.SUPER_ADMIN

    assert entitlement(user, NOW) == (True, "staff")
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd doqto_backend && venv/bin/python -m pytest tests/test_billing_entitlement.py -q`
Expected: FAIL, `ModuleNotFoundError: No module named 'app.services.billing_service'`.

- [ ] **Step 3: Add the settings**

In `app/core/config.py`, after the `FIREBASE_PROJECT_ID` block:

```python
    # Billing. Every value has a default so local dev and tests run with no
    # Stripe account at all: entitlement still works, only the endpoints that
    # call Stripe refuse (503 billing_unavailable).
    STRIPE_SECRET_KEY: str = ""
    STRIPE_WEBHOOK_SECRET: str = ""
    STRIPE_PRICE_MONTHLY: str = ""
    STRIPE_PRICE_YEARLY: str = ""
    BILLING_TRIAL_DAYS: int = 14
    BILLING_GRACE_DAYS: int = 7
    # Shown in the app so the yearly saving is computed, never typed twice.
    # Must match the Stripe prices above.
    BILLING_PRICE_MONTHLY_CENTS: int = 899
    BILLING_PRICE_YEARLY_CENTS: int = 8000
    BILLING_RETURN_URL: str = "https://doqto.ai/billing/done"
```

- [ ] **Step 4: Write the rule**

Create `app/services/billing_service.py`:

```python
"""Who may use Doqto, and why.

One rule, in one place, so the API, the app and any future admin screen can
never disagree. Pure: no database, no network, no clock of its own.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import NamedTuple

from app.core.config import settings
from app.core.enums import UserRole
from app.models import User

# Stripe statuses that mean "this person is paid up". `trialing` only appears
# if a Stripe-side trial is ever configured; our own trial lives in the
# database and is checked first.
LIVE_STATUSES = frozenset({"active", "trialing"})


class Entitlement(NamedTuple):
    entitled: bool
    reason: str  # staff | trial | subscribed | grace | expired


def entitlement(user: User, now: datetime | None = None) -> Entitlement:
    """First matching rule wins."""
    now = now or datetime.now(timezone.utc)

    if user.role == UserRole.SUPER_ADMIN:
        return Entitlement(True, "staff")

    if user.trial_ends_at is not None and user.trial_ends_at > now:
        return Entitlement(True, "trial")

    if user.billing_status in LIVE_STATUSES:
        return Entitlement(True, "subscribed")

    # A failed renewal keeps the door open briefly: cards expire, people are
    # on call, and losing a messaging app over a declined charge is worse than
    # a few unpaid days.
    if (
        user.billing_status == "past_due"
        and user.current_period_end is not None
        and user.current_period_end + timedelta(days=settings.BILLING_GRACE_DAYS) > now
    ):
        return Entitlement(True, "grace")

    return Entitlement(False, "expired")
```

- [ ] **Step 5: Run the tests**

Run: `cd doqto_backend && venv/bin/python -m pytest tests/test_billing_entitlement.py -q`
Expected: 10 passed.

- [ ] **Step 6: Commit**

```bash
git add doqto_backend/app/services/billing_service.py doqto_backend/app/core/config.py doqto_backend/tests/test_billing_entitlement.py
git commit -m "billing: the entitlement rule (trial, subscription, grace)"
```

---

### Task 3: The Stripe client wrapper and its fake

**Files:**
- Create: `doqto_backend/app/services/stripe_client.py`
- Modify: `doqto_backend/requirements.txt`
- Modify: `doqto_backend/tests/conftest.py`

**Interfaces:**
- Consumes: settings from Task 2.
- Produces: `StripeGateway` with `ensure_customer(user) -> str`, `checkout_url(customer_id, price_id, user_id) -> str`, `portal_url(customer_id) -> str`, `subscription(subscription_id) -> Subscription`, `construct_event(payload: bytes, signature: str) -> dict`. `Subscription(id, customer_id, status, price_id, current_period_end)`. Dependency `get_stripe()` raising 503 `billing_unavailable` when unconfigured. Test fixture `stripe_gateway` returning a `FakeStripe` that is already installed as the dependency override.

- [ ] **Step 1: Add the dependency**

In `doqto_backend/requirements.txt`, add the line `stripe==11.4.1` in alphabetical order, then:

```bash
cd doqto_backend && venv/bin/pip install -r requirements.txt
```

- [ ] **Step 2: Write the wrapper**

Create `app/services/stripe_client.py`:

```python
"""The only module that imports `stripe`.

Everything else speaks in our own small types, which keeps Stripe out of the
API layer and makes the whole billing surface testable with a fake.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import NamedTuple

import stripe
from fastapi import HTTPException, status

from app.core.config import settings
from app.models import User


class Subscription(NamedTuple):
    id: str
    customer_id: str
    status: str
    price_id: str | None
    current_period_end: datetime | None


class StripeGateway:
    """Thin, synchronous wrapper. Calls are short; FastAPI runs the endpoints
    that use it in a threadpool via `run_in_threadpool`."""

    def __init__(self, api_key: str) -> None:
        self._client = stripe.StripeClient(api_key)

    def ensure_customer(self, user: User) -> str:
        if user.stripe_customer_id:
            return user.stripe_customer_id
        # metadata carries our id so a webhook can find the user even when the
        # checkout session is long gone. Email is the only personal field we
        # send, and only so receipts reach the doctor.
        customer = self._client.customers.create(
            params={"email": user.email or None, "metadata": {"user_id": str(user.id)}}
        )
        return customer.id

    def checkout_url(self, *, customer_id: str, price_id: str, user_id: str) -> str:
        session = self._client.checkout.sessions.create(
            params={
                "mode": "subscription",
                "customer": customer_id,
                "line_items": [{"price": price_id, "quantity": 1}],
                "client_reference_id": user_id,
                "success_url": f"{settings.BILLING_RETURN_URL}?status=success",
                "cancel_url": f"{settings.BILLING_RETURN_URL}?status=cancel",
                "allow_promotion_codes": True,
            }
        )
        return session.url

    def portal_url(self, customer_id: str) -> str:
        session = self._client.billing_portal.sessions.create(
            params={"customer": customer_id, "return_url": settings.BILLING_RETURN_URL}
        )
        return session.url

    def subscription(self, subscription_id: str) -> Subscription:
        sub = self._client.subscriptions.retrieve(subscription_id)
        items = sub["items"]["data"]
        period_end = sub.get("current_period_end")
        return Subscription(
            id=sub.id,
            customer_id=str(sub.customer),
            status=sub.status,
            price_id=items[0]["price"]["id"] if items else None,
            current_period_end=(
                datetime.fromtimestamp(period_end, tz=timezone.utc) if period_end else None
            ),
        )

    def construct_event(self, payload: bytes, signature: str) -> dict:
        """Raises stripe.SignatureVerificationError on a forged request."""
        return stripe.Webhook.construct_event(
            payload, signature, settings.STRIPE_WEBHOOK_SECRET
        )


_gateway: StripeGateway | None = None


def get_stripe() -> StripeGateway:
    """FastAPI dependency. 503 rather than 500 when Stripe isn't configured:
    that is a deployment problem, and the app shows a readable message."""
    global _gateway
    if not settings.STRIPE_SECRET_KEY:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, detail="billing_unavailable"
        )
    if _gateway is None:
        _gateway = StripeGateway(settings.STRIPE_SECRET_KEY)
    return _gateway
```

- [ ] **Step 3: Write the fake and the fixture**

In `tests/conftest.py`, add the imports and the fixture at the end of the file:

```python
from app.services import stripe_client
from app.services.stripe_client import Subscription, get_stripe
from main import app as fastapi_app


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
    fastapi_app.dependency_overrides[get_stripe] = lambda: fake
    yield fake
    fastapi_app.dependency_overrides.pop(get_stripe, None)
```

Add `from app.core.config import settings` to the conftest imports if it is not already there.

- [ ] **Step 4: Check nothing broke**

Run: `cd doqto_backend && venv/bin/python -m pytest -q`
Expected: the same pass count as Task 1 finished with. The new fixture is unused so far.

- [ ] **Step 5: Commit**

```bash
git add doqto_backend/app/services/stripe_client.py doqto_backend/requirements.txt doqto_backend/tests/conftest.py
git commit -m "billing: Stripe gateway wrapper and its test fake"
```

---

### Task 4: Status, checkout and portal endpoints

**Files:**
- Create: `doqto_backend/app/schemas/billing.py`
- Create: `doqto_backend/app/api/v1/billing.py`
- Modify: `doqto_backend/app/core/routes.py`
- Modify: `doqto_backend/main.py`
- Test: `doqto_backend/tests/test_billing_endpoints.py`

**Interfaces:**
- Consumes: `entitlement` (Task 2), `get_stripe` (Task 3).
- Produces: `GET /api/v1/billing`, `POST /api/v1/billing/checkout`, `POST /api/v1/billing/portal`. Response `BillingOut(entitled, reason, trial_ends_at, plan, status, current_period_end, monthly_cents, yearly_cents)`. Request `CheckoutIn(plan)`. Response `UrlOut(url)`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_billing_endpoints.py`:

```python
"""Billing status, checkout and portal."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from tests import helpers

pytestmark = pytest.mark.asyncio


async def test_status_reports_a_running_trial(client, db):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.get("/api/v1/billing", headers=headers)

    assert r.status_code == 200
    body = r.json()
    assert body["entitled"] is True
    assert body["reason"] == "trial"
    assert body["trial_ends_at"] is not None
    assert body["plan"] is None
    # The app computes the yearly saving from these, never from typed-in copy.
    assert body["monthly_cents"] == 899
    assert body["yearly_cents"] == 8000


async def test_status_reports_an_expired_user(client, db):
    user = await helpers.create_user(db, trial_days=None)
    headers = await helpers.auth_headers(user.id)

    r = await client.get("/api/v1/billing", headers=headers)

    assert r.json()["entitled"] is False
    assert r.json()["reason"] == "expired"


async def test_checkout_returns_a_stripe_url_and_remembers_the_customer(
    client, db, stripe_gateway
):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/checkout", json={"plan": "yearly"}, headers=headers)

    assert r.status_code == 200
    assert r.json()["url"] == "https://checkout.stripe.test/session"
    assert stripe_gateway.checkouts == [
        {
            "customer_id": "cus_fake0",
            "price_id": "price_yearly",
            "user_id": str(user.id),
        }
    ]
    await db.refresh(user)
    assert user.stripe_customer_id == "cus_fake0"


async def test_checkout_reuses_the_existing_customer(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_existing"
    await db.commit()
    headers = await helpers.auth_headers(user.id)

    await client.post("/api/v1/billing/checkout", json={"plan": "monthly"}, headers=headers)

    assert stripe_gateway.customers == []
    assert stripe_gateway.checkouts[0]["customer_id"] == "cus_existing"
    assert stripe_gateway.checkouts[0]["price_id"] == "price_monthly"


async def test_checkout_refuses_an_unknown_plan(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/checkout", json={"plan": "lifetime"}, headers=headers)

    assert r.status_code == 422


async def test_checkout_sends_a_subscriber_to_the_portal_instead(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.billing_status = "active"
    await db.commit()
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/checkout", json={"plan": "monthly"}, headers=headers)

    assert r.status_code == 409
    assert r.json()["detail"] == "already_subscribed"
    assert stripe_gateway.checkouts == []


async def test_checkout_is_503_when_stripe_is_not_configured(client, db):
    # No stripe_gateway fixture: this is production with a missing key.
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/checkout", json={"plan": "monthly"}, headers=headers)

    assert r.status_code == 503
    assert r.json()["detail"] == "billing_unavailable"


async def test_status_still_works_without_stripe(client, db):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.get("/api/v1/billing", headers=headers)

    assert r.status_code == 200
    assert r.json()["entitled"] is True


async def test_portal_returns_a_url(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_existing"
    await db.commit()
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/portal", headers=headers)

    assert r.status_code == 200
    assert r.json()["url"] == "https://portal.stripe.test/session"
    assert stripe_gateway.portals == ["cus_existing"]


async def test_portal_refuses_someone_who_never_paid(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    headers = await helpers.auth_headers(user.id)

    r = await client.post("/api/v1/billing/portal", headers=headers)

    assert r.status_code == 409
    assert r.json()["detail"] == "no_billing_account"


async def test_billing_needs_a_session(client):
    assert (await client.get("/api/v1/billing")).status_code == 401
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd doqto_backend && venv/bin/python -m pytest tests/test_billing_endpoints.py -q`
Expected: FAIL, 404s, because the router does not exist.

- [ ] **Step 3: Add the route constants**

In `app/core/routes.py`, add to `ApiPrefix`:

```python
    BILLING = "/api/v1/billing"
```

and to `ApiRoutes`:

```python
    # Billing
    BILLING_STATUS = ""
    BILLING_CHECKOUT = "/checkout"
    BILLING_PORTAL = "/portal"
    BILLING_WEBHOOK = "/webhook"
```

- [ ] **Step 4: Write the schemas**

Create `app/schemas/billing.py`:

```python
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

Plan = Literal["monthly", "yearly"]


class BillingOut(BaseModel):
    entitled: bool
    reason: str
    trial_ends_at: datetime | None = None
    plan: Plan | None = None
    status: str | None = None
    current_period_end: datetime | None = None
    # Prices travel with the status so the app shows one truth and computes
    # the yearly saving instead of hard-coding it.
    monthly_cents: int
    yearly_cents: int


class CheckoutIn(BaseModel):
    plan: Plan = Field(description="Which recurring price to subscribe to.")


class UrlOut(BaseModel):
    url: str
```

- [ ] **Step 5: Write the endpoints**

Create `app/api/v1/billing.py`:

```python
"""Subscription status, checkout and the customer portal.

The app never talks to Stripe. It asks here, and opens whatever URL we hand
back in an external browser — which is also what Apple's link-out rule
requires.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.concurrency import run_in_threadpool
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.dependencies import get_current_user, get_db
from app.core.routes import ApiRoutes
from app.models import User
from app.schemas.billing import BillingOut, CheckoutIn, UrlOut
from app.services.billing_service import entitlement
from app.services.stripe_client import StripeGateway, get_stripe

logger = logging.getLogger(__name__)
router = APIRouter()

# Statuses that mean "already paying, or recoverable" — sending these users
# through checkout again would create a second subscription.
SUBSCRIBED_STATUSES = frozenset({"active", "trialing", "past_due"})


def _billing_out(user: User) -> BillingOut:
    decision = entitlement(user)
    return BillingOut(
        entitled=decision.entitled,
        reason=decision.reason,
        trial_ends_at=user.trial_ends_at,
        plan=user.billing_plan,
        status=user.billing_status,
        current_period_end=user.current_period_end,
        monthly_cents=settings.BILLING_PRICE_MONTHLY_CENTS,
        yearly_cents=settings.BILLING_PRICE_YEARLY_CENTS,
    )


@router.get(ApiRoutes.BILLING_STATUS, response_model=BillingOut)
async def billing_status(user: User = Depends(get_current_user)) -> BillingOut:
    return _billing_out(user)


@router.post(ApiRoutes.BILLING_CHECKOUT, response_model=UrlOut)
async def create_checkout(
    body: CheckoutIn,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    stripe: StripeGateway = Depends(get_stripe),
) -> UrlOut:
    if user.billing_status in SUBSCRIBED_STATUSES:
        raise HTTPException(status.HTTP_409_CONFLICT, detail="already_subscribed")

    price_id = (
        settings.STRIPE_PRICE_MONTHLY
        if body.plan == "monthly"
        else settings.STRIPE_PRICE_YEARLY
    )
    if not price_id:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE, detail="billing_unavailable"
        )

    customer_id = await run_in_threadpool(stripe.ensure_customer, user)
    if user.stripe_customer_id != customer_id:
        user.stripe_customer_id = customer_id
        await db.commit()

    url = await run_in_threadpool(
        lambda: stripe.checkout_url(
            customer_id=customer_id, price_id=price_id, user_id=str(user.id)
        )
    )
    logger.info("billing checkout user=%s plan=%s", user.id, body.plan)
    return UrlOut(url=url)


@router.post(ApiRoutes.BILLING_PORTAL, response_model=UrlOut)
async def create_portal(
    user: User = Depends(get_current_user),
    stripe: StripeGateway = Depends(get_stripe),
) -> UrlOut:
    if not user.stripe_customer_id:
        raise HTTPException(status.HTTP_409_CONFLICT, detail="no_billing_account")
    url = await run_in_threadpool(stripe.portal_url, user.stripe_customer_id)
    return UrlOut(url=url)
```

- [ ] **Step 6: Register the router**

In `main.py`, beside the other routers:

```python
app.include_router(billing.router, prefix=ApiPrefix.BILLING, tags=["billing"])
```

and add `billing` to the `from app.api.v1 import ...` list.

- [ ] **Step 7: Run the tests**

Run: `cd doqto_backend && venv/bin/python -m pytest tests/test_billing_endpoints.py -q`
Expected: 11 passed.

- [ ] **Step 8: Commit**

```bash
git add doqto_backend/app/api/v1/billing.py doqto_backend/app/schemas/billing.py doqto_backend/app/core/routes.py doqto_backend/main.py doqto_backend/tests/test_billing_endpoints.py
git commit -m "billing: status, checkout and portal endpoints"
```

---

### Task 5: The webhook

**Files:**
- Modify: `doqto_backend/app/api/v1/billing.py`
- Test: `doqto_backend/tests/test_billing_webhook.py`

**Interfaces:**
- Consumes: `StripeGateway.construct_event`, `StripeGateway.subscription` (Task 3).
- Produces: `POST /api/v1/billing/webhook`. Sets `billing_status`, `billing_plan`, `stripe_subscription_id`, `current_period_end`, `stripe_customer_id` on the matching user.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_billing_webhook.py`:

```python
"""Stripe's webhook is the only thing that may declare someone subscribed."""
from __future__ import annotations

from datetime import datetime, timezone

import pytest

from app.services.stripe_client import Subscription
from tests import helpers

pytestmark = pytest.mark.asyncio

PERIOD_END = datetime(2026, 10, 23, 12, 0, tzinfo=timezone.utc)


def _sub(status: str = "active", price: str = "price_yearly") -> Subscription:
    return Subscription(
        id="sub_1",
        customer_id="cus_fake0",
        status=status,
        price_id=price,
        current_period_end=PERIOD_END,
    )


async def _post(client) -> object:
    return await client.post(
        "/api/v1/billing/webhook",
        content=b"{}",
        headers={"stripe-signature": "t=1,v1=whatever"},
    )


async def test_checkout_completed_subscribes_the_user(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    stripe_gateway.subscriptions["sub_1"] = _sub()
    stripe_gateway.event = {
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "client_reference_id": str(user.id),
                "customer": "cus_fake0",
                "subscription": "sub_1",
            }
        },
    }

    r = await _post(client)

    assert r.status_code == 200
    await db.refresh(user)
    assert user.billing_status == "active"
    assert user.billing_plan == "yearly"
    assert user.stripe_subscription_id == "sub_1"
    assert user.stripe_customer_id == "cus_fake0"
    assert user.current_period_end == PERIOD_END


async def test_subscription_updated_is_matched_by_customer(client, db, stripe_gateway):
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_fake0"
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = _sub(status="past_due", price="price_monthly")
    stripe_gateway.event = {
        "type": "customer.subscription.updated",
        "data": {"object": {"id": "sub_1", "customer": "cus_fake0"}},
    }

    await _post(client)

    await db.refresh(user)
    assert user.billing_status == "past_due"
    assert user.billing_plan == "monthly"


async def test_a_stale_event_cannot_resurrect_a_cancelled_subscription(
    client, db, stripe_gateway
):
    # Stripe promises neither order nor exactly-once delivery. The handler
    # re-fetches, so whatever the event says, the truth wins.
    user = await helpers.create_user(db)
    user.stripe_customer_id = "cus_fake0"
    await db.commit()
    stripe_gateway.subscriptions["sub_1"] = _sub(status="canceled")
    stripe_gateway.event = {
        "type": "customer.subscription.updated",
        "data": {"object": {"id": "sub_1", "customer": "cus_fake0"}},
    }

    await _post(client)
    await _post(client)  # delivered twice, as Stripe does on retry

    await db.refresh(user)
    assert user.billing_status == "canceled"


async def test_a_forged_signature_is_refused(client, db, stripe_gateway):
    stripe_gateway.signature_valid = False

    r = await _post(client)

    assert r.status_code == 400


async def test_an_unknown_customer_is_accepted_and_ignored(client, db, stripe_gateway):
    stripe_gateway.subscriptions["sub_1"] = _sub()
    stripe_gateway.event = {
        "type": "customer.subscription.updated",
        "data": {"object": {"id": "sub_1", "customer": "cus_nobody"}},
    }

    r = await _post(client)

    # 200, or Stripe retries this for three days over a user we don't have.
    assert r.status_code == 200


async def test_an_uninteresting_event_is_ignored(client, db, stripe_gateway):
    stripe_gateway.event = {"type": "invoice.paid", "data": {"object": {}}}

    assert (await _post(client)).status_code == 200
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd doqto_backend && venv/bin/python -m pytest tests/test_billing_webhook.py -q`
Expected: FAIL with 404.

- [ ] **Step 3: Write the handler**

Append to `app/api/v1/billing.py`:

```python
SUBSCRIPTION_EVENTS = frozenset(
    {
        "customer.subscription.created",
        "customer.subscription.updated",
        "customer.subscription.deleted",
    }
)


def _plan_for(price_id: str | None) -> str | None:
    if price_id and price_id == settings.STRIPE_PRICE_MONTHLY:
        return "monthly"
    if price_id and price_id == settings.STRIPE_PRICE_YEARLY:
        return "yearly"
    return None


@router.post(ApiRoutes.BILLING_WEBHOOK)
async def webhook(
    request: Request,
    db: AsyncSession = Depends(get_db),
    stripe: StripeGateway = Depends(get_stripe),
) -> dict[str, bool]:
    payload = await request.body()
    signature = request.headers.get("stripe-signature", "")
    try:
        event = stripe.construct_event(payload, signature)
    except Exception:
        # Never log the payload: it is unverified input.
        logger.warning("billing webhook rejected: bad signature")
        raise HTTPException(status.HTTP_400_BAD_REQUEST, detail="bad_signature")

    event_type = event.get("type", "")
    obj = event.get("data", {}).get("object", {})

    if event_type == "checkout.session.completed":
        user = await db.scalar(
            select(User).where(User.id == uuid.UUID(obj["client_reference_id"]))
        )
        subscription_id = obj.get("subscription")
    elif event_type in SUBSCRIPTION_EVENTS:
        user = await db.scalar(
            select(User).where(User.stripe_customer_id == obj.get("customer"))
        )
        subscription_id = obj.get("id")
    else:
        return {"ok": True}

    if user is None or not subscription_id:
        # 200 anyway: Stripe retries for three days, and there is nothing to
        # retry for a customer we do not have.
        logger.warning("billing webhook %s for an unknown user", event_type)
        return {"ok": True}

    # Re-fetch rather than trust the event body: events arrive out of order
    # and more than once, and the current subscription is the only truth.
    sub = await run_in_threadpool(stripe.subscription, subscription_id)
    user.stripe_customer_id = sub.customer_id
    user.stripe_subscription_id = sub.id
    user.billing_status = sub.status
    user.billing_plan = _plan_for(sub.price_id)
    user.current_period_end = sub.current_period_end
    await db.commit()
    logger.info("billing %s user=%s status=%s", event_type, user.id, sub.status)
    return {"ok": True}
```

Add the imports this needs at the top of the file: `import uuid`, `from fastapi import Request`, `from sqlalchemy import select`.

- [ ] **Step 4: Run the tests**

Run: `cd doqto_backend && venv/bin/python -m pytest tests/test_billing_webhook.py -q`
Expected: 6 passed.

- [ ] **Step 5: Commit**

```bash
git add doqto_backend/app/api/v1/billing.py doqto_backend/tests/test_billing_webhook.py
git commit -m "billing: Stripe webhook mirrors subscriptions onto the user"
```

---

### Task 6: The 402 wall

**Files:**
- Modify: `doqto_backend/app/core/dependencies.py`
- Modify: `doqto_backend/app/api/v1/conversations.py`
- Modify: `doqto_backend/app/api/v1/messages.py`
- Modify: `doqto_backend/app/api/v1/groups.py`
- Test: `doqto_backend/tests/test_billing_gating.py`

**Interfaces:**
- Consumes: `entitlement` (Task 2).
- Produces: `require_entitled(user: User = Depends(get_current_user)) -> User`, raising 402 `subscription_required`.

- [ ] **Step 1: Find every send path**

Run:
```bash
cd doqto_backend && grep -rn "@router.post\|@router.websocket" app/api | grep -v admin
```
Read the list. The gate goes on: conversation create, conversation message send, scheduled message create, message upload, voice note, group create. If a websocket path can create a message, gate it too by calling `entitlement` at the point the message is accepted, and add a test for it in this task. Record what you found in the commit message.

- [ ] **Step 2: Write the failing tests**

Create `tests/test_billing_gating.py`:

```python
"""An expired doctor can read, but cannot send."""
from __future__ import annotations

import pytest

from tests import helpers

pytestmark = pytest.mark.asyncio


async def _expire(db, user) -> None:
    user.trial_ends_at = None
    user.billing_status = None
    await db.commit()


async def test_sending_needs_a_subscription(client, db, chat):
    await _expire(db, chat.alice)

    r = await client.post(
        f"/api/v1/conversations/{chat.conv.id}/messages",
        json={"content": "are you there"},
        headers=chat.alice_headers,
    )

    assert r.status_code == 402
    assert r.json()["detail"] == "subscription_required"


async def test_starting_a_conversation_needs_a_subscription(client, db, chat):
    await _expire(db, chat.alice)

    r = await client.post(
        "/api/v1/conversations",
        json={"type": "direct", "member_ids": [str(chat.bob.id)]},
        headers=chat.alice_headers,
    )

    assert r.status_code == 402


async def test_reading_always_works(client, db, chat):
    await _expire(db, chat.alice)

    r = await client.get(
        f"/api/v1/conversations/{chat.conv.id}/messages", headers=chat.alice_headers
    )

    # Nothing is ever held hostage: the history stays readable.
    assert r.status_code == 200


async def test_the_profile_stays_editable(client, db, chat):
    await _expire(db, chat.alice)

    r = await client.get("/api/v1/users/me", headers=chat.alice_headers)

    assert r.status_code == 200


async def test_a_doctor_in_their_trial_can_send(client, chat):
    # The default test user: proves the gate doesn't break every other suite.
    r = await client.post(
        f"/api/v1/conversations/{chat.conv.id}/messages",
        json={"content": "hello"},
        headers=chat.alice_headers,
    )

    assert r.status_code == 200
```

- [ ] **Step 3: Run them and watch the 402 ones fail**

Run: `cd doqto_backend && venv/bin/python -m pytest tests/test_billing_gating.py -q`
Expected: the two 402 tests FAIL with 200; the others pass.

- [ ] **Step 4: Write the dependency**

In `app/core/dependencies.py`, after `require_super_admin`:

```python
async def require_entitled(user: User = Depends(get_current_user)) -> User:
    """Trial running, subscription live, or inside the grace period.

    402 rather than 403: this is about payment, and the app turns it into the
    paywall rather than an error message.
    """
    if not entitlement(user).entitled:
        raise HTTPException(
            status.HTTP_402_PAYMENT_REQUIRED, detail="subscription_required"
        )
    return user
```

Add `from app.services.billing_service import entitlement` to the imports.

- [ ] **Step 5: Put the gate on the send paths**

In each endpoint listed in Step 1, replace the dependency line

```python
    user: User = Depends(get_current_user),
```

with

```python
    user: User = Depends(require_entitled),
```

and import `require_entitled` alongside `get_current_user` in that module. Do this only for: `create_conversation`, `send_message`, the scheduled-message POST, `messages.upload`, `messages.voice_notes`, and group create. Leave every GET, read receipt, hide, profile and account endpoint alone.

- [ ] **Step 6: Run the tests**

Run: `cd doqto_backend && venv/bin/python -m pytest tests/test_billing_gating.py -q`
Expected: 5 passed.

- [ ] **Step 7: Run the whole suite**

Run: `cd doqto_backend && venv/bin/python -m pytest -q`
Expected: all green. If a suite fails because its user has no trial, fix that test's setup rather than weakening the gate.

- [ ] **Step 8: Commit**

```bash
git add doqto_backend/app/core/dependencies.py doqto_backend/app/api/v1 doqto_backend/tests/test_billing_gating.py
git commit -m "billing: 402 on sending once the trial and subscription lapse"
```

---

### Task 7: The app talks to billing

**Files:**
- Create: `doqto_app/lib/data/models/billing.dart`
- Create: `doqto_app/lib/data/repositories/billing_repository.dart`
- Create: `doqto_app/lib/data/services/url_opener.dart`
- Modify: `doqto_app/lib/core/constants/api_routes.dart`
- Modify: `doqto_app/lib/core/di/providers.dart`
- Modify: `doqto_app/lib/core/utils/error_messages.dart`
- Test: `doqto_app/test/billing_test.dart`

**Interfaces:**
- Consumes: the endpoints from Tasks 4 and 5.
- Produces: `Billing` with `entitled`, `reason`, `trialEndsAt`, `plan`, `status`, `currentPeriodEnd`, `monthlyCents`, `yearlyCents`, plus `trialDaysLeft` and `yearlySavingPercent`. `BillingRepository.status()`, `.checkoutUrl(String plan)`, `.portalUrl()`. `UrlOpener.open(String url) -> Future<bool>` and `FakeUrlOpener`. Providers `billingRepositoryProvider`, `urlOpenerProvider`.

- [ ] **Step 1: Write the failing test**

Create `doqto_app/test/billing_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/data/models/billing.dart';

void main() {
  Map<String, dynamic> json({
    bool entitled = true,
    String reason = 'trial',
    String? trialEndsAt,
    int monthly = 899,
    int yearly = 8000,
  }) => {
        'entitled': entitled,
        'reason': reason,
        'trial_ends_at': trialEndsAt,
        'plan': null,
        'status': null,
        'current_period_end': null,
        'monthly_cents': monthly,
        'yearly_cents': yearly,
      };

  test('reads the server payload', () {
    final b = Billing.fromJson(json(trialEndsAt: '2026-10-07T12:00:00Z'));

    expect(b.entitled, isTrue);
    expect(b.reason, 'trial');
    expect(b.trialEndsAt, DateTime.utc(2026, 10, 7, 12));
  });

  test('computes the yearly saving from the prices, not from copy', () {
    // 12 x $8.99 = $107.88 against $80 is 25.8%, which reads as 26%.
    expect(Billing.fromJson(json()).yearlySavingPercent, 26);
  });

  test('a cheaper monthly price moves the saving', () {
    expect(
      Billing.fromJson(json(monthly: 1000, yearly: 6000)).yearlySavingPercent,
      50,
    );
  });

  test('days left rounds up, so the last day still reads as one', () {
    final b = Billing.fromJson(json(
      trialEndsAt: DateTime.now().toUtc().add(const Duration(hours: 5)).toIso8601String(),
    ));

    expect(b.trialDaysLeft, 1);
  });

  test('an expired trial has no days left', () {
    final b = Billing.fromJson(json(
      entitled: false,
      reason: 'expired',
      trialEndsAt: DateTime.now().toUtc().subtract(const Duration(days: 1)).toIso8601String(),
    ));

    expect(b.trialDaysLeft, 0);
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd doqto_app && flutter test test/billing_test.dart`
Expected: FAIL, `Target of URI doesn't exist: 'package:doqto_app/data/models/billing.dart'`.

- [ ] **Step 3: Write the model**

Create `lib/data/models/billing.dart`:

```dart
/// What the backend says about this doctor's subscription.
///
/// Prices come down with the status so the yearly saving is computed from what
/// Stripe actually charges. Typing the discount into the UI is how a price
/// change silently turns the copy into a lie.
class Billing {
  final bool entitled;

  /// `staff`, `trial`, `subscribed`, `grace` or `expired`.
  final String reason;
  final DateTime? trialEndsAt;
  final String? plan;
  final String? status;
  final DateTime? currentPeriodEnd;
  final int monthlyCents;
  final int yearlyCents;

  const Billing({
    required this.entitled,
    required this.reason,
    required this.monthlyCents,
    required this.yearlyCents,
    this.trialEndsAt,
    this.plan,
    this.status,
    this.currentPeriodEnd,
  });

  factory Billing.fromJson(Map<String, dynamic> j) => Billing(
        entitled: j['entitled'] as bool,
        reason: (j['reason'] ?? 'expired') as String,
        trialEndsAt: DateTime.tryParse((j['trial_ends_at'] ?? '') as String)?.toUtc(),
        plan: j['plan'] as String?,
        status: j['status'] as String?,
        currentPeriodEnd:
            DateTime.tryParse((j['current_period_end'] ?? '') as String)?.toUtc(),
        monthlyCents: (j['monthly_cents'] ?? 0) as int,
        yearlyCents: (j['yearly_cents'] ?? 0) as int,
      );

  /// Whole days remaining, rounded up: a trial with five hours left still has
  /// "1 day", never "0 days" while it works.
  int get trialDaysLeft {
    final end = trialEndsAt;
    if (end == null) return 0;
    final left = end.difference(DateTime.now().toUtc());
    return left.isNegative ? 0 : (left.inMinutes / (60 * 24)).ceil();
  }

  /// Percent saved by paying yearly, against twelve monthly payments.
  int get yearlySavingPercent {
    final year = monthlyCents * 12;
    if (year <= 0 || yearlyCents <= 0) return 0;
    return ((year - yearlyCents) / year * 100).round();
  }

  String get monthlyLabel => '\$${(monthlyCents / 100).toStringAsFixed(2)}/mo';
  String get yearlyLabel => '\$${(yearlyCents / 100).toStringAsFixed(0)}/yr';

  /// "$6.67/mo" — the yearly price spread over twelve months.
  String get yearlyPerMonthLabel =>
      '\$${(yearlyCents / 12 / 100).toStringAsFixed(2)}/mo';
}
```

- [ ] **Step 4: Run the test**

Run: `cd doqto_app && flutter test test/billing_test.dart`
Expected: 5 passed.

- [ ] **Step 5: Add the routes, repository, opener and providers**

In `lib/core/constants/api_routes.dart`:

```dart
  static const String billing = '$apiV1/billing';
  static const String billingCheckout = '$apiV1/billing/checkout';
  static const String billingPortal = '$apiV1/billing/portal';
```

Create `lib/data/repositories/billing_repository.dart`:

```dart
import '../api/api_client.dart';
import '../models/billing.dart';
import '../../core/constants/api_routes.dart';

class BillingRepository {
  final ApiClient _api;
  BillingRepository(this._api);

  Future<Billing> status() async =>
      Billing.fromJson(await _api.get(ApiRoutes.billing));

  /// A Stripe Checkout URL. Opens in the browser, never in a web view.
  Future<String> checkoutUrl(String plan) async {
    final res = await _api.post(ApiRoutes.billingCheckout, {'plan': plan});
    return res['url'] as String;
  }

  /// Stripe's hosted portal: cancel, switch plan, change card.
  Future<String> portalUrl() async {
    final res = await _api.post(ApiRoutes.billingPortal, {});
    return res['url'] as String;
  }
}
```

Match the exact `_api.get` / `_api.post` signatures used by `lib/data/repositories/user_repository.dart`; read that file first and follow it.

Create `lib/data/services/url_opener.dart`:

```dart
import 'package:url_launcher/url_launcher.dart';

/// Opens a URL outside the app. An interface, so widget tests never launch a
/// real browser.
abstract class UrlOpener {
  Future<bool> open(String url);
}

class ExternalUrlOpener implements UrlOpener {
  const ExternalUrlOpener();

  @override
  Future<bool> open(String url) => launchUrl(
        Uri.parse(url),
        // externalApplication, not an in-app web view: Apple's link-out rule
        // for web payments requires the real browser.
        mode: LaunchMode.externalApplication,
      );
}

class FakeUrlOpener implements UrlOpener {
  final List<String> opened = [];
  bool result = true;

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return result;
  }
}
```

In `lib/core/di/providers.dart`:

```dart
final billingRepositoryProvider = Provider<BillingRepository>(
  (ref) => BillingRepository(ref.read(apiClientProvider)),
);
final urlOpenerProvider = Provider<UrlOpener>((ref) => const ExternalUrlOpener());
```

In `lib/core/utils/error_messages.dart`, add to the code map:

```dart
    'subscription_required':
        'Your free trial has ended. Subscribe to keep sending messages.',
    'already_subscribed': 'You already have a subscription. Manage it in Settings.',
    'no_billing_account': 'There is no subscription to manage yet.',
    'billing_unavailable':
        'Payments are temporarily unavailable. Please try again shortly.',
```

- [ ] **Step 6: Check it compiles and the suite is clean**

Run: `cd doqto_app && flutter analyze lib test && flutter test`
Expected: no issues, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add doqto_app/lib doqto_app/test/billing_test.dart
git commit -m "app: billing model, repository and external URL opener"
```

---

### Task 8: The paywall

**Files:**
- Create: `doqto_app/lib/state/billing_state.dart`
- Modify: `doqto_app/lib/state/auth_state.dart`
- Modify: `doqto_app/lib/core/router/app_router.dart`
- Modify: `doqto_app/lib/ui/screens/payments/payments_screen.dart`
- Modify: `doqto_app/lib/core/constants/strings.dart`
- Test: `doqto_app/test/widgets/paywall_test.dart`

**Interfaces:**
- Consumes: `Billing`, `BillingRepository`, `UrlOpener` (Task 7).
- Produces: `billingProvider` (`AsyncValue<Billing?>`) with `refresh()` and `pollAfterCheckout()`. `AuthStage.needsSubscription`. `AppRoutes.paywall = '/paywall'`. `PaymentsScreen({PaymentsMode mode})` with `PaymentsMode.onboarding` and `PaymentsMode.paywall`.

- [ ] **Step 1: Write the failing tests**

Create `doqto_app/test/widgets/paywall_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/billing.dart';
import 'package:doqto_app/data/repositories/billing_repository.dart';
import 'package:doqto_app/data/services/url_opener.dart';
import 'package:doqto_app/ui/screens/payments/payments_screen.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

class _FakeBilling extends BillingRepository {
  _FakeBilling() : super(ApiClient());
  final List<String> checkouts = [];
  Object? checkoutError;
  Billing value = const Billing(
    entitled: false,
    reason: 'expired',
    monthlyCents: 899,
    yearlyCents: 8000,
  );

  @override
  Future<Billing> status() async => value;

  @override
  Future<String> checkoutUrl(String plan) async {
    if (checkoutError != null) throw checkoutError!;
    checkouts.add(plan);
    return 'https://checkout.stripe.test/$plan';
  }

  @override
  Future<String> portalUrl() async => 'https://portal.stripe.test/s';
}

void main() {
  late _FakeBilling billing;
  late FakeUrlOpener opener;

  setUp(() {
    billing = _FakeBilling();
    opener = FakeUrlOpener();
  });

  Future<void> pump(WidgetTester tester, {PaymentsMode mode = PaymentsMode.paywall}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        billingRepositoryProvider.overrideWithValue(billing),
        urlOpenerProvider.overrideWithValue(opener),
      ],
      child: MaterialApp(home: PaymentsScreen(mode: mode)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the paywall explains itself and offers both plans', (tester) async {
    await pump(tester);

    expect(find.text(Strings.paywallTitle), findsOneWidget);
    // Nothing is held hostage, and the screen says so.
    expect(find.textContaining('still readable'), findsOneWidget);
    expect(find.text(Strings.planMonthly), findsOneWidget);
    expect(find.text(Strings.planYearly), findsOneWidget);
  });

  testWidgets('prices and the saving come from the server', (tester) async {
    billing.value = const Billing(
      entitled: false,
      reason: 'expired',
      monthlyCents: 1000,
      yearlyCents: 6000,
    );
    await pump(tester);

    expect(find.text('\$10.00/mo'), findsOneWidget);
    expect(find.text('\$60/yr'), findsOneWidget);
    expect(find.textContaining('50%'), findsOneWidget);
  });

  testWidgets('Subscribe opens Stripe in the browser for the chosen plan',
      (tester) async {
    await pump(tester);

    await tester.tap(find.widgetWithText(AppButton, Strings.planSubscribe).first);
    await tester.pumpAndSettle();

    // Yearly is preselected.
    expect(billing.checkouts, ['yearly']);
    expect(opener.opened, ['https://checkout.stripe.test/yearly']);
  });

  testWidgets('a checkout failure is explained, not swallowed', (tester) async {
    billing.checkoutError = ApiException('billing_unavailable', status: 503);
    await pump(tester);

    await tester.tap(find.widgetWithText(AppButton, Strings.planSubscribe).first);
    await tester.pumpAndSettle();

    expect(find.textContaining('temporarily unavailable'), findsOneWidget);
    expect(opener.opened, isEmpty);
  });

  testWidgets('the paywall has no way to skip', (tester) async {
    await pump(tester);

    expect(find.text(Strings.planSkip), findsNothing);
  });

  testWidgets('onboarding keeps the free trial and the skip', (tester) async {
    await pump(tester, mode: PaymentsMode.onboarding);

    expect(find.text(Strings.planStartTrial), findsOneWidget);
    expect(find.text(Strings.planSkip), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd doqto_app && flutter test test/widgets/paywall_test.dart`
Expected: FAIL, `PaymentsMode` is undefined.

- [ ] **Step 3: Add the copy**

In `lib/core/constants/strings.dart`, beside the other plan strings:

```dart
  static const String planStartTrial = 'Start 14-day free trial';
  static const String planSubscribe = 'Subscribe';
  static const String paywallTitle = 'Subscribe to keep going';
  static const String paywallBody =
      'Your free trial has ended. Your messages are safe and still readable — '
      'subscribing turns sending back on.';
  static const String paywallPaid = 'I have already paid';
  static const String subscriptionRow = 'Subscription';
  static String planSaving(int percent, String perMonth) =>
      'Save $percent% · $perMonth';
  static String trialDaysLeft(int days) =>
      days == 1 ? 'Trial: 1 day left' : 'Trial: $days days left';
```

Delete `planYearlyNote`, `planMonthlyPrice` and `planYearlyPrice`, which the server now supplies, and fix the references the analyzer reports.

- [ ] **Step 4: Write the billing state**

Create `lib/state/billing_state.dart`:

```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../data/models/billing.dart';

/// The app's cached view of the subscription. Null means "not asked yet, or
/// the server could not be reached" — never "expired". Only the server
/// decides that.
class BillingNotifier extends AsyncNotifier<Billing?> {
  @override
  Future<Billing?> build() => _fetch();

  Future<Billing?> _fetch() async {
    try {
      return await ref.read(billingRepositoryProvider).status();
    } catch (_) {
      return null;
    }
  }

  Future<Billing?> refresh() async {
    final value = await _fetch();
    state = AsyncValue.data(value);
    return value;
  }

  /// Stripe's webhook can land a few seconds after the browser sends the
  /// doctor back. Poll briefly rather than show them a stale paywall.
  Future<Billing?> pollAfterCheckout() async {
    for (var i = 0; i < 10; i++) {
      final value = await refresh();
      if (value?.entitled == true) return value;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return state.value;
  }
}

final billingProvider =
    AsyncNotifierProvider<BillingNotifier, Billing?>(BillingNotifier.new);
```

- [ ] **Step 5: Add the stage and the route**

In `lib/state/auth_state.dart`: add `needsSubscription` to `AuthStage` after `needsPayment`, with a comment saying the server decides it. At the top of `_resolveStageForRegisteredUser`, before the orgs call:

```dart
    // The server is the authority. A failed check lets the user in: the
    // endpoints still return 402, so failing open costs nothing and avoids
    // locking someone out over a flaky network.
    final billing = await ref.read(billingProvider.notifier).refresh();
    if (billing != null && !billing.entitled) return AuthStage.needsSubscription;
```

In `lib/core/router/app_router.dart`: add `static const paywall = '/paywall';`, a `GoRoute` for it rendering `const PaymentsScreen(mode: PaymentsMode.paywall)`, and in `redirect`, after the `needsPayment` branch:

```dart
      if (auth.stage == AuthStage.needsSubscription && loc != AppRoutes.paywall) {
        return AppRoutes.paywall;
      }
```

- [ ] **Step 6: Give the screen two modes**

In `payments_screen.dart`:

```dart
enum PaymentsMode {
  /// Straight after registration: start the trial, or subscribe now.
  onboarding,

  /// The trial is over. No way past this screen except paying.
  paywall,
}
```

Take `final PaymentsMode mode;` as a constructor parameter, defaulting to `PaymentsMode.onboarding`. Then:

- Read `billingProvider` for the prices. Build the two plan rows from `Billing.monthlyLabel`, `yearlyLabel` and `planSaving(b.yearlySavingPercent, b.yearlyPerMonthLabel)`. While billing is loading or null, fall back to `$8.99/mo` and `$80/yr` with a 26% saving so the screen is never empty.
- `PaymentsMode.paywall`: title `Strings.paywallTitle`, body `Strings.paywallBody`, primary button `Strings.planSubscribe`, a text button `Strings.paywallPaid` calling `pollAfterCheckout()` then re-resolving the stage, and a sign-out text button. No skip, no trial button, and no back arrow: `automaticallyImplyLeading: false`.
- `PaymentsMode.onboarding`: title `Strings.planTitle`, primary button `Strings.planStartTrial` calling the existing `_leave()`, secondary button `Strings.planSubscribe`, and the existing skip.
- Subscribe calls `checkoutUrl(_selected)`, then `ref.read(urlOpenerProvider).open(url)`. On `ApiException`, show `ErrorMessages.forApi(e)` in the existing inline error. After a successful open, call `pollAfterCheckout()`.

- [ ] **Step 7: Run the tests**

Run: `cd doqto_app && flutter test test/widgets/paywall_test.dart`
Expected: 6 passed.

- [ ] **Step 8: Run everything and look at it**

Run: `cd doqto_app && flutter analyze lib test && flutter test`
Expected: clean, all green. Then render the paywall to a PNG with the throwaway golden-test technique in `~/.claude` memory `local-dev-environment` (simulator builds are broken on Xcode 27) and check the layout at phone width.

- [ ] **Step 9: Commit**

```bash
git add doqto_app/lib doqto_app/test/widgets/paywall_test.dart
git commit -m "app: paywall screen, subscription stage and Stripe checkout"
```

---

### Task 9: Settings, foreground refresh and the 402 handler

**Files:**
- Modify: `doqto_app/lib/ui/screens/settings/settings_screen.dart`
- Modify: `doqto_app/lib/main.dart`
- Modify: `doqto_app/lib/core/di/providers.dart`
- Modify: `doqto_app/lib/data/api/api_client.dart`
- Test: `doqto_app/test/widgets/paywall_test.dart`

**Interfaces:**
- Consumes: `billingProvider`, `urlOpenerProvider` (Tasks 7 and 8).
- Produces: a Subscription row in Settings; a billing re-check on resume; `ApiClient.onPaymentRequired` callback.

- [ ] **Step 1: Write the failing tests**

Append to `test/widgets/paywall_test.dart`:

```dart
  testWidgets('settings shows the trial countdown', (tester) async {
    billing.value = Billing(
      entitled: true,
      reason: 'trial',
      monthlyCents: 899,
      yearlyCents: 8000,
      trialEndsAt: DateTime.now().toUtc().add(const Duration(days: 3, hours: 2)),
    );
    await pumpSettings(tester);

    expect(find.text(Strings.subscriptionRow), findsOneWidget);
    expect(find.text(Strings.trialDaysLeft(4)), findsOneWidget);
  });

  testWidgets('settings opens the Stripe portal for a subscriber',
      (tester) async {
    billing.value = const Billing(
      entitled: true,
      reason: 'subscribed',
      status: 'active',
      plan: 'yearly',
      monthlyCents: 899,
      yearlyCents: 8000,
    );
    await pumpSettings(tester);

    await tester.tap(find.text(Strings.subscriptionRow));
    await tester.pumpAndSettle();

    expect(opener.opened, ['https://portal.stripe.test/s']);
  });
```

Write `pumpSettings` beside `pump`, following the existing overrides in `test/widgets/settings_screen_test.dart` if one exists, plus the two billing overrides.

- [ ] **Step 2: Run them and watch them fail**

Run: `cd doqto_app && flutter test test/widgets/paywall_test.dart`
Expected: FAIL, the Subscription row is not found.

- [ ] **Step 3: Add the Settings row**

In `settings_screen.dart`, after the Specialty row:

```dart
          FadeSlideIn.staggered(
            4,
            Consumer(builder: (context, ref, _) {
              final billing = ref.watch(billingProvider).value;
              return ListTile(
                title: const Text(Strings.subscriptionRow),
                subtitle: Text(switch (billing?.reason) {
                  'trial' => Strings.trialDaysLeft(billing!.trialDaysLeft),
                  'subscribed' => billing!.plan == 'yearly' ? 'Yearly' : 'Monthly',
                  'grace' => 'Payment problem — update your card',
                  'staff' => 'Staff account',
                  'expired' => 'No subscription',
                  _ => '—',
                }),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _openBilling(context, ref, billing),
              );
            }),
          ),
```

and the handler, which sends someone with no Stripe customer to checkout instead of a portal that would 409:

```dart
  Future<void> _openBilling(BuildContext context, WidgetRef ref, Billing? billing) async {
    final repo = ref.read(billingRepositoryProvider);
    try {
      final url = billing?.status == null
          ? await repo.checkoutUrl('yearly')
          : await repo.portalUrl();
      await ref.read(urlOpenerProvider).open(url);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
      }
    }
  }
```

Renumber the `FadeSlideIn.staggered` indices below it.

- [ ] **Step 4: Re-check billing when the app comes back**

In `lib/main.dart`, wrap the app's root widget so returning from the browser refreshes the status. Read the file first and follow its existing structure:

```dart
/// Stripe Checkout happens in the browser, so the only reliable signal that
/// something may have changed is the app coming back to the foreground.
class BillingRefresher extends ConsumerStatefulWidget {
  final Widget child;
  const BillingRefresher({super.key, required this.child});

  @override
  ConsumerState<BillingRefresher> createState() => _BillingRefresherState();
}

class _BillingRefresherState extends ConsumerState<BillingRefresher>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(authProvider.notifier).refreshBilling());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
```

Add `AuthNotifier.refreshBilling()` in `auth_state.dart`: refresh `billingProvider`, and if the answer flips entitlement, re-resolve the stage so the router moves the user on or off the paywall.

- [ ] **Step 5: Turn a 402 into the paywall**

In `lib/data/api/api_client.dart`, add an optional `void Function()? onPaymentRequired` field, and call it in the error path when `e.response?.statusCode == 402`. In `providers.dart`, pass `onPaymentRequired: () => ref.read(authProvider.notifier).refreshBilling()` when constructing the client.

- [ ] **Step 6: Run the tests**

Run: `cd doqto_app && flutter test test/widgets/paywall_test.dart`
Expected: 8 passed.

- [ ] **Step 7: Run everything**

Run: `cd doqto_app && flutter analyze lib test && flutter test`
Expected: clean and green.

- [ ] **Step 8: Commit**

```bash
git add doqto_app/lib doqto_app/test
git commit -m "app: subscription row in settings, resume refresh, 402 to paywall"
```

---

### Task 10: Infra and the return page

**Files:**
- Modify: `infra/backend/main.tf`
- Create: `landing/src/app/billing/done/page.tsx`
- Modify: `docs/payments.md`

**Interfaces:**
- Consumes: the settings names from Task 2.
- Produces: `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` as SSM secrets; `STRIPE_PRICE_MONTHLY`, `STRIPE_PRICE_YEARLY` and `BILLING_RETURN_URL` as task environment values; `https://doqto.ai/billing/done`.

- [ ] **Step 1: Add the secrets and env to Terraform**

In `infra/backend/main.tf`, follow the existing secret pattern (the one `FCM_SERVICE_ACCOUNT_JSON` uses) and add `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`, each fed from a new variable:

```hcl
variable "stripe_secret_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "stripe_webhook_secret" {
  type      = string
  sensitive = true
  default   = ""
}
```

Add to the container environment list, beside `FIREBASE_PROJECT_ID`:

```hcl
        { name = "STRIPE_PRICE_MONTHLY", value = var.stripe_price_monthly },
        { name = "STRIPE_PRICE_YEARLY", value = var.stripe_price_yearly },
        { name = "BILLING_RETURN_URL", value = "https://doqto.ai/billing/done" },
```

with matching non-sensitive variables for the two price ids.

- [ ] **Step 2: Check the plan is only what you expect**

Run: `cd infra/backend && terraform plan -no-color | grep -E "^Plan:|Error"`
Expected: a task-definition change and two new SSM parameters. Nothing destroyed. Do not apply: deploys run from `deploy.sh` and are the user's to run.

- [ ] **Step 3: Write the return page**

Create `landing/src/app/billing/done/page.tsx`, following the styling of `landing/src/app/delete-account/page.tsx`:

```tsx
'use client';

import { useEffect, useState } from 'react';

// Stripe sends people here after checkout. The app can't be told directly, so
// this page bounces them back into it; the app re-checks billing on resume.
export default function BillingDone() {
  const [cancelled, setCancelled] = useState(false);

  useEffect(() => {
    const status = new URLSearchParams(window.location.search).get('status');
    setCancelled(status === 'cancel');
    if (status !== 'cancel') window.location.href = 'doqto:///billing';
  }, []);

  return (
    <main>
      <h1>{cancelled ? 'Checkout cancelled' : 'Payment received'}</h1>
      <p>
        {cancelled
          ? 'Nothing was charged. You can subscribe any time from the app.'
          : 'Thank you. Your subscription is active — open Doqto to continue.'}
      </p>
      <a href="doqto:///billing">Open Doqto</a>
    </main>
  );
}
```

- [ ] **Step 4: Build the landing site**

Run: `cd landing && npm run build`
Expected: the static export succeeds and `out/billing/done/index.html` exists.

- [ ] **Step 5: Rewrite the payments doc**

Replace `docs/payments.md` with what is now true: the plan picker charges, the trial is 14 days in `users.trial_ends_at`, Stripe Checkout runs in the browser, the webhook is the source of truth, sending is gated at 402, and the portal handles cancellation. Keep the App Store reasoning, and update it to say the link-out is allowed on the US storefront rather than that billing is deferred.

- [ ] **Step 6: Commit**

```bash
git add infra/backend/main.tf landing/src/app/billing docs/payments.md
git commit -m "billing: Stripe secrets in terraform, checkout return page, docs"
```

---

### Task 11: Wire up Stripe and verify end to end

This task is manual and shared with the user. It has no code and no commit until Step 7.

- [ ] **Step 1: The user creates the product**

In Stripe **test mode**: product "Doqto", two recurring USD prices, $8.99 monthly and $80 yearly. They send you the two price ids (`price_...`), which are not secret.

- [ ] **Step 2: The user adds the keys**

They put the test secret key and, after Step 3, the webhook signing secret into `infra/backend/terraform.tfvars`, which is gitignored:

```hcl
stripe_secret_key     = "sk_test_..."
stripe_webhook_secret = "whsec_..."
stripe_price_monthly  = "price_..."
stripe_price_yearly   = "price_..."
```

- [ ] **Step 3: Create the webhook endpoint**

In the Stripe dashboard, add the endpoint `https://api.doqto.ai/api/v1/billing/webhook` subscribed to exactly `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated` and `customer.subscription.deleted`. Copy its signing secret into the tfvars above.

- [ ] **Step 4: Configure the Customer Portal**

Turn on cancel at period end, switching between the two prices, and updating the payment method.

- [ ] **Step 5: The user deploys**

```bash
TF_CLI_ARGS_apply=-auto-approve ./infra/backend/deploy.sh
```

Then confirm the migration ran and the service is healthy:

```bash
AWS_PROFILE=loki-doqto AWS_REGION=us-east-1 aws logs tail /ecs/doqto-backend --since 5m --format short | grep -iE "alembic|0023|startup"
curl -s -o /dev/null -w "%{http_code}\n" https://api.doqto.ai/api/v1/billing
```

Expected: `0023_billing` applied, and 401 from the billing endpoint without a token.

- [ ] **Step 6: Walk the flow on a TestFlight build**

Cut a build, then check each of these on the device:

1. A brand-new account lands on the plan picker and "Start 14-day free trial" gets into the app.
2. Settings shows "Trial: 14 days left".
3. Subscribe opens Safari on Stripe Checkout. Pay with `4242 4242 4242 4242`, any future expiry, any CVC.
4. Returning to the app shows the subscription within a few seconds, and Settings reads "Yearly".
5. In Stripe, cancel the subscription immediately. The webhook lands, and after a foreground refresh the app shows the paywall.
6. On the paywall, reading old messages still works and sending shows the subscription message.
7. The App Review demo account (+1 650 555 0199) never sees the paywall.

Record anything that differs and fix it before going further.

- [ ] **Step 7: Update the memory file and go live**

Add a memory note under `~/.claude/projects/.../memory/` describing: Stripe project, price ids, which environment is live, where the keys live, and the webhook endpoint. Then the user activates the Stripe account, swaps the live keys and price ids into tfvars, redeploys, and repeats Step 6's first three checks with a real card.

```bash
git add docs
git commit -m "billing: verified end to end in Stripe test mode"
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: data and migration (1), entitlement (2), Stripe wrapper (3), three endpoints (4), webhook (5), 402 gating (6), app model and repository (7), stage, paywall and checkout (8), settings, resume and 402 handling (9), infra, return page and docs (10), Stripe dashboard and end-to-end verification (11).

**Two deliberate departures from the spec, both simplifications:**

1. **Prices come from our own config, not from a Stripe API call.** The spec said `GET /billing` returns both prices; it does, from `BILLING_PRICE_*_CENTS`. Fetching them from Stripe on every status call would add a network hop to the most-called billing endpoint for a number that changes once a year. The risk is the config drifting from Stripe, which Task 11 Step 6 checks by eye.

2. **No deep-link handler for `doqto:///billing`.** The spec described the return page sending the user back through that link. The link still opens the app, but the app does not parse it: the resume refresh in Task 9 covers every return path, including the user switching back by hand. Adding a link handler would mean a new package and platform configuration on both platforms for no extra behaviour.

**Placeholders:** none. Every code step carries the code.

**Type consistency:** `Entitlement(entitled, reason)` is used the same way in Tasks 2, 4 and 6. `Subscription` fields match between the wrapper, the fake and the webhook. `Billing` field names match between the model, the paywall and the settings row. `PaymentsMode` is defined in Task 8 and used in Tasks 8 and 9.
