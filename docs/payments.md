# Billing

Doqto is a paid subscription: $8.99/month or $80/year, billed through Stripe.
Every doctor gets a 14-day free trial with no card required. Reading existing
messages never locks; sending does once the trial and any subscription have
lapsed.

```
Phone → OTP → Your details → Choose your plan → Chats
```

## What it is now

The plan picker at the end of registration is real. "Start 14-day free
trial" keeps `needsPayment` moving on with nothing charged, same as before.
"Subscribe now" opens Stripe Checkout in the external browser (Safari or the
device default) for the selected plan.

Once the trial and any subscription have both lapsed, the app shows a
paywall (`AuthStage.needsSubscription`) instead of the plan picker. Sending
messages, scheduled messages, uploads/voice notes and creating conversations
or groups return 402 `subscription_required` until the doctor subscribes.
Reading, marking read, hiding, profile edits, sign-out and account deletion
stay open regardless of billing state.

## Access rule

`entitlement(user, now)` in `app/services/billing_service.py` is the single
place that decides access:

| Reason | Condition | Entitled |
|---|---|---|
| `staff` | role is `super_admin` | yes |
| `trial` | `trial_ends_at` is in the future | yes |
| `subscribed` | Stripe status is `active` or `trialing` | yes |
| `grace` | Stripe status is `past_due` and `current_period_end + BILLING_GRACE_DAYS` is in the future | yes |
| `expired` | none of the above | no |

The first matching row wins, so a doctor who subscribes during their trial
keeps the reason `trial` (and therefore full access) until the trial date
passes — subscribing early changes nothing they can do.

## How a payment happens

1. The app asks the backend for a Checkout URL
   (`POST /api/v1/billing/checkout {plan}`) and opens it in the external
   browser. Apple's US storefront link-out rule requires the external
   browser rather than an in-app web view — see "App Store" below.
2. Stripe Checkout collects the card and starts the subscription.
3. Stripe redirects to `https://doqto.ai/billing/done`, a static page on the
   landing site (`landing/src/app/billing/done/page.tsx`). It reads
   `?status=success|cancel`, tries to reopen the app via `doqto:///billing`
   automatically on success, and always shows an "Open Doqto" button as a
   fallback for browsers that block the automatic redirect.
4. Stripe also calls the backend webhook
   (`POST /api/v1/billing/webhook`, signed) with the subscription event.
   **The webhook, not the redirect, is the source of truth** — the backend
   re-fetches the subscription from Stripe on every handled event and mirrors
   its status, price and period end onto the user row. The app never trusts
   the redirect by itself.
5. The app re-checks `GET /api/v1/billing` whenever it starts, returns to the
   foreground, opens the `doqto:///billing` link, or gets a 402 on a request.
   Right after a return from checkout it polls every 2 seconds for up to 20
   seconds, since the webhook can arrive a few seconds after the redirect.
6. Cancelling, switching plan, updating the card and viewing invoices all
   happen in Stripe's hosted Customer Portal
   (`POST /api/v1/billing/portal`), opened from the Subscription row in
   Settings. A cancellation takes effect at the end of the paid period —
   access continues until then.

Stripe only ever receives the doctor's email and our internal user id. No
patient data, message content or clinical information goes to Stripe, so no
BAA is needed.

## Config

| Setting | Default | Where prod gets it |
|---|---|---|
| `STRIPE_SECRET_KEY` | `""` | SSM secret (Terraform `stripe_secret_key`) |
| `STRIPE_WEBHOOK_SECRET` | `""` | SSM secret (Terraform `stripe_webhook_secret`) |
| `STRIPE_PRICE_MONTHLY` | `""` | Terraform env (`stripe_price_monthly`) |
| `STRIPE_PRICE_YEARLY` | `""` | Terraform env (`stripe_price_yearly`) |
| `BILLING_TRIAL_DAYS` | `14` | default |
| `BILLING_GRACE_DAYS` | `7` | default |
| `BILLING_RETURN_URL` | `https://doqto.ai/billing/done` | default |

An empty `STRIPE_SECRET_KEY` (the local/dev default) makes `/billing/checkout`
and `/billing/portal` return 503 `billing_unavailable`. Entitlement itself
never depends on Stripe being configured, so the trial behaves normally in
dev and in tests with no keys present.

## Stripe setup (test mode)

The Stripe test-mode account is already configured:

