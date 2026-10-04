# Next steps

A living list. Update it as items close. Last updated 2026-10-05.

## Now: bugs

1. **Create an organization: built, not yet deployed.** It fixes the redirect,
   adds the lookup-driven create flow, and stops pending orgs locking the app.
   To deploy: run migration 0024 and the backend deploy, then
   `python -m scripts.import_org_directory` as a one-off ECS task. Repeat the
   import monthly.
   Spec: `docs/superpowers/specs/2026-10-04-create-org-and-dm-without-org-design.md`, part 1.
   Screens: https://claude.ai/artifact/PEVmTGDEzYcqDZ7aQboz2Y. **Review first.**
   Organization lookup research (CMS group, hospital and NPPES data):
   `docs/superpowers/specs/2026-10-04-org-lookup-research.md`. Decide this
   before finalising the create flow.
2. **Users with no org can't message connections: fixed.** The org gate now
   applies to groups only (backend deployed 2026-10-05), and Chats → Start a
   conversation opens the New message picker (app build 34). Same spec, part 2.

## Waiting on others

| What | Waiting on | Then |
|---|---|---|
| Apple organization account, enrollment `4Y88NV2RKY` | Apple verifies Dhanunjaya; he accepts the agreement and pays $99 | He adds lokesh@doqto.ai as Admin |
| Stripe live activation, `acct_1U3GwU6Y4Fw7IsvC` | Dhanunjaya: last 4 of his SSN, the LLC bank account, 2FA | Review and submit together |
| Play: India and the health declaration | Google review | Live in India |

## When Apple approves

Finish branch `ios-org-team` (checklist in `docs/ios-release.md`, "Moving to
the DOQTO LLC team"):

- new team ID
- APNs key uploaded to Firebase
- new App Store Connect app
- TestFlight, with a new invite link
- App Review: demo login, Stripe note, privacy, US only, iPad check

## When Stripe is active

Go live per `docs/payments.md`:

- live prices
- clear the test subscriptions
- live keys in the tfvars
- deploy
- one real purchase to confirm

Best done after the App Store approval.

## You

- Accept Apple's updated agreement on the personal account. It was due
  2026-10-02. TestFlight build 32 lasts until about 22 December.
- Delete the passport scan from wherever it was shared.

## Later

- Remove "The app blurs itself in the task switcher" from the Play description.
  It's no longer true on Android.
- Android payments: Play's external links program, or Play Billing.
- Cleanup:
  - delete test number +1 650-555-0198
  - close Twilio
  - remove builds 11, 14 and 15 from the TestFlight group
  - optionally rotate the FCM key
