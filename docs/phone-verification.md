# Sign-up, and adding a phone later

## One door

There is no separate "Create an account". The phone number decides:

```
Login → phone / Google / Facebook / Apple ─┬─ known   → signed in
                                           └─ unknown → Your details → Choose your plan → app
```

Every route is brokered by Firebase and ends at `POST /auth/firebase`, which
returns `is_registered`; the app routes on it. Social sign-in joins at exactly
the same point — there is one entry to the stage machine regardless of provider.
See [auth.md](auth.md).

Your details is unreachable without that verified session — the router sends a
signed-out user back to Login.

## Your details

Required fields are marked `*`: first name, last name, specialty, NPI. No
helper texts. The one conditional line under NPI — "Several clinicians share
that name…" — stays, because it tells the user what to do next.

**Phone** appears only for an account that has none, i.e. social sign-up. It
is optional, so it carries no `*`. Rules:

| State | Continue |
|---|---|
| Empty | allowed |
| Typed, not verified | blocked — "Verify this number, or clear it to skip." |
| Verified | allowed |

Editing the number (or its country) after verifying starts verification over.
Clearing it makes it optional again.

## Backend contract

The sign-in flow cannot be reused: signing in with a phone signs you in **as**
whoever owns it, which would swap the social account for a different (possibly
new) one mid-registration.

Instead the client links the phone to its **existing** Firebase user
(`linkWithCredential`) and sends the refreshed ID token. Firebase sends and
checks the SMS code, so there is one authenticated endpoint and no code of ours
anywhere:

### `POST /api/v1/users/me/phone`

```json
{ "id_token": "<Firebase ID token, refreshed after linking>" }
```

The token's `phone_number` claim is Google's word that the SMS was answered.
On success, sets `phone` on the current user and returns the full `User` (same
shape as `GET /users/me`). It never issues tokens or changes which account is
signed in.

| Response | When |
|---|---|
| `400 phone_not_verified` | the token carries no phone claim — the link never happened |
| `403 firebase_uid_mismatch` | the token belongs to a different Firebase user; a borrowed token must not move a number onto this account |
| `409 phone_already_registered` | the number is already on another account |

`users.phone` is nullable (migration `0022_firebase_identity`), so a social
account that skips the field is valid. Covered by `tests/test_phone_link.py`.

## Practice location

`POST /auth/register` takes only `full_name`, `specialty`, `npi_number` and
silently drops anything else. The city/state from the NPI registry are saved
with `PATCH /users/me` straight after, best-effort — a failure there never
blocks registration.
