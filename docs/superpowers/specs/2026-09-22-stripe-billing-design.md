# Stripe billing — design

Date: 2026-09-22. Status: approved in chat, awaiting spec review.

## Goal

Doctors pay for Doqto with a Stripe subscription: $29/month or $290/year.
Every doctor gets a 14-day free trial with no card. When the trial ends
without a subscription, the app asks them to subscribe before they can send
anything. Reading existing messages always keeps working.

## Decisions already made

| Question | Decision |
|---|---|
| How iPhone users pay | Stripe Checkout in the external browser (US App Store link-out). No Apple IAP. |
| What an unpaid doctor can do | Free trial, then a paywall on sending. |
| Stripe account | Exists. Build and verify in test mode, then swap to live keys. |
| Trial length | 14 days, no card, tracked in our database. |
| Existing testers | Trial starts at launch (migration time), not at sign-up. |

## How it works

1. The app asks our backend for a Checkout URL and opens it in Safari (or the
   default browser on Android). Apple's US link-out rule requires the external
   browser, not an in-app web view.
2. After payment Stripe redirects to `https://doqto.ai/billing/done`, a static
   page on the landing site that sends the user back to the app through
   `doqto:///billing`.
3. Stripe tells the backend what happened through a signed webhook. The
   backend mirrors the subscription onto the user row. The redirect alone is
   never trusted.
4. The app never talks to Stripe. It asks our backend `GET /billing` whenever
   it starts, comes back to the foreground, or opens the `doqto:///billing`
   link.
5. Cancelling, switching plan and changing the card all happen in Stripe's
   hosted Customer Portal, opened from Settings.

Stripe only ever receives the doctor's email and our internal user id. No
patient data, message content or clinical information goes to Stripe, so no
BAA is needed.

## Access rule

One function decides access, `entitlement(user, now)`, in
`app/services/billing_service.py`. It returns `entitled` and a `reason`:

| Reason | Condition | Entitled |
|---|---|---|
| `staff` | role is `super_admin` | yes |
| `trial` | `trial_ends_at` is in the future | yes |
| `subscribed` | Stripe status is `active` or `trialing` | yes |
| `grace` | Stripe status is `past_due` and `current_period_end + 7 days` is in the future | yes |
| `expired` | none of the above | no |

The first matching row wins. A trial that is still running wins over a
subscription, so a doctor who pays early keeps the reason `trial` until the
trial date passes, which changes nothing they can do.

## Backend

### Data

Migration `0023_billing` adds to `users`:

| Column | Type | Notes |
|---|---|---|
| `trial_ends_at` | timestamptz, null | Set on registration. |
| `stripe_customer_id` | varchar(64), unique, null | Created on first checkout. |
| `stripe_subscription_id` | varchar(64), null | From the webhook. |
| `billing_status` | varchar(20), null | Mirror of Stripe's subscription status. |
| `billing_plan` | varchar(10), null | `monthly` or `yearly`, derived from the price id. |
| `current_period_end` | timestamptz, null | From the subscription. |

Backfill in the same migration:

- Every registered user (full name set and NPI not `PENDING…`) gets
  `trial_ends_at = now() + 14 days`.
- The App Review demo account (`+16505550199`) gets
  `trial_ends_at = 2099-01-01`, so App Review never meets the paywall.

The downgrade drops the columns.

`AuthService.complete_registration` sets `trial_ends_at = now + BILLING_TRIAL_DAYS`
when it is still null.

### Endpoints

All under `/api/v1/billing`, in a new `app/api/v1/billing.py`.

| Method and path | Auth | Does |
|---|---|---|
| `GET /billing` | user | Returns entitlement, reason, `trial_ends_at`, plan, status, `current_period_end`. |
| `POST /billing/checkout` `{plan}` | user | Creates the Stripe customer if missing, then a Checkout Session. Returns `{url}`. |
| `POST /billing/portal` | user | Creates a Customer Portal session. Returns `{url}`. |
| `POST /billing/webhook` | Stripe signature | Mirrors subscription changes onto the user. |

Checkout details:

- `mode=subscription`, one line item with the price id for the plan
  (`STRIPE_PRICE_MONTHLY` or `STRIPE_PRICE_YEARLY`).
- `client_reference_id` and customer metadata carry the user id.
- `success_url` is `BILLING_RETURN_URL?status=success`, `cancel_url` is
  `BILLING_RETURN_URL?status=cancel`.
- If the user already has status `active`, `trialing` or `past_due`, return
  409 `already_subscribed`. The app sends them to the portal instead.
- An unknown plan is 400 `invalid_plan`.

Portal: 409 `no_billing_account` when the user has no Stripe customer yet.

Both return 503 `billing_unavailable` when `STRIPE_SECRET_KEY` is empty, which
is the local dev default. Entitlement still works without Stripe, so the trial
behaves normally in dev and tests.

Webhook:

- Verify with `stripe.Webhook.construct_event` and `STRIPE_WEBHOOK_SECRET`.
  A bad signature is 400.
- Handled events: `checkout.session.completed`,
  `customer.subscription.created`, `customer.subscription.updated`,
  `customer.subscription.deleted`. Everything else returns 200 and is ignored.
- Find the user by `client_reference_id` for checkout events and by
  `stripe_customer_id` for subscription events. An unknown customer returns
  200 and logs a warning, so Stripe doesn't retry forever.
- For every handled event, re-fetch the subscription from Stripe and copy its
  current status, price and period end. Stripe does not guarantee event
  order, and re-fetching makes the handler idempotent and order-proof.
- Log the user id, event type and new status. Never log the payload.

### Enforcement

A dependency `require_entitled` returns 402 `subscription_required` when
`entitlement` says no. It goes on the endpoints that create content:

