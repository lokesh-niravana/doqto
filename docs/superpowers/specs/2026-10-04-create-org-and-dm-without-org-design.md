# Create an organization, and messaging without one

Status: part 1 **built** (2026-10-04, with the lookup from
`2026-10-04-org-lookup-research.md`); part 2 **built** (2026-10-05), together
with the New message picker (design: https://claude.ai/artifact/N5RdNSUp2vYBnCxLU9Dpj7).

Decisions taken (owner: "go with your recommendations"):
- Groups wait for verification: 403 `org_not_verified`.
- One pending org per creator: 409 `org_pending_exists`.
- The created screen makes no promise of a time; it says "we'll let you know".
- Lookup built now, with auto-verify when the creator's NPI is in the matched
  Medicare group.
- A practice already on Doqto can't be created twice (409 `org_exists`).
  - "Request to join" became **join directly when your NPI is listed** in
    that group (`POST /orgs/directory/join`); otherwise "ask a member for the
    invite code".
  - This avoids a new admin-approval queue. Add one if doctors not on the CMS
    list keep asking.

Design canvas with the five screens: https://claude.ai/artifact/PEVmTGDEzYcqDZ7aQboz2Y

---

## Part 1: creating an organization

### The bug

Tapping **Create an organization** on My Org (no-org empty state) lands on Chats.
**Join with an invite code** does the same.

The screen exists (`create_org_screen.dart`) and the route exists (`/org/create`). The
global redirect throws the user out:

- `auth_state.dart:132`: a registered user with no org is `AuthStage.signedIn`,
  because no org is no longer a blocker.
- `app_router.dart:306-311` counts `/org/select`, `/org/create`, `/org/join` and
  `/org/pending` as the "org flow".
- `app_router.dart:343-348`: a `signedIn` user on any org-flow route → `/chats`.

`test/widgets/my_org_empty_test.dart` builds its own GoRouter with no redirect,
so it passes while the real router bounces.

### The second problem behind it

Fixing the redirect alone leads into a dead end:

- New orgs are always `PENDING` (`org_service.py:53`) until a super admin
  verifies them.
- `refreshOrgStatus` then sets `pendingVerification` (`auth_state.dart:137-140`).
- The router locks the whole app on `/org/pending` (`app_router.dart:338-339`).
- The current org is simply the newest one (`orgs.first`). So a doctor already
  in an active org who creates a second org also gets locked out.

A user who just created an org can't chat, can't reach connections and can't
use the app until someone at Doqto approves the org. That contradicts part 2.

### The framework

**Principle: an organization adds to an account; it never gates it.** A pending
org is a state of that org, not of the user.

**Entry points** (all push `/org/create` or `/org/join`):

1. My Org → no-org empty state → **Create an organization** /
   **Join with an invite code**
2. My Org → org switcher → **Create another organization** (later, once multi-org
   switching exists; out of scope now)

`org_selection_screen.dart` is unreachable today (it is only used for the
network-error fallback). Leave it.

**Flow** (canvas artboards 1–5):

| # | Screen | What happens |
|---|---|---|
| 1 | My Org, empty | The two buttons, unchanged |
| 2 | Create: details | Name\*, practice type\*, city, state. A short note about verification. **Continue** |
| 3 | Create: review | Summary, "You'll be the admin", what verification means. **Create organization** → `POST /orgs` |
| 4 | Created | "Doqto LLC is waiting for verification". The invite code, with Copy and Share. **Done** → My Org |
| 5 | My Org, pending | Org header with a **Pending verification** pill, invite card, members (you, Admin). The rest of the app works as normal |

The details and review steps are two screens, not one long form. The review step
is where the user commits, so the admin role and the verification wait are said
before the org exists, not after.

**Fields** (the backend already accepts all of them; the app sends only name and city today):

| Field | Rule | Backend |
|---|---|---|
| Organization name\* | 1–255 chars, trimmed | `name` |
| Practice type\* | Independent practice / Specialty group / Community hospital | `practice_type` |
| City | optional, ≤100 | `city` |
| State | optional, US state picker → 2-letter code | `state` |

Address is left out. The backend accepts it, but nothing reads it yet.

**After create:**

- The app calls `refreshOrgStatus()`. The stage stays `signedIn`, and the user
  goes to the Created screen, then My Org.
- **The `pendingVerification` lock is removed.**
  - `/org/pending` stays only for the old network-error path and is not used here.
  - The polling moves to My Org: a pending org re-checks on resume and on pull to
    refresh, and the pill turns to verified.
- **Current org:** pick the first `active` org, else the first `pending` one,
  instead of `orgs.first`.
- **While pending, the admin can:**
  - share the invite code (the backend already lets people join pending orgs)
  - see members
  - message colleagues and connections
- **Groups wait for verification:** `create_group` returns 403
  `org_not_verified`. *(Decision needed: see below.)*

**Backend changes:**

- `POST /orgs`: refuse a second **pending** org from the same creator: 409
  `org_pending_exists`. *(Decision needed.)*
- Map these new error codes in `error_messages.dart`: `org_pending_exists`,
  `org_not_verified`.

**App changes:**

- `app_router.dart`: a `signedIn` user may open `/org/create` and `/org/join`.
  Only `/org/select` and `/org/pending` still bounce to `/chats`.
- `auth_state.dart`: drop the `pendingVerification` stage for pending orgs, and
  choose the current org as described above.
- `create_org_screen.dart`: two steps, add practice type and state, and add the
  Created screen.
- `my_org_screen.dart`: pending pill, invite card for admins of pending orgs, and a
  refresh.

**Tests:**

- A router test with the real `routerProvider`: a signed-in user with no org opens
  `/org/create` and stays there (the test missing today). The same for `/org/join`.
- Create → Created → My Org shows pending, and Chats is still reachable.
- An admin of an active org creates a second org and stays on the active one, with no
  lock.
- Backend: creator gets admin; a second pending org gives 409; group creation in a
  pending org gives 403.

**Decisions for you:**

1. **Groups in a pending org: blocked until verified, or allowed?** My
   recommendation is blocked, because a group is the org acting as an organization.
2. **One pending org per creator?** My recommendation is yes. It stops duplicates
   while verification is manual.
3. **Who verifies, and how fast?** Today it's a super admin in the admin panel,
   by hand, with no NPI or domain check. Should the Created screen promise a time,
   such as "usually within 1 business day"?

---

## Part 2: messaging connections without an organization

### The bug

A doctor with no org taps **Message** on a connection and gets "Join or create an
organization before starting a chat."

### Cause

`conversations.py:189-193` looks up the caller's org and returns 400
`user_not_in_any_org` for **every** conversation type, before the direct-message
branch. A direct conversation never uses that org (it is forced to `org_id=None`
at `:216`). Only groups need it.

The relationship rules (`permissions.py:131-154`) never needed an org:

- a colleague (shared org) can message
- a first-degree connection can message
- anyone else gets `not_connected`

Sending into an existing DM has no org check. Only creating one does.

### Also broken for users with no org (app)

`auth_state.dart:132` returns before `_connectWs` and `_syncPushToken`, so a
user with no org has:

- no live socket (no live delivery or typing)
- no push token registered

The backend socket already accepts users with no org (`websocket.py:62-81`).

### Fix

1. **Backend:** move the `caller_org` lookup and its 400 into the group branch.
   Direct conversations skip it.
2. **App:** connect the socket and sync the push token for every signed-in user,
   with or without an org. Use the user-scoped socket, not `/ws/{org_id}`.
3. **App:** give these errors clear messages instead of the generic 403
   "You don't have permission":

   | Code | Message |
   |---|---|
   | `not_connected` | "Connect with Dr X first" |
   | `network_dm_disabled` | (text to write) |
   | `user_unavailable` | (text to write) |
   | `not_reachable` | (text to write) |

4. **Ops:** confirm `NETWORK_DM_ENABLED=true` in the live prod task definition.
   Terraform sets it to true, but with no shared org the flag decides, so if it
   is false users with no org still can't start DMs.

### Also: Start a conversation opened the group creator

Chats → **Start a conversation** pushed `/new-group`, a group-only screen
listing org members. It is replaced by **New message**
(`new_message_screen.dart`, route `/new-message`), modelled on WhatsApp:
connections first, then colleagues (each person once), search, **New group**
only for a verified org, **Find doctors on Doqto**, and an empty state. Tapping
a person opens the existing direct chat or creates one, replacing the picker so
back returns to Chats. The Chats header gained a compose button to the same
screen. The old `create_group_screen.dart` is deleted; groups are created from
the Groups tab flow.

### Tests

- Backend (`tests/test_dm_without_org.py`):
  - a user with no org and an accepted connection: create a DM gives 201, and
    sending works
  - with no connection, it gives 403 `not_connected`
  - creating a group with no org still gives 400
- App: sign in with no org, and the socket connects and the push token syncs.
