# Recommended for you (network suggestions)

Status: built 2026-10-05.

The Network tab shows your connections and then empty space. Fill it with
doctors you probably know, each with a Connect button and the reason they're
suggested.

## What the big networks do

| | Main signal | Also uses |
|---|---|---|
| **LinkedIn** "People you may know" ([engineering](https://engineering.linkedin.com/teams/data/artificial-intelligence/people-you-may-know)) | Triangle closing: friends of friends, ranked by mutual connections | Same company or school, location, profile views and searches. Builds over half of LinkedIn's graph. |
| **Instagram** "Suggested for you" ([Meta transparency](https://transparency.meta.com/features/explaining-ranking/ig-suggested-accounts/)) | Mutual follows | Phone contacts, profile visits, an ML ranker |
| **Doximity** ([blog](https://blog.doximity.com/articles/search-find-and-reach-any-healthcare-provider-instantly)) | Who your colleagues are | Specialty, location, alumni groups |

All three put mutual connections first and the shared workplace next. The
other inputs are behavioural tracking (who you looked at) and contact upload.

## Doqto's version

What makes it ours:

- **Explainable.** Every suggestion says why: "In your organization",
  "3 mutual connections", "Cardiology in Kansas". No black box, so a doctor can
  tell at a glance whether it's right.
- **Privacy first.** No contact upload and no tracking of profile views or
  searches. Only the graph and the public profile fields are used. A doctor who
  set discoverability to nobody, or connections only, or whose orgs are all
  org-only, never appears, exactly as in people search (same SQL filters).
- **Deterministic.** A simple scored query, no ML. Small network, so a model
  would have nothing to learn from; revisit at tens of thousands of doctors.
- **Cold start.** Most doctors have 0–1 connections today, so mutuals alone
  tie everyone at 0. Shared org, specialty and location break the tie.

### Who can be suggested

Doctors who are visible to the viewer in people search, minus:

- the viewer, existing connections, blocked pairs (either way)
- anyone with a pending invitation in either direction
- anyone the viewer dismissed

### Ranking

| Signal | Points |
|---|---|
| Shares an organization with you | 100 |
| Each mutual connection (max 5 counted) | 20 |
| Same specialty | 10 |
| Same state | 5 |
| Same city | 5 |
| Joined in the last 30 days | 3 |

Ties: newest member first, then id. One reason per card, the first that
applies: `colleague`, `mutual`, `specialty_nearby` (specialty and state),
`specialty`, `nearby`, `new_member`, else none.

### API

- `GET /api/v1/network/suggestions?limit=&cursor=` returns a
  `PeopleSearchPage` of `PersonCardOut`, each with `reason` and `mutual_count`.
  Limit default 10, max 50; cursor is an offset like search.
- `POST /api/v1/network/suggestions/{user_id}/dismiss` hides that doctor for
  good. Table `suggestion_dismissals (user_id, dismissed_user_id, created_at)`,
  migration 0025.

### App

Network tab, under Your connections:

- **RECOMMENDED FOR YOU**: top 5 cards. Avatar, name, the reason line,
  **Connect** (sends an invitation; the button turns to **Pending**) and an ×
  that dismisses the card.
- **See all** opens a full list (up to 50) with the same rows.
- Hidden when there's nothing to suggest. Refreshes with the tab's pull to
  refresh.

## Later

- Precompute per user once the doctor count makes the query slow.
- Medical school and residency overlap, once profiles carry them.
- Org-directory members (CMS group) who aren't on Doqto yet, as invites.
