---
name: Doqto Design System
colors:
  surface: '#faf8ff'
  surface-dim: '#d9d9e4'
  surface-bright: '#faf8ff'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f3f3fe'
  surface-container: '#ededf8'
  surface-container-high: '#e7e7f3'
  surface-container-highest: '#e2e1ed'
  on-surface: '#191b23'
  on-surface-variant: '#434654'
  inverse-surface: '#2e3039'
  inverse-on-surface: '#f0f0fb'
  outline: '#737686'
  outline-variant: '#c3c5d7'
  surface-tint: '#1353d8'
  primary: '#003fb1'
  on-primary: '#ffffff'
  primary-container: '#1a56db'
  on-primary-container: '#d4dcff'
  inverse-primary: '#b5c4ff'
  secondary: '#006a60'
  on-secondary: '#ffffff'
  secondary-container: '#69f9e5'
  on-secondary-container: '#007166'
  tertiary: '#852b00'
  on-tertiary: '#ffffff'
  tertiary-container: '#ad3b00'
  on-tertiary-container: '#ffd4c5'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#dbe1ff'
  primary-fixed-dim: '#b5c4ff'
  on-primary-fixed: '#00174d'
  on-primary-fixed-variant: '#003dab'
  secondary-fixed: '#69f9e5'
  secondary-fixed-dim: '#46dcc9'
  on-secondary-fixed: '#00201c'
  on-secondary-fixed-variant: '#005048'
  tertiary-fixed: '#ffdbcf'
  tertiary-fixed-dim: '#ffb59a'
  on-tertiary-fixed: '#380d00'
  on-tertiary-fixed-variant: '#802a00'
  background: '#faf8ff'
  on-background: '#191b23'
  surface-variant: '#e2e1ed'
  med-blue-dark: '#1E2A5A'
  med-blue-mid: '#5FA5AB'
  med-blue-light: '#E6F1F2'
  med-teal-light: '#E0FAF7'
  gray-50: '#F8FAFD'
  gray-100: '#EEF2F8'
  gray-200: '#D6DDF0'
  gray-400: '#8A9CC4'
  gray-600: '#4A5E8C'
  gray-800: '#1C2B4A'
  gray-900: '#0D1829'
  green-success: '#22C55E'
  amber-warning: '#F59E0B'
  red-danger: '#EF4444'
  red-light: '#FEF2F2'
  avatar-purple: '#7C3AED'
typography:
  display-hero:
    fontFamily: Sora
    fontSize: 22px
    fontWeight: '700'
    lineHeight: '1.2'
    letterSpacing: normal
  heading-section:
    fontFamily: Sora
    fontSize: 17px
    fontWeight: '600'
    lineHeight: '1.3'
    letterSpacing: normal
  subheading-ui:
    fontFamily: DM Sans
    fontSize: 15px
    fontWeight: '500'
    lineHeight: '1.4'
    letterSpacing: normal
  body-message:
    fontFamily: DM Sans
    fontSize: 14px
    fontWeight: '400'
    lineHeight: '1.5'
    letterSpacing: normal
  caption-timestamp:
    fontFamily: DM Sans
    fontSize: 12px
    fontWeight: '400'
    lineHeight: '1.2'
    letterSpacing: normal
  label-caps:
    fontFamily: DM Sans
    fontSize: 11px
    fontWeight: '600'
    lineHeight: '1.0'
    letterSpacing: 1.5px
  code-display:
    fontFamily: Sora
    fontSize: 20px
    fontWeight: '700'
    lineHeight: '1.0'
    letterSpacing: 4px
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  space-1: 4px
  space-2: 8px
  space-3: 12px
  space-4: 16px
  space-6: 24px
  space-8: 32px
  space-10: 40px
---

# Doqto — Design System

> Version 1.1 · May 2026 · Light theme only · Mobile-first · Flutter (iOS + Android)

---

## 1. Brand Identity

**App name:** Doqto  
**Tagline:** Secure doctor-to-doctor communication  
**Category:** B2B Healthcare Communication  
**Theme:** Light only. Clean, clinical, trustworthy. No dark mode.

