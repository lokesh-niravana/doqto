"""TTLs, limits, and other magic numbers — defined ONCE. No inline numbers in services."""

# JWT lifetimes
ACCESS_TOKEN_TTL_SECONDS = 60 * 60  # 1 hour
REFRESH_TOKEN_TTL_SECONDS = 60 * 60 * 24 * 7  # 7 days


# Presence
PRESENCE_ONLINE_TTL_SECONDS = 60 * 5  # 5 minutes
PRESENCE_AWAY_TTL_SECONDS = 60 * 30  # 30 minutes
WS_HEARTBEAT_INTERVAL_SECONDS = 60
# Server drops a socket silent for 2 missed heartbeats + grace. Must match
# AppConstants.wsHeartbeatTimeout (130s) on the Flutter side.
WS_HEARTBEAT_TIMEOUT_SECONDS = WS_HEARTBEAT_INTERVAL_SECONDS * 2 + 10

# Presigned URL
PRESIGNED_URL_TTL_SECONDS = 60 * 5  # 5 minutes

# Pagination
MESSAGES_PAGE_SIZE = 50
# Sender may edit a text message / delete any message this long after sending.
MESSAGE_EDIT_WINDOW_SEC = 5 * 60
MESSAGE_DELETE_WINDOW_SEC = 3 * 60
MESSAGE_DELETED_PREVIEW = "This message was deleted"
MEMBERS_PAGE_SIZE = 100

# Voice notes
VOICE_NOTE_MIN_DURATION_SECONDS = 1
VOICE_NOTE_MAX_DURATION_SECONDS = 60 * 5  # 5 minutes
VOICE_NOTE_MAX_FILE_BYTES = 10 * 1024 * 1024  # 10 MB

# Files
FILE_MAX_BYTES = 25 * 1024 * 1024  # 25 MB

# Avatars
AVATAR_MAX_BYTES = 2 * 1024 * 1024  # 2 MB
AVATAR_ALLOWED_MIME = frozenset({"image/jpeg", "image/png", "image/webp"})
AVATAR_ALLOWED_EXT = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}

# Profile validation
BIO_MAX_LEN = 500
SKILLS_MAX_COUNT = 20
SKILL_MAX_LEN = 40
YEARS_OF_EXPERIENCE_MIN = 0
YEARS_OF_EXPERIENCE_MAX = 80

# Invite codes
INVITE_CODE_FORMAT = "XXXX·NNNN"  # 4 letters + middle dot + 4 digits
INVITE_CODE_LETTERS_LEN = 4
INVITE_CODE_DIGITS_LEN = 4

# Rate limiting (requests per minute per user per endpoint)
RATE_LIMIT_DEFAULT_PER_MINUTE = 60
# Sign-in attempts per IP per hour. /auth/firebase is the only
# unauthenticated endpoint, and a valid token still costs a DB write.
RATE_LIMIT_SIGNIN_PER_HOUR = 20
# Read endpoints (message history, file URLs, member list) — generous.
RATE_LIMIT_READS_PER_MINUTE = 120
# Admin login lockout: attempts per email per window.
ADMIN_LOGIN_MAX_ATTEMPTS = 5
ADMIN_LOGIN_WINDOW_SECONDS = 15 * 60


# Push notifications — PHI-free by policy: these strings are sent verbatim to
# Apple/Google. NEVER interpolate user data (names, message content, phone
# numbers) into push title/body.
PUSH_TITLE = "Doqto"
PUSH_BODY_NEW_MESSAGE = "New message"
# Message-request push copy — generic, PHI-free, NO content/preview ever (M4).

# Chat list preview
CHAT_LIST_PREVIEW_MAX_LEN = 140

# --- Networking graph (M1) ------------------------------------------------- #
# Redis caches for the social graph.
NET_FD_TTL_SECONDS = 60 * 60 * 24  # first-degree set, lazy-rebuilt on miss
NET_SD_TTL_SECONDS = 60 * 10  # second-degree set, computed on demand
ORG_POLICY_CACHE_TTL_SECONDS = 60  # org networking policy snapshot
SECOND_DEGREE_LIMIT = 500  # cap the fan-out; no third degree ever
MUTUAL_CONNECTIONS_DEFAULT_LIMIT = 20

