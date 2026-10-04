# Organization lookup: research

Status: **research, for decision** (2026-10-04). It feeds part 1 of
`2026-10-04-create-org-and-dm-without-org-design.md`.

The question: we already prefill a doctor from the public NPI Registry
(`docs/npi-lookup.md`). Can organization names come from a public database the
same way, instead of being typed freely?

**Yes. Three free, public CMS sources cover it. Two of them also tell us which
doctors belong to which group.** I checked each one live on 2026-10-04.

## The sources

### 1. CMS Doctors and Clinicians (group practices): the best fit

- **What:** the "National Downloadable File" on data.cms.gov, dataset
  `mj5m-pzi6`. It has one row per clinician × practice location, and it was
  updated 2026-08-18. CMS refreshes it monthly.
- **Fields we'd use:**

  | Field | Meaning |
  |---|---|
  | `facility_name` | group name |
  | `org_pac_id` | the group's stable Medicare ID |
  | `num_org_mem` | number of clinicians in the group |
  | `citytown`, `state` | location |
  | `npi` | the clinician |
  | `pri_spec` | specialty |

- **Live check:** a search for "SAINT LUKE" in MO returned `SAINT LUKES PHYSICIAN
  GROUP INC`, PAC `3577476894`, **1,233 members**, with each member's NPI.
- **Why it matters:** it links **doctor → group**. From the NPI a doctor already
  gives us at registration, we can suggest "You practice with Saint Luke's
  Physician Group" without them searching at all.
- **Free and keyless:** the API is
  `data.cms.gov/provider-data/api/1/datastore/query/mj5m-pzi6/0`, and the file
  is also downloadable in bulk.
- **Gaps:**
  - It only covers clinicians and groups enrolled in Medicare. Most US
    physicians are; cash-only and some concierge practices aren't.
  - Some solo doctors have no group. The test NPI `1851408082` has none.

### 2. CMS Hospital General Information

- **What:** dataset `xubh-q36u`, about **5,419 hospitals**, each with a CMS
  Certification Number.
- **Live check:** "SAINT LUKE" in MO returned `SAINT LUKES NORTH HOSPITAL` (CCN
  260062) and `SAINT LUKE'S EAST HOSPITAL` (CCN 260216), both Acute Care.
- **Strengths:** small, clean, and it carries a hospital type. Good for the
  "Community hospital" practice type.

### 3. NPPES NPI Registry, organizations (NPI-2): live fallback

- **What:** the same API we already call, with `enumeration_type=NPI-2&
  organization_name=<name>*&city=&state=`. It covers every organization that
  has an NPI, which is broader than Medicare.
- **Live check:** "saint luke\*" in Kansas City, MO returned:
  - `SAINT LUKE'S`
  - `SAINT LUKE'S CARDIOLOGY SERVICES, LLC`
  - `SAINT LUKE'S CARDIOVASCULAR CONSULTANTS`
  - two hospice/pharmacy entries
- **Weaknesses:**
  - It's noisy. Health systems register many billing entities, sub-parts,
    pharmacies and hospice units.
  - It has no doctor → organization link.
  - Names are legal billing names.
- **Usable with filters:** keep `organizational_subpart = NO`, filter out
  non-practice taxonomies (pharmacy, DME, hospice, labs), and remove duplicates
  by name + city.

## Recommendation

**Build a small Doqto organization directory from sources 1 and 2, and use 3
live as a fallback.**

- **Store it:** a Postgres table `org_directory`:

  | Column | Content |
  |---|---|
  | `source` | `cms_group` / `cms_hospital` / `nppes` |
  | `source_id` | PAC ID / CCN / NPI |
  | `name`, `display_name` | legal name, and a title-cased version |
  | `city`, `state` | location |
  | `type` | maps to our three practice types |
  | `member_count` | clinicians in the group |

  Plus a table `org_directory_member (source_id, npi)` linking groups to their
  doctors.
- **Search it:** Postgres trigram search on `display_name`, plus state, so
  search-as-you-type is fast and handles typos.
- **Refresh it:** a monthly job loads the CMS files. There are roughly 2–3M
  clinician rows, which collapse to about 100k groups. I'll confirm the real
  numbers on the first load.
- **Why load it ourselves instead of calling CMS live:**
  - the CMS query API is slow for type-ahead
  - CMS returns one row per clinician, not per group, so we'd have to dedupe
    every keystroke
  - we need the doctor → group link anyway

**What it changes in the create flow:**

1. **"Suggested for you"** at the top of the create screen. These are the groups
   CMS lists the doctor's own NPI under, so most doctors tap once.
2. **The name field becomes a search.** Picking a result fills in the name,
   practice type, city and state, and stores `directory_source` / `directory_id`
   on the organization.
3. **"Can't find it? Enter it yourself"** keeps free entry for groups that
   aren't in the data.
4. **Duplicates turn into joins.** If a Doqto organization is already linked to
   that directory entry, the result says "Already on Doqto" and offers **Request
   to join** instead of creating a copy.
5. **Faster verification:**
   - If the creator's NPI is listed in that group, the match is strong evidence.
     We could auto-verify on it, or put it at the top of the admin review queue.
   - Free-typed organizations stay manually reviewed.

## Caveats

- **Names come in CMS styling** (`SAINT LUKES PHYSICIAN GROUP INC`). We store
  the legal name and show a title-cased name with "Inc"/"LLC" removed. The
  creator can still edit the display name.
- **A Medicare PAC ID is a billing group, not always the name doctors use.** A
  big system may bill as one group while doctors think of their department.
  Free entry and editable display names cover this.
- **The data is monthly.** A doctor who joined a group last week may not show
  as a suggestion yet. Search still finds the group.
- **Licence:** CMS public data is free to use.

## Decisions

1. **Build the directory now, or ship the plain create flow first and add
   lookup after?** It's about two days more of backend work: the import job,
   the search endpoint, and the doctor → group join.
2. **Auto-verify when the creator's NPI is in the matched group?** My
   recommendation is yes, which removes the manual wait for most organizations.
3. **Duplicates:** when an organization already exists for a directory entry,
   allow only "Request to join" (my recommendation), or still allow a second
   one?