- **Product** "Doqto" with two recurring USD prices: `$8.99/month` and
  `$80/year`. The price ids go into `STRIPE_PRICE_MONTHLY` /
  `STRIPE_PRICE_YEARLY` (placeholders below — the real ids are never
  committed):
  ```
  STRIPE_PRICE_MONTHLY=price_xxxxxxxxxxxxxxxxxxxxxxxx
  STRIPE_PRICE_YEARLY=price_xxxxxxxxxxxxxxxxxxxxxxxx
  ```
- **Webhook endpoint** `https://api.doqto.ai/api/v1/billing/webhook`,
  subscribed to `checkout.session.completed`,
  `customer.subscription.created`, `customer.subscription.updated` and
  `customer.subscription.deleted`. Everything else is ignored (returns 200).
  No ALB change was needed — `api.doqto.ai` already serves `/api/v1/*`
  publicly.
- **Customer Portal** configured to allow: cancelling at period end,
  switching between the two prices, updating the payment method, and
  viewing invoices. Return URL is `https://doqto.ai/billing/done`.
- Test-mode secret key and webhook signing secret live only in
  `infra/backend/terraform.tfvars` (gitignored, never in chat or git) and
  are applied as SSM `SecureString` parameters, following the same pattern
  as `FCM_SERVICE_ACCOUNT_JSON`.

## Going live

1. Activate the Stripe account for live payments (Stripe dashboard).
2. Recreate the product/prices, webhook endpoint and Customer Portal
   configuration above in live mode (or verify they already exist if Stripe
   copied them over).
3. Put the live secret key, live webhook signing secret and live price ids
   into `infra/backend/terraform.tfvars`:
   `stripe_secret_key`, `stripe_webhook_secret`, `stripe_price_monthly`,
   `stripe_price_yearly`.
4. Run `./deploy.sh` from `infra/backend/` to build, push and apply.
5. Confirm `GET /api/v1/billing` on a real account and a live test
   subscription end to end before relying on it.

## App Store

iOS purchases go through Stripe Checkout in the external browser, not
StoreKit. Apple allows linking out to an external payment flow for digital
goods only on the **US storefront** (the "reader"/external link-out
exception), so App Store availability must be set to United States only
before any build that ships this flow goes to review — this is not
deferred billing, it's the storefront rule this app now depends on. It
should be re-checked at every App Store submission. Google Play's policy on
linking out to web payments has been changing and needs its own check
before a production Play release; the app uses the same external-browser
flow on Android.

## Testing

Backend (pytest, Stripe never called over the network): `entitlement` for
every row of the access table including the trial/grace boundaries, checkout
and portal against a fake Stripe client (session parameters, 409/503 cases),
webhook payloads signed with the test secret (good signature mirrors state,
bad signature is 400, unknown customer is 200, events out of order still end
in the right state), and `require_entitled` returning 402 on gated endpoints
and 200 on reads.

App (flutter test): the stage resolver sends an expired user to the paywall
and fails open when `GET /billing` errors, a 402 on send moves the app to the
paywall, the plan picker and paywall both call checkout with the selected
plan and launch the URL externally via a fake launcher, and Settings shows
the right subscription line for trial, subscribed and grace.

End to end, in Stripe test mode after deploy: card `4242 4242 4242 4242`
subscribes and the app unlocks; card `4000 0000 0000 0341` fails renewal and
lands in grace; cancelling in the portal keeps access until the period ends.

## Org is no longer a gate

`_resolveStageForRegisteredUser` used to return `needsOrg` for a user with no
orgs, which forced everyone through org selection. It now returns `signedIn`.

The org machinery is untouched and still reachable — create/join still exist,
and joining still comes back through the same resolver, which connects the
realtime socket at that point. The only consequence of having no org is that
`wsOrg(orgId)` has nothing to connect to, so a brand-new user has no live
socket until they join one. `needsOrg` survives as the offline fallback when
`/orgs/mine` can't be reached.

Because of that, **no org is now the normal state of the My Org tab**, not an
error. It used to render `Center(child: Text('No organization selected'))` — a
dead end that was unreachable while onboarding forced an org, and would have
been the first thing every new user saw. It now carries the same two doors the
old org-selection step offered: create, or join with an invite code. Covered by
`test/widgets/my_org_empty_test.dart`.

## Related

- `test/widgets/payments_screen_test.dart` — plan picker rendering and both
  buttons.
- `AuthStage.needsPayment` / `AuthStage.needsSubscription` in the app's auth
  stage resolver.
- `app/services/billing_service.py`, `app/api/v1/billing.py` in
  `doqto_backend/`.