### Logo Mark
Two circular doctor symbols with bidirectional arrows and a stethoscope element connecting them. The mark communicates peer-to-peer clinical communication at a glance.

### App Icon
- Background: `#35878F` (primary blue)
- Icon: White logo mark centered
- Corner radius: iOS/Android standard (continuous curve)

---

## 2. Color System

### Primary Palette

| Token | Hex | Usage |
|---|---|---|
| `--med-blue` | `#35878F` | Primary actions, nav bar, sent bubbles, CTAs |
| `--med-blue-dark` | `#1E2A5A` | Hover states, headings on white |
| `--med-blue-mid` | `#5FA5AB` | Focused inputs, secondary highlights |
| `--med-blue-light` | `#E6F1F2` | Input backgrounds, badge fills, tinted surfaces |
| `--med-teal` | `#0ABFAD` | Accent, mic button, voice note elements, teal badges |
| `--med-teal-light` | `#E0FAF7` | Teal surface backgrounds |

### Neutral Palette

| Token | Hex | Usage |
|---|---|---|
| `--med-gray-50` | `#F8FAFD` | App background, screen bg |
| `--med-gray-100` | `#EEF2F8` | Dividers, card borders, input borders |
| `--med-gray-200` | `#D6DDF0` | Stronger borders, separator lines |
| `--med-gray-400` | `#8A9CC4` | Placeholder text, captions, timestamps, muted info |
| `--med-gray-600` | `#4A5E8C` | Secondary text, labels, subtitles |
| `--med-gray-800` | `#1C2B4A` | Primary text, headings |
| `--med-gray-900` | `#0D1829` | Display text, hero headings |
| `--med-white` | `#FFFFFF` | Card surfaces, received bubbles, modal bg |

### Semantic Palette

| Token | Hex | Usage |
|---|---|---|
| `--med-green` | `#22C55E` | Online presence, success states, verified badge |
| `--med-green-light` | `#DCFCE7` | Online badge background |
| `--med-amber` | `#F59E0B` | Away presence, warning states |
| `--med-red` | `#EF4444` | Danger actions, error states, leave org |
| `--med-red-light` | `#FEF2F2` | Danger button background |

### Avatar Color Cycle
Avatars use initials with colored circle backgrounds. Cycle through these in order by user index:

| Index | Color | Hex |
|---|---|---|
| 0 | Blue | `#35878F` |
| 1 | Teal | `#0ABFAD` |
| 2 | Purple | `#7C3AED` |
| 3 | Dark Blue | `#1E2A5A` |
| 4 | Amber | `#F59E0B` |

---

## 3. Typography

**Display font:** Sora — used for all headings, app name, nav titles, doctor names  
**Body font:** DM Sans — used for all body text, messages, captions, labels, buttons

### Type Scale

| Style | Font | Weight | Size | Color | Usage |
|---|---|---|---|---|---|
| Display | Sora | 700 | 22px | `#0D1829` | Screen titles, doctor name on profile |
| Heading | Sora | 600 | 17px | `#1C2B4A` | Section headers, org name |
| Subheading | DM Sans | 500 | 15px | `#1C2B4A` | Specialty, subtitle rows |
| Body | DM Sans | 400 | 14px | `#4A5E8C` | Message content, descriptions |
| Caption | DM Sans | 400 | 12px | `#8A9CC4` | Timestamps, file size, read receipts |
| Label | DM Sans | 600 | 11px | `#35878F` | Section labels, uppercase tags |
| Code / Invite | Sora | 700 | 20px | `#1E2A5A` | Invite code display (letter-spacing: 4px) |

### Rules
- Never use font sizes below 11px
- Invite codes always use Sora 700 with `letter-spacing: 4px`
- Button text: DM Sans 600, 14px
- All caps only for section labels (11px, `letter-spacing: 1.5px`)

---

## 4. Spacing System

Base unit: **4px**. All spacing is a multiple of 4.

