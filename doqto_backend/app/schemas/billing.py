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
    # Where the live subscription is managed: "apple" (iPhone Settings) or
    # "stripe" (the portal). None when there is nothing to manage.
    store: Literal["apple", "stripe"] | None = None
    # Prices travel with the status so the app shows one truth and computes
    # the yearly saving instead of hard-coding it.
    monthly_cents: int
    yearly_cents: int


class CheckoutIn(BaseModel):
    plan: Plan = Field(description="Which recurring price to subscribe to.")


class UrlOut(BaseModel):
    url: str


class AppleTransactionIn(BaseModel):
    transaction: str = Field(
        max_length=20000, description="StoreKit 2 jwsRepresentation of the transaction."
    )


class AppleNotificationIn(BaseModel):
    signedPayload: str = Field(max_length=100000)