# Invitation quotas (via enforce_rate_limit — two stacked windows).
INVITE_QUOTA_PER_DAY = 50
INVITE_QUOTA_PER_WEEK = 100

# Invitation re-send cooldowns (days) — measured from the last terminal event.
COOLDOWN_IGNORED_DAYS = 21
COOLDOWN_WITHDRAWN_DAYS = 3
COOLDOWN_REMOVED_DAYS = 30

# Invitation message length (spec: short note).
INVITATION_MESSAGE_MAX_LEN = 300

# People/network read limits.
NETWORK_PAGE_SIZE = 30
REPORT_DETAILS_MAX_LEN = 1000

# --- Message-request tier (M4) --------------------------------------------- #
# The initiator may send exactly ONE opening message, capped at this length,
# text-only, no contact info (URL/phone) — see spam_heuristics.
# Message-request quota: how many new requests one sender may open per day.
# Spam scoring for hiding a request (compute-on-read; no migration). A request
# is "hidden" (no push, no badge) when its score reaches the threshold.
#   +1 opening message contains a URL/phone   (unreachable via the send guard,
#       which rejects such messages — kept for completeness + invitation reuse)
#   +1 sender account younger than this many days
#   +1 no shared context (no shared org AND no mutual connections)
#
# Threshold 3 (not 2) deliberately: "new account, no shared context" IS the
# request tier's whole reason to exist — a doctor who just joined reaching a
# colleague they haven't met. At 2 those two benign signals alone buried every
# legitimate first outreach with no badge and no notification, which read as
# the feature being broken. Nothing scores 3 today (the send guard rejects
# contact info before it can count), so nothing is hidden until M7 adds real
# velocity/reputation signals — that is the honest state, not an oversight.
NEW_ACCOUNT_REQUEST_DAYS = 7
REQUEST_HIDDEN_THRESHOLD = 3

# --- People search + public profiles (M2) ---------------------------------- #
# Cross-org directory surface. Cards/profiles NEVER expose phone/email/NPI.
PEOPLE_SEARCH_PER_MINUTE = 60  # rate limit on GET /people/search
PEOPLE_SEARCH_PAGE_SIZE = 20  # default page limit
PEOPLE_SEARCH_MAX_LIMIT = 50  # hard cap on the client-supplied limit
# Deterministic ranking weights (trgm similarity + graph/org boosts). No ML.
SEARCH_DEGREE_BOOST_FIRST = 0.5
SEARCH_DEGREE_BOOST_SECOND = 0.25
SEARCH_SAME_ORG_BOOST = 0.3

# Profile handle: lowercase slug, [a-z0-9_], 3–30 chars, globally unique.
HANDLE_MIN_LEN = 3
HANDLE_MAX_LEN = 30
HANDLE_PATTERN = r"^[a-z0-9_]{3,30}$"
HEADLINE_MAX_LEN = 120

# Disappearing messages — allowed timer values (seconds → human label).
# Mirror of the option list in the Flutter chat details screen.
DISAPPEAR_OPTIONS_SEC = {
    60 * 60 * 24: "24 hours",
    60 * 60 * 24 * 7: "7 days",
    60 * 60 * 24 * 30: "30 days",
    60 * 60 * 24 * 90: "90 days",
}
# --- Groups (M5) ----------------------------------------------------------- #
GROUP_NAME_MAX_LEN = 100
GROUP_DESCRIPTION_MAX_LEN = 1000
# Group creation quotas (via enforce_rate_limit + an active-ownership cap).
GROUP_CREATE_QUOTA_PER_DAY = 5
GROUP_MAX_OWNED = 20  # max groups a user may actively own at once
# A rejected join request cannot be re-submitted for this many days.
GROUP_REJOIN_COOLDOWN_DAYS = 14
GROUPS_PAGE_SIZE = 30
# Link-invite token length (url-safe).
GROUP_INVITE_TOKEN_BYTES = 24

DISAPPEAR_PURGE_INTERVAL_SEC = 60
SCHEDULED_SEND_INTERVAL_SEC = 15  # delivery granularity for scheduled messages
# Hard-delete grace: content of soft-deleted/expired messages is crypto-shredded
# (encrypted blobs nulled, S3 objects deleted) once older than this.
PURGE_CONTENT_GRACE_SEC = 30 * 24 * 3600  # 30 days