| Token | Value | Usage |
|---|---|---|
| `space-1` | 4px | Icon internal padding, tight gaps |
| `space-2` | 8px | Gap between inline elements, small padding |
| `space-3` | 12px | Chat item padding, button internal gaps |
| `space-4` | 16px | Standard screen horizontal padding, card padding |
| `space-6` | 24px | Section spacing, between cards |
| `space-8` | 32px | Large section gaps |
| `space-10` | 40px | Screen top/bottom breathing room |

**Standard screen padding:** 16px horizontal  
**Card internal padding:** 16px all sides

---

## 5. Border Radius

| Token | Value | Usage |
|---|---|---|
| `radius-xs` | 4px | Small tags, wave bars |
| `radius-sm` | 8px | Input fields, small cards |
| `radius-md` | 12px | Standard cards, attachment previews |
| `radius-lg` | 16px | Mobile frames, large cards, modals |
| `radius-xl` | 22px | Bottom sheets, screen containers |
| `radius-full` | 999px | Buttons (pill), avatars, badges, presence dots |

### Chat Bubble Radius
- **Received bubble:** `4px` top-left, `16px` top-right, `16px` bottom-right, `16px` bottom-left
- **Sent bubble:** `16px` top-left, `16px` top-right, `4px` bottom-right, `16px` bottom-left

---

## 6. Elevation & Shadows

| Level | Value | Usage |
|---|---|---|
| Card | `0 2px 12px rgba(26,86,219,0.08)` | Standard content cards |
| Elevated | `0 4px 24px rgba(26,86,219,0.13)` | Modals, bottom sheets, active elements |
| None | `none` | Flat surfaces, nav bars |

---

## 7. Components

### 7.1 Buttons

| Variant | Background | Text | Border | Usage |
|---|---|---|---|---|
| Primary | `#35878F` | `#FFFFFF` | None | Main CTAs: Join, Send, Continue |
| Secondary | `#E6F1F2` | `#1E2A5A` | None | Invite, secondary actions |
| Ghost | Transparent | `#4A5E8C` | `1.5px #D6DDF0` | Cancel, back actions |
| Danger | `#FEF2F2` | `#EF4444` | None | Leave org, remove doctor |
| Icon (blue) | `#E6F1F2` | — | None | Add, new chat |
| Icon (teal) | `#E0FAF7` | — | None | Mic, voice actions |

All buttons: `border-radius: 999px` (pill), `font: DM Sans 600 14px`, `padding: 10px 20px`  
Icon buttons: `40px × 40px`, `border-radius: 999px`

---

### 7.2 Input Fields

**Standard input:**
- Background: `#F8FAFD`
- Border: `1.5px solid #D6DDF0`
- Border radius: `12px`
- Padding: `11px 14px`
- Font: DM Sans 400 14px, color `#1C2B4A`
- Placeholder: `#8A9CC4`
- Focus border: `1.5px solid #35878F`

**Invite code input:**
- Background: `#E6F1F2`
- Border: `1.5px solid #5FA5AB`
- Border radius: `12px`
- Font: Sora 700 15px, color `#1E2A5A`
- Letter spacing: `3px`
- Placeholder: `APOL·4827`

**Chat input bar:**
- Background: `#F8FAFD`
- Border: `1px solid #D6DDF0`
- Border radius: `999px`
- Padding: `9px 14px`
- Font: DM Sans 400 13px

---

### 7.3 Avatars

All avatars display the user's initials (first + last name). No photo default — initials always shown.

| Size | Dimensions | Font | Usage |
|---|---|---|---|
| XL | 52×52px | Sora 700 16px | Profile screen |
| LG | 44×44px | Sora 700 14px | Chat list rows |
| MD | 36×36px | Sora 700 12px | Chat thread nav, org list |
| SM | 28×28px | Sora 700 10px | Compact lists, nav |

**Presence dot:** Positioned bottom-right of avatar
- Size: `10×10px`, border: `2px solid white`
- Online: `#22C55E`
- Away: `#F59E0B`
- Offline: `#8A9CC4`