- `POST` conversation create
- `POST` conversation message send
- `POST` scheduled message create
- `POST` message upload and voice note
- `POST` group create

Reading, marking read, hiding, profile edits, sign-out and account deletion
stay open. The planning step must confirm there is no other send path, for
example over the websocket, and gate it the same way if there is.

### Config

New settings in `app/core/config.py`, all with safe defaults:

| Setting | Default | Where prod gets it |
|---|---|---|
| `STRIPE_SECRET_KEY` | `""` | SSM secret |
| `STRIPE_WEBHOOK_SECRET` | `""` | SSM secret |
| `STRIPE_PRICE_MONTHLY` | `""` | Terraform env |
| `STRIPE_PRICE_YEARLY` | `""` | Terraform env |
| `BILLING_TRIAL_DAYS` | `14` | default |
| `BILLING_GRACE_DAYS` | `7` | default |
| `BILLING_RETURN_URL` | `https://doqto.ai/billing/done` | default |

New dependency: the official `stripe` Python package.

## Infra

- `infra/backend/main.tf`: two new SSM secrets (`STRIPE_SECRET_KEY`,
  `STRIPE_WEBHOOK_SECRET`) fed from `terraform.tfvars`, which is gitignored.
  Two price ids as plain environment values.
- The webhook needs no ALB change. `api.doqto.ai` already serves
  `/api/v1/*` publicly.
- `landing`: a static page at `/billing/done`. It says "Payment received" or
  "Checkout cancelled" from the `status` query, tries `doqto:///billing`
  automatically, and shows an "Open Doqto" button as the fallback.

## Stripe setup (test mode first)

- Product "Doqto" with two recurring prices: $29 monthly and $290 yearly, USD.
- Webhook endpoint `https://api.doqto.ai/api/v1/billing/webhook`, subscribed
  to the four events above.
- Customer Portal: allow cancel at period end, switching between the two
  prices, and updating the payment method.
- Keys go into `infra/backend/terraform.tfvars` by the user, never in chat or
  git.

## App

### Stage

`AuthStage.needsSubscription` is new. The resolver for a registered user asks
`GET /billing` and returns `needsSubscription` when not entitled. If the call
fails (offline, 5xx) it lets the user in. The server still enforces, so
failing open costs nothing and avoids locking people out on a network blip.

`needsPayment` stays as the one-time plan picker straight after registration.

### Screens

- **Plan picker** (`payments_screen.dart`, after registration). The primary
  button becomes "Start 14-day free trial", which keeps today's behaviour. A
  second button, "Subscribe now", starts checkout for the selected plan.
- **Paywall** (new, stage `needsSubscription`). The same two plans, a
  "Subscribe" button, "I've already paid" to re-check status, and "Sign out".
  It says plainly that messages are kept and readable.
- **Settings**. A "Subscription" row shows "Trial: N days left", "Monthly" or
  "Yearly", or "Payment problem". Tapping it opens the portal, or checkout
  when there is no Stripe customer yet.

Checkout and portal URLs open with `url_launcher` in
`LaunchMode.externalApplication`.

### Coming back

The app re-checks billing and re-resolves the stage when:

- it returns to the foreground,
- it opens the `doqto:///billing` link,
- any request fails with 402 `subscription_required`.

The webhook can arrive a few seconds after the redirect. The paywall's
re-check therefore polls `GET /billing` every 2 seconds for up to 20 seconds
after a return from checkout, then stops.

### Errors

`ErrorMessages` gains `subscription_required`, `already_subscribed`,
`no_billing_account`, `billing_unavailable` and `invalid_plan`.

## Testing

Backend (pytest, Stripe never called over the network):

- `entitlement` for each row of the access table, including the boundaries
  at trial end and at grace end.
- Checkout and portal with the Stripe client replaced by a fake: session
  parameters, customer created once, 409 and 503 cases.
- Webhook with payloads signed in the test using the test secret: good
  signature mirrors state, bad signature is 400, unknown customer is 200,
  events out of order still end in the right state.
- `require_entitled`: an expired user gets 402 on each gated endpoint and 200
  on reads.
- Migration backfill: registered users get a trial, pending users don't, the
  demo account gets 2099.

App (flutter test):

- The resolver sends an expired user to the paywall and lets a user in when
  `GET /billing` fails.
- A 402 on send moves the app to the paywall.
- Plan picker and paywall buttons call checkout with the selected plan and
  launch the returned URL externally, using a fake launcher.
- Settings shows the right subscription line for trial, subscribed and grace.

End to end, in Stripe test mode after deploy:

- Card `4242 4242 4242 4242` subscribes and the app unlocks.
- Card `4000 0000 0000 0341` fails renewal and lands in grace.
- Cancelling in the portal keeps access until the period ends.

## Rollout

1. Backend and migration deployed with test-mode keys.
2. The end-to-end test-mode pass above, on a TestFlight build.
3. App Store availability set to the United States only.
4. Stripe account activated for live payments, live keys and live price ids
   swapped in `terraform.tfvars`, redeploy.

## Out of scope

- Billing organizations or seats.
- Apple In-App Purchase and Google Play Billing.
- Coupons, taxes (Stripe Tax), invoices in the app.
- An admin screen for comping accounts. Setting `trial_ends_at` directly is
  enough for now.

## Risks

- **App Store rules.** The external link-out is only allowed on the US
  storefront. Availability must be US-only before the next App Store
  submission. The rule should be re-checked at submission time.
- **Google Play.** US policy on linking out to web payments has been changing.
  Android needs a policy check before a production Play release.
- **Webhook delay.** Covered by the post-checkout polling window.
- **Missed webhooks.** Stripe retries for three days. Re-fetching on every
  event means one delivered event is enough to repair the state.
