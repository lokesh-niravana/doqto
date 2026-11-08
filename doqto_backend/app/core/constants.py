"""TTLs, limits, and other magic numbers — defined ONCE. No inline numbers in services."""

from datetime import datetime, timezone

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

# users.last_seen_at is written at most this often per connected user (WS
# connect + heartbeats are throttled through Redis; disconnect always writes).
LAST_SEEN_WRITE_INTERVAL_SECONDS = 60
# GET /users/presence?ids= accepts at most this many ids per call.
PRESENCE_QUERY_MAX_IDS = 50
RATE_LIMIT_PRIVACY_WRITES_PER_MINUTE = 30

# Presigned URL
PRESIGNED_URL_TTL_SECONDS = 60 * 5  # 5 minutes

# Pagination
MESSAGES_PAGE_SIZE = 50
# Sender may edit a text message / delete any message this long after sending
# (batch 4: 15 min / 48 h). Group admins deleting a member's message are not
# window-bound (moderation).
MESSAGE_EDIT_WINDOW_SEC = 15 * 60
MESSAGE_DELETE_WINDOW_SEC = 48 * 3600
ADMIN_REMOVED_MESSAGE_TEXT = "Admin removed a message"
MESSAGE_REACTION_MAX_BYTES = 32  # one emoji grapheme cluster, UTF-8
RATE_LIMIT_REACTIONS_PER_MINUTE = 60
MESSAGE_DELETED_PREVIEW = "This message was deleted"
MEMBERS_PAGE_SIZE = 100

# --- Message features (batch 4) -------------------------------------------- #
# Reply quote rendered live from the target row; text is truncated to this.
REPLY_PREVIEW_MAX_LEN = 140
REPLY_PREVIEW_DELETED = "Message deleted"
# Forward: destinations per call, and the hop count at which a message is
# "Forwarded many times" and can no longer be forwarded.
FORWARD_MAX_DESTINATIONS = 5
FORWARD_MAX_DEPTH = 5
RATE_LIMIT_FORWARDS_PER_MINUTE = 20
# Star / pin.
STARRED_PAGE_SIZE = 50
RATE_LIMIT_STARS_PER_MINUTE = 60
RATE_LIMIT_PINS_PER_MINUTE = 20
PIN_DURATIONS_SEC = {
    60 * 60 * 24: "24 hours",
    60 * 60 * 24 * 7: "7 days",
    60 * 60 * 24 * 30: "30 days",
}
# Mentions: `@[<user uuid>]` tokens in a text body.
MENTION_TOKEN_PATTERN = r"@\[([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\]"
MENTIONS_MAX_PER_MESSAGE = 50
# Link previews: server-side fetch with an SSRF guard.
LINK_PREVIEW_TIMEOUT_SEC = 5
LINK_PREVIEW_MAX_BYTES = 1024 * 1024  # 1 MB HTML cap
LINK_PREVIEW_IMAGE_MAX_BYTES = 50 * 1024  # inlined as base64
LINK_PREVIEW_MAX_REDIRECTS = 3
LINK_PREVIEW_CACHE_TTL_SEC = 24 * 3600
LINK_PREVIEW_TEXT_MAX_LEN = 300
RATE_LIMIT_LINK_PREVIEWS_PER_MINUTE = 30
# Reports: the reporter's last N message ids (never bodies) for moderators.
REPORT_CONTEXT_MAX_IDS = 5
REPORTS_PAGE_SIZE = 50
# Org policies (organizations.policies JSONB) and their defaults.
ORG_POLICY_ALLOW_FORWARD_OUTSIDE_ORG = "allow_forward_outside_org"
ORG_POLICY_ALLOW_COPY = "allow_copy"
# Batch 7 (compliance): banner previews default for members, the timer every
# new org group chat starts with, retention (days; None = keep forever) and
# the legal hold that pauses every shred for the org's conversations.
ORG_POLICY_SHOW_PREVIEW_IN_BANNERS_DEFAULT = "show_preview_in_banners_default"
ORG_POLICY_DEFAULT_DISAPPEAR_SEC = "default_disappear_sec"
ORG_POLICY_RETENTION_DAYS = "retention_days"
ORG_POLICY_LEGAL_HOLD = "legal_hold"
ORG_POLICY_DEFAULTS = {
    ORG_POLICY_ALLOW_FORWARD_OUTSIDE_ORG: True,
    ORG_POLICY_ALLOW_COPY: True,
    # Batch 5 — key defined below (ORG_POLICY_ALLOW_MEDIA_EXPORT).
    "allow_media_export": False,
    # Batch 6 — key defined below (ORG_POLICY_BLOCK_SCREENSHOTS).
    "block_screenshots": False,
    ORG_POLICY_SHOW_PREVIEW_IN_BANNERS_DEFAULT: False,
    ORG_POLICY_DEFAULT_DISAPPEAR_SEC: None,
    ORG_POLICY_RETENTION_DAYS: None,
    ORG_POLICY_LEGAL_HOLD: False,
}
ORG_POLICY_BOOL_KEYS = (
    ORG_POLICY_ALLOW_FORWARD_OUTSIDE_ORG,
    ORG_POLICY_ALLOW_COPY,
    "allow_media_export",
    "block_screenshots",
    ORG_POLICY_SHOW_PREVIEW_IN_BANNERS_DEFAULT,
    ORG_POLICY_LEGAL_HOLD,
)
RETENTION_DAYS_MIN = 1
RETENTION_DAYS_MAX = 365 * 10
RATE_LIMIT_POLICY_WRITES_PER_MINUTE = 20