---

### 7.4 Badges

| Variant | Background | Text Color | Usage |
|---|---|---|---|
| Role | `#E6F1F2` | `#1E2A5A` | "Doctor" |
| Admin | `#FEF3C7` | `#92400E` | "Admin" |
| Org | `#E0FAF7` | `#0D6B62` | Hospital name |
| Online | `#DCFCE7` | `#15803D` | "Online" |
| Specialty | `#F3E8FF` | `#6B21A8` | "Cardiology", "Orthopedics" |
| Verified | `#DCFCE7` | `#15803D` | Org verified status |

All badges: `border-radius: 999px`, `DM Sans 600 11px`, `padding: 4px 10px`

---

### 7.5 Group Avatar (Stacked)

Group chats do not have a single avatar. Instead, display a 2×2 stacked grid of the first 4 members' initials avatars, each `22×22px`, overlapping slightly.

```
┌──┬──┐
│SC│VM│
├──┼──┤
│RN│+3│
└──┴──┘
```

- Grid size: `44×44px` total
- Each cell: `22×22px` avatar (SM size), `1.5px white border` between cells
- Overflow: if more than 4 members, bottom-right cell shows `+N` in `#8A9CC4` on `#EEF2F8` bg
- Used in: Chat list rows, group thread nav bar

---

### 7.6 Invite Code Display

```
┌─────────────────────────────────────────┐
│  Your org invite code                   │  ← 11px muted white
│  MEDC·7731                              │  ← Sora 700 20px white letter-spaced
│                              [  Copy  ] │  ← Ghost button white
└─────────────────────────────────────────┘
```
- Background: `#35878F`
- Border radius: `16px`
- Padding: `14px 16px`

---

### 7.7 Chat Bubbles

**Received bubble:**
- Background: `#FFFFFF`
- Border: `1px solid #EEF2F8`
- Text: DM Sans 400 13px `#1C2B4A`
- Sender name: DM Sans 600 10px `#0ABFAD` (shown in group contexts)
- Timestamp: 10px `#8A9CC4`, bottom-right

**Sent bubble:**
- Background: `#35878F`
- Text: DM Sans 400 13px `#FFFFFF`
- Timestamp + read receipts: 10px `rgba(255,255,255,0.55)`, bottom-right
- Max width: 72% of screen width

**Read receipts:**
- `✓` — Sent (gray)
- `✓✓` — Delivered (gray)
- `✓✓` — Read (blue tint on white, white on blue bubble)

---

### 7.8 Voice Note Bubble

Displayed as a sent blue bubble with two zones:

**Zone 1 — Player row:**
- Play button: `32×32px` circle, `rgba(255,255,255,0.25)` bg, white play icon
- Waveform: series of 3px wide bars, varying heights (6–18px), `rgba(255,255,255,0.7)` fill
- Duration: DM Sans 400 11px `rgba(255,255,255,0.7)`

**Zone 2 — Transcript strip:**
- Separator: `1px solid rgba(255,255,255,0.15)`
- Text: DM Sans 400 italic 11px `rgba(255,255,255,0.75)`
- Example: *"Looks like sinus node dysfunction. Recommend 24hr holter before escalating."*

---

### 7.9 File Attachment Bubble

Inside a received bubble, shown above message text:
- Background: `#F8FAFD`
- Border: `1px solid #D6DDF0`
- Border radius: `8px`
- Padding: `7px 10px`
- PDF icon: blue-tinted rectangle with line details
- File name: DM Sans 600 12px `#1C2B4A`
- File size: DM Sans 400 10px `#8A9CC4`

---

### 7.10 Navigation Bar

**Top nav (blue):**
- Background: `#35878F`
- Title: Sora 700 17px white
- Back button: `30×30px` circle, `rgba(255,255,255,0.15)` bg
- Status bar: extends blue upward

**Tab bar (bottom):**
- Background: `#FFFFFF`
- Border top: `1px solid #EEF2F8`
- Active tab: `#35878F`, 2px bottom indicator
- Inactive tab: `#8A9CC4`
- Font: Sora 600 12px
- Tabs: Chats / Doctors / My Org

---

## 8. Screen Specifications

### 8.1 Splash / Onboarding
- Full blue background: `#35878F`
- Centered logo mark (white, 80px)
- App name: Sora 700 32px white
- Tagline: DM Sans 400 14px `rgba(255,255,255,0.65)`
- CTA button: white background, `#35878F` text (inverted primary)

---

### 8.2 Registration
- White screen, 16px horizontal padding
- Section: phone input → "Send OTP" → OTP 6-digit input → "Verify"
- Then: Full name, Specialty dropdown, NPI number
- NPI helper text: DM Sans 400 12px muted — "Find your NPI at nppes.cms.hhs.gov"
- Progress indicator: 3 steps (Phone → Details → Done)

---

### 8.3 Org Selection
- Two equal-height cards (white, shadow-card, radius-lg)
- Card 1: Building icon + "Create Organization" + "Set up your hospital or practice"
- Card 2: Key/code icon + "Join with Invite Code" + "Your org admin shared a code with you"
- 16px gap between cards

---

### 8.4 Chat List
```
┌─────────────────────────────┐
│ 9:41          ▌▌▌  WiFi     │  ← status bar (blue)
│ MedLink              [+]    │  ← nav (blue)
│ ─────────────────────────── │
│ Chats  │ Doctors │ My Org   │  ← tab bar
│ ─────────────────────────── │
│ [VM●] Dr. V. Mehta    2m    │
│       🎤 Voice note · 0:24 [3]│
│ ─────────────────────────── │
│ [RN◐] Dr. R. Nanavati 14m   │
│       ECG attached — review  │
└─────────────────────────────┘
```

---

### 8.5 Chat Thread
```
┌─────────────────────────────┐
│ [←] [VM] Dr. V. Mehta  [⋯] │  ← nav
│      Cardiologist · Online   │
│ ─────────────────────────── │
│  ┌──────────────────────┐   │
│  │ Patient 47M, irreg.. │   │  ← received
│  └──────────────────────┘   │
│         ┌───────────────┐   │
│         │ ▶  ───────  24│   │  ← sent voice note
│         │ "Sinus node.."│   │
│         └───────────────┘   │
│ ─────────────────────────── │
│ [🎤] [Message...]  [📎] [➤] │  ← input bar
└─────────────────────────────┘
```

---

### 8.6 Voice Note Recording (Bottom Sheet)
- Background overlay: `rgba(0,0,0,0.4)`
- Bottom sheet: white, `border-radius: 22px 22px 0 0`
- Red animated dot + "Recording..." label
- Live waveform (animated bars, teal color)
- Duration counter: Sora 700 32px
- Instruction: "Release to send · Slide left to cancel"
- Cancel zone: left side, red tint on slide

---

### 8.7 My Org Screen
- Org name: Sora 700 17px + green "Verified" badge
- Invite code card: full-width blue card (see 7.5)
- Section label: "MEMBERS (12)" — uppercase, blue, 11px
- Doctor list rows: avatar (LG) + name + specialty + presence badge

---

### 8.8 Pending Verification
- Centered layout
- Icon: clock or hourglass (blue tinted, 80px)
- Title: Sora 700 22px "Verification in Progress"
- Body: DM Sans 400 14px muted, centered
- No CTA — non-dismissable holding screen
- Subtle "Contact support" text link at bottom

---

### 8.9 Create Group (New Screen)

Entry point: tap `[+]` icon in Chat List nav bar → bottom sheet appears with two options: "New Direct Message" and "New Group". Tapping "New Group" pushes this screen.