# --- Compliance (batch 7) -------------------------------------------------- #
# Break-glass: an approved request lets the requester read for this long.
ACCESS_REQUEST_WINDOW_SEC = 24 * 3600
ACCESS_REQUEST_REASON_MAX_LEN = 500
ACCESS_REQUESTS_PAGE_SIZE = 50
RATE_LIMIT_ACCESS_REQUESTS_PER_MINUTE = 10
BREAK_GLASS_SYSTEM_TEXT = "An administrator accessed this conversation under policy"
PUSH_BODY_ACCESS_REQUEST_PENDING = "An access request needs your review"
PUSH_BODY_ACCESS_REQUEST_APPROVED = "Your access request was approved"
PUSH_BODY_ACCESS_REQUEST_REJECTED = "Your access request was rejected"
# Audit read API.
AUDIT_PAGE_SIZE = 100
RATE_LIMIT_AUDIT_READS_PER_MINUTE = 60
# Universal links / app links served from /.well-known.
APPLE_TEAM_ID = "3N7394B3B9"
APPLE_APP_BUNDLE_ID = "com.doqto.ios"
UNIVERSAL_LINK_PATHS = ("/g/*", "/c/*", "/u/*")
ANDROID_PACKAGE_NAME = "com.doqto.app"
# Play App Signing SHA-256 fingerprints — filled in by ops; empty until then.
ANDROID_CERT_SHA256_FINGERPRINTS: tuple[str, ...] = ()

# Voice notes
VOICE_NOTE_MIN_DURATION_SECONDS = 1
VOICE_NOTE_MAX_DURATION_SECONDS = 60 * 5  # 5 minutes
VOICE_NOTE_MAX_FILE_BYTES = 10 * 1024 * 1024  # 10 MB
# Amplitude envelope recorded by the client: raw bytes (0–255 per sample),
# sent base64 — at most this many samples.
VOICE_NOTE_WAVEFORM_MAX_BYTES = 64

# --- Files / media (batch 5) ----------------------------------------------- #
# Hard cap for any attachment (file or video) through the presigned
# multipart flow (upload-intent / upload-complete).
FILE_MAX_BYTES = 100 * 1024 * 1024  # 100 MB
VIDEO_MAX_BYTES = FILE_MAX_BYTES
# The legacy inline route (POST /messages/upload/{conv}) reads the body into
# memory, so it keeps a smaller cap; bigger payloads use the multipart flow.
UPLOAD_INLINE_MAX_BYTES = 25 * 1024 * 1024  # 25 MB
# Multipart: S3 needs ≥ 5 MB per part (except the last); single presigned PUT
# below this size.
UPLOAD_PART_SIZE_BYTES = 8 * 1024 * 1024  # 8 MB
UPLOAD_MULTIPART_THRESHOLD_BYTES = UPLOAD_PART_SIZE_BYTES
UPLOAD_INTENT_TTL_SEC = 60 * 60  # an intent not completed within an hour is aborted
UPLOAD_URL_TTL_SEC = UPLOAD_INTENT_TTL_SEC
RATE_LIMIT_UPLOAD_INTENTS_PER_MINUTE = 30
# Poster thumbnail (video) / client-supplied JPEG — always EXIF-stripped.
THUMB_MAX_BYTES = 300 * 1024  # 300 KB
THUMB_CONTENT_TYPE = "image/jpeg"
CAPTION_MAX_LEN = 1024
VIDEO_MAX_DURATION_SEC = 60 * 10  # 10 minutes
MEDIA_PAGE_SIZE = 60
# Links tab: text messages are scanned (decrypted) newest first in batches of
# this size; at most LINK_SCAN_MAX_MESSAGES per request before the page is
# returned (possibly short) with a cursor.
LINK_SCAN_BATCH = 200
LINK_SCAN_MAX_MESSAGES = 2000
URL_PATTERN = r"https?://[^\s<>\"'()\[\]{}]+"
# Save to Photos / share sheet gate (organizations.policies): off for org
# members unless the admin enables it; users with no org may export.
ORG_POLICY_ALLOW_MEDIA_EXPORT = "allow_media_export"
RATE_LIMIT_EXPORT_AUDITS_PER_MINUTE = 60
# Polls
POLL_QUESTION_MAX_LEN = 300
POLL_OPTION_MAX_LEN = 100
POLL_OPTIONS_MIN = 2
POLL_OPTIONS_MAX = 12
RATE_LIMIT_VOTES_PER_MINUTE = 60

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
# Mention push: "<name> mentioned you in <group>" — a doctor's name and a group
# name are directory data, not PHI. Never the message text.
PUSH_BODY_MENTION_FALLBACK = "You were mentioned"
# Message-request push copy — generic, PHI-free, NO content/preview ever (M4).

# --- Conversation preferences (batch 3) ------------------------------------ #
# At most this many pinned chats per user (409 pin_limit beyond it).
PINNED_CONVERSATIONS_MAX = 3
RATE_LIMIT_PREFS_WRITES_PER_MINUTE = 60
# muted_until at or beyond this instant means "always" (no expiry).
MUTE_ALWAYS_UNTIL = datetime(9999, 12, 31, tzinfo=timezone.utc)

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

# "Recommended for you" (GET /network/suggestions). Points per signal.
SUGGEST_COLLEAGUE = 100
SUGGEST_PER_MUTUAL = 20
SUGGEST_MUTUAL_CAP = 5
SUGGEST_SAME_SPECIALTY = 10
SUGGEST_SAME_STATE = 5
SUGGEST_SAME_CITY = 5
SUGGEST_NEW_MEMBER = 3
SUGGEST_NEW_MEMBER_DAYS = 30
SUGGEST_PAGE_SIZE = 10

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
# Hard cap on ACTIVE members per group — enforced on invite, invite accept and
# link accept (409 group_full). WhatsApp-scale, not a channel.
GROUP_MAX_MEMBERS = 256

DISAPPEAR_PURGE_INTERVAL_SEC = 60
SCHEDULED_SEND_INTERVAL_SEC = 15  # delivery granularity for scheduled messages
# Hard-delete grace: content of soft-deleted/expired messages is crypto-shredded
# (encrypted blobs nulled, S3 objects deleted) once older than this.
PURGE_CONTENT_GRACE_SEC = 30 * 24 * 3600  # 30 days

# --- Settings (batch 6) ---------------------------------------------------- #
# Notification tones: bundled CAF files on iOS (ios/Runner/Resources/<tone>.caf)
# and raw resources on Android. "default" = the system sound. The server only
# validates the name and puts it in aps.sound; it never ships the file.
NOTIFICATION_TONES = frozenset(
    {
        "default",
        "chime",
        "pulse",
        "ping",
        "bell",
        "glass",
        "note",
        "pop",
        "ripple",
        "signal",
        "tap",
        "whistle",
        "none",
    }
)
NOTIFICATION_TONE_DEFAULT = "default"
# FCM Android notification channels — created by the app on first launch.
PUSH_CHANNEL_MESSAGES = "messages"
PUSH_CHANNEL_GROUPS = "groups"
PUSH_CHANNEL_INVITATIONS = "invitations"
RATE_LIMIT_NOTIFICATION_SETTINGS_PER_MINUTE = 30
# Screenshot audit (iOS detects, Android blocks behind the org policy).
ORG_POLICY_BLOCK_SCREENSHOTS = "block_screenshots"
RATE_LIMIT_SCREENSHOT_AUDITS_PER_MINUTE = 30
# Sessions / linked devices.
DEVICE_NAME_MAX_LEN = 80
APP_VERSION_MAX_LEN = 32
RATE_LIMIT_SESSION_WRITES_PER_MINUTE = 20
PUSH_BODY_NEW_SIGN_IN_FALLBACK = "New sign-in on another device"
# Two-step verification PIN: exactly 6 digits, bcrypt-hashed. Verification
# attempts are capped per user; the forgot-PIN cooldown clears the PIN after
# PIN_RESET_COOLDOWN_SEC with no code of ours in an email or SMS.
PIN_LENGTH = 6
RATE_LIMIT_PIN_VERIFY_PER_15_MIN = 5
PIN_VERIFY_WINDOW_SEC = 15 * 60
RATE_LIMIT_PIN_WRITES_PER_MINUTE = 10
PIN_RESET_COOLDOWN_SEC = 7 * 24 * 3600
# Account info export: JSON (no messages) to S3, handed back as a short URL.
EXPORT_URL_TTL_SEC = 10 * 60
RATE_LIMIT_EXPORTS_PER_HOUR = 3
# Status under the name: preset wire value or custom text, with an expiry.
STATUS_CUSTOM_MAX_LEN = 40
STATUS_EXPIRY_OPTIONS_SEC = {
    60 * 60: "1 hour",
    8 * 60 * 60: "8 hours",
    24 * 60 * 60: "24 hours",
}
RATE_LIMIT_STATUS_WRITES_PER_MINUTE = 30
RATE_LIMIT_PHONE_CHANGES_PER_HOUR = 5
# Legal / help links served by GET /app/legal so the app never hard-codes them.
LEGAL_URLS = {
    "help": "https://doqto.ai/help",
    "contact": "mailto:support@doqto.ai",
    "terms": "https://doqto.ai/terms",
    "privacy": "https://doqto.ai/privacy",
    "hipaa": "https://doqto.ai/hipaa",
}