**Layout:**
```
┌─────────────────────────────┐
│ [←]  New Group         [✓]  │  ← nav, checkmark enabled once name + 2+ members
│ ─────────────────────────── │
│  Group name                 │
│ ┌─────────────────────────┐ │
│ │ e.g. ICU Consult Team   │ │  ← standard input, autofocus
│ └─────────────────────────┘ │
│                             │
│  ADD MEMBERS                │  ← section label, blue uppercase 11px
│ ┌─────────────────────────┐ │
│ │ 🔍 Search doctors...    │ │  ← search input, gray bg
│ └─────────────────────────┘ │
│                             │
│ [SC●] Dr. S. Chen    [+ Add]│
│ [VM●] Dr. V. Mehta   [+ Add]│
│ [RN◐] Dr. R. Nanavati[+ Add]│
│ [DJ○] Dr. D. Joshi   [+ Add]│
│ ─────────────────────────── │
│  SELECTED (2)               │  ← section label, appears after first add
│ [SC ×] [VM ×]               │  ← selected doctor chips, tappable × to remove
└─────────────────────────────┘
```

**Rules:**
- Group name: required, max 40 characters
- Minimum 2 members to enable the confirm checkmark (creator is auto-included, not shown in list)
- No maximum member count for MVP
- Doctor list shows only members of the same org, sorted alphabetically
- Search filters list in real time
- Selected doctors shown as chips below the list: avatar (SM) + first name + `×` remove button
- Chip: `#E6F1F2` bg, `#1E2A5A` text, `border-radius: 999px`, `DM Sans 500 12px`, `padding: 4px 10px`

---

### 8.10 Group Chat Thread (New Screen)

Same layout as direct chat thread (8.5) with these differences:

**Nav bar:**
```
┌─────────────────────────────┐
│ [←] [SC][VM]  ICU Consult  [⋯]│
│      3 members               │  ← member count, muted 10px
└─────────────────────────────┘
```
- Avatar: stacked group avatar (see 7.5) instead of single avatar
- Subtitle: `{N} members` in DM Sans 400 10px `rgba(255,255,255,0.65)`

**Message bubbles:**
- Received bubbles show **sender name** above the message text
- Sender name: DM Sans 600 10px, color from avatar color cycle (e.g. teal for VM, purple for RN)
- Sender's SM avatar shown to the left of the received bubble
- Sent bubbles unchanged — no sender name (it's you)

**Read receipts in groups:**
- Bubble ticks stay coarse (`✓✓` once every member has it).
- Per-member detail lives in **Message info**: select one of your own sent
  messages → ⓘ in the selection bar → sheet with *Read by / Delivered to /
  Not yet delivered*, each row name + avatar + time. Backed by
  `GET /messages/{id}/receipts` (sender-only; groups read the per-member
  `last_read_seq` / `last_delivered_seq` cursors, direct chats the receipt rows).

**Admins-only posting:** when `post_policy = admins_only`, members see a
read-only strip "Only admins can send messages" where the composer was; the
server refuses their sends with `403 post_restricted`.

**Input bar:** identical to direct chat — mic, text, attachment, send

---

### 8.11 Group Info Screen (New Screen)

Accessed by tapping the group name / avatar in the chat thread nav bar.

```
┌─────────────────────────────┐
│ [←]  Group Info        [✏️] │  ← edit pencil for creator only
│ ─────────────────────────── │
│  [SC][VM]                   │  ← large group avatar (60×60px version)
│  [RN][+1]                   │
│                             │
│  ICU Consult Team           │  ← Sora 700 20px centered
│  3 members · Created by you │  ← DM Sans 400 12px muted centered
│                             │
│  MEMBERS (3)                │  ← section label
│ [SC●] Dr. S. Chen   (You)   │
│ [VM●] Dr. V. Mehta          │
│ [RN◐] Dr. R. Nanavati       │
│                             │
│  [+ Add Members]            │  ← secondary button, full width
│                             │
│  [Leave Group]              │  ← danger button, full width
└─────────────────────────────┘
```

**Rules (as shipped, role-aware):**
- A pending invitee lands here instead of the chat: info banner "You've
  been invited to this group" + **Decline / Accept**. Accept → the chat opens.
  The Groups tab shows the same pair on the Invited row.
- **Owner / admin** (`canManage`): tap the avatar → photo sheet (library /
  camera / remove, `POST|DELETE /groups/{id}/avatar`); tap the name → rename
  dialog; pencil on About → description dialog. **Group settings** section:
  Send messages (All members / Admins only), Member direct messages (Open /
  Connections only / Off), Disappearing messages (same picker as a chat).
  **Invite links** section: create (max uses + 1 day / 7 days / never),
  copy, share sheet, revoke; links are `doqto:///g/<token>`. **Add members**
  opens a searchable sheet of connections + org colleagues minus current
  members, multi-select, one invite each.
- Tap a member row → actions sheet: Message, View profile for everyone;
  Remove / Ban for owner and admins (admins cannot touch the owner or other
  admins); Make admin / Remove as admin / Transfer ownership for the owner.
- Members see facts only: About (incl. the DM rule and "Admins only" when
  set), the member list, Leave Group.
- Leave Group: confirmation, then back to the Groups tab.
- Legacy org group chats (no `groups` row) never open this screen; their
  header still opens Chat details.

---

## 9. Interaction Patterns

### Invite Code Format
Always display as: `XXXX·XXXX` (4 uppercase letters, middle dot `·`, 4 digits)  
Example: `APOL·4827`, `MEDC·7731`

### Voice Note Recording
- **Hold** mic button → recording starts (haptic feedback)
- **Release** → sends automatically
- **Slide left** → cancels (no send)
- Minimum recording: 1 second
- Maximum recording: 5 minutes

### Disappearing Messages
- Set per-conversation in settings or conversation header
- Options: Off / 24 hours / 7 days
- Indicator shown in conversation header when active
- Messages show countdown timer near timestamp

### Presence Status
- **Online** (green): App open and active in last 5 minutes
- **Away** (amber): App backgrounded or inactive 5–30 minutes
- **Offline** (gray): App closed or inactive 30+ minutes

### Read Receipts
- Single gray tick `✓` — Message sent to server
- Double gray tick `✓✓` — Message delivered to device
- Double blue tick `✓✓` — Message read (conversation opened)
- In group chats: delivery tick only — no per-message read tracking in MVP

---

### Group Chat Patterns

**Creating a group:**
1. Tap `[+]` in Chat List nav → bottom sheet: "New Direct Message" / "New Group"
2. Tap "New Group" → Create Group screen
3. Enter group name + select 2+ doctors from org → tap checkmark
4. Group is created instantly, all members notified, thread opens

**Chat list appearance:**
- Group chats appear in the same Chats tab as direct messages
- Sorted by most recent message, same as direct chats
- Group avatar: stacked 2×2 grid (see 7.5)
- Preview text prefixed with sender name: `Dr. Mehta: Voice note · 0:18`
- Unread badge: same blue pill as direct chats

**Sender attribution in group threads:**
- Every received message shows the sender's name in their avatar color above the bubble
- Sender's SM avatar floats to the left of the bubble
- Your own sent messages have no name label

**Adding members:**
- Any group member can add new doctors from the same org
- New member sees full message history from the point they joined — not before

**Leaving a group:**
- A system message appears in the thread: `"Dr. Chen left the group"`
- System messages: centered, DM Sans 400 italic 12px `#8A9CC4`, no bubble

**Removing a member (creator only):**
- Long press on member in Group Info → "Remove from group"
- Confirmation dialog before removal
- System message in thread: `"Dr. Chen was removed from the group"`

---

## 10. Do Not

- No dark mode
- No gradients (except the blue header gradient on nav bar)
- No shadows heavier than `shadow-elevated`
- No font sizes below 11px
- No purple gradients or gradient buttons
- No cards nested inside cards
- No patient-facing UI elements
- No emoji in UI chrome (only in message content)
- No bottom tab bar icons that are generic (use text labels + line indicator)
- Never use Inter or Roboto — only Sora + DM Sans

---

*Doqto Design System v1.1 — Group Chat Update — Confidential — May 2026*
