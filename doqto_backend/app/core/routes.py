"""API route paths — mirrored in lib/core/constants/api_routes.dart on Flutter."""


class ApiPrefix:
    V1 = "/api/v1"
    AUTH = "/api/v1/auth"
    ORGS = "/api/v1/orgs"
    USERS = "/api/v1/users"
    CONVERSATIONS = "/api/v1/conversations"
    MESSAGES = "/api/v1/messages"
    ADMIN = "/api/v1/admin"
    NETWORK = "/api/v1/network"
    NOTIFICATIONS = "/api/v1/notifications"
    PEOPLE = "/api/v1/people"
    # Groups (M5) — mounted at the bare V1 prefix so it can also own the
    # sibling /group-invites and /me/groups surfaces.
    GROUPS = "/api/v1"
    BILLING = "/api/v1/billing"
    # Link previews (batch 4) — bare V1 prefix, single route.
    LINKS = "/api/v1"
    # Settings (batch 6)
    AUDIT = "/api/v1/audit"
    APP = "/api/v1/app"


class ApiRoutes:
    # Auth
    AUTH_FIREBASE = "/firebase"
    AUTH_REFRESH = "/refresh"
    AUTH_LOGOUT = "/logout"
    AUTH_REGISTER = "/register"
    # Two-step PIN (batch 6): verify on a new device / start the 7-day reset.
    AUTH_PIN_VERIFY = "/pin/verify"
    AUTH_PIN_RESET_REQUEST = "/pin/reset-request"

    # Orgs
    ORGS_CREATE = ""
    ORGS_JOIN = "/join"
    ORGS_MINE = "/mine"
    ORGS_DIRECTORY_SEARCH = "/directory/search"
    ORGS_DIRECTORY_SUGGESTED = "/directory/suggested"
    ORGS_DIRECTORY_JOIN = "/directory/join"
    ORGS_DETAIL = "/{org_id}"
    ORGS_MEMBERS = "/{org_id}/members"
    ORGS_MEMBER_DETAIL = "/{org_id}/members/{user_id}"
    ORGS_INVITE_CODE = "/{org_id}/invite-code"
    ORGS_NETWORKING_SETTINGS = "/{org_id}/settings/networking"
    # Compliance (batch 7)
    ORGS_POLICIES = "/{org_id}/policies"  # GET member / PATCH admin
    ORGS_AUDIT = "/{org_id}/audit"  # GET admin — members' actions on org resources
    ORGS_REPORTS = "/{org_id}/reports"  # GET admin — reports involving members
    ORGS_REPORT_DETAIL = "/{org_id}/reports/{report_id}"  # PATCH status
    ORGS_ACCESS_REQUESTS = "/{org_id}/access-requests"  # GET list / POST create
    ORGS_ACCESS_REQUEST_APPROVE = "/{org_id}/access-requests/{request_id}/approve"
    ORGS_ACCESS_REQUEST_REJECT = "/{org_id}/access-requests/{request_id}/reject"
    ORGS_ACCESS_REQUEST_MESSAGES = "/{org_id}/access-requests/{request_id}/messages"

    # Users
    USERS_ME_PHONE = "/me/phone"  # POST link (sign-up) / PATCH change (batch 6)
    # Settings (batch 6)
    USERS_NOTIFICATIONS = "/me/notifications"  # GET / PATCH tones, vibrate, previews
    USERS_SESSIONS = "/me/sessions"  # GET linked devices
    USERS_SESSION_DETAIL = "/me/sessions/{session_id}"  # DELETE revoke one
    USERS_SESSIONS_REVOKE_OTHERS = "/me/sessions/revoke-others"  # POST
    USERS_PIN = "/me/pin"  # PUT set / change, DELETE disable
    USERS_EXPORT = "/me/export"  # POST → presigned JSON (no messages)
    USERS_STATUS = "/me/status"  # PATCH preset / custom text + expiry
    USERS_PUSH_TOKENS = "/me/push-tokens"
    USERS_PRIVACY = "/me/privacy"
    USERS_PRESENCE = "/presence"  # ?ids=a,b,c (max 50) — privacy-filtered
    USERS_PROFILE = "/{user_id}/profile"  # public profile (M2) — no PHI

    # People search (M2) — cross-org directory surface
    PEOPLE_SEARCH = "/search"
    PEOPLE_NPI_LOOKUP = "/npi-lookup"
    PEOPLE_INVITES = "/invites"

    # Network (M1)
    NETWORK_INVITATIONS = "/invitations"
    NETWORK_INVITATION_ACCEPT = "/invitations/{invitation_id}/accept"
    NETWORK_INVITATION_IGNORE = "/invitations/{invitation_id}/ignore"
    NETWORK_INVITATION_DETAIL = "/invitations/{invitation_id}"
    NETWORK_CONNECTIONS = "/connections"
    NETWORK_CONNECTION_DETAIL = "/connections/{user_id}"
    NETWORK_CONNECTIONS_MUTUAL = "/connections/mutual/{user_id}"
    NETWORK_BLOCKS = "/blocks"
    NETWORK_BLOCK_DETAIL = "/blocks/{user_id}"
    NETWORK_MUTES = "/mutes"
    NETWORK_MUTE_DETAIL = "/mutes/{user_id}"
    NETWORK_REPORTS = "/reports"
    NETWORK_SUGGESTIONS = "/suggestions"
    NETWORK_SUGGESTION_DISMISS = "/suggestions/{user_id}/dismiss"

    # Notifications (M1)
    NOTIFICATIONS_LIST = ""
    NOTIFICATIONS_READ = "/read"
    NOTIFICATIONS_UNREAD_COUNT = "/unread-count"

    # Conversations
    CONVERSATIONS_LIST = ""
    # Total unread across the list, minus muted / archived chats (app icon badge).
    CONVERSATIONS_UNREAD_TOTAL = "/unread-total"
    CONVERSATIONS_CREATE = ""
    CONVERSATIONS_MESSAGES = "/{conversation_id}/messages"
    CONVERSATIONS_MESSAGES_SCHEDULE = "/{conversation_id}/messages/schedule"
    CONVERSATIONS_SCHEDULED = "/{conversation_id}/scheduled"  # GET my pending (batch 7)
    CONVERSATIONS_READ = "/{conversation_id}/read"
    CONVERSATIONS_DELIVERED = "/{conversation_id}/delivered"
    CONVERSATIONS_MEMBERS = "/{conversation_id}/members"
    CONVERSATIONS_MEMBER_DETAIL = "/{conversation_id}/members/{user_id}"
    CONVERSATIONS_SETTINGS = "/{conversation_id}/settings"
    # Per-member preferences: pin / archive / mute / mark unread / clear / delete.
    CONVERSATIONS_PREFS = "/{conversation_id}/prefs"
    CONVERSATIONS_PIN = "/{conversation_id}/pin"  # PUT pin / DELETE unpin (batch 4)
    # Media gallery (batch 5): GET ?type=image|video|file|link&cursor=&limit=
    CONVERSATIONS_MEDIA = "/{conversation_id}/media"
    # Message-request tier (M4) — recipient-only accept / decline.

    # Messages
    MESSAGES_READ = "/{message_id}/read"
    MESSAGES_DETAIL = "/{message_id}"  # PATCH edit / DELETE
    MESSAGES_EDITS = "/{message_id}/edits"
    MESSAGES_REACTION = "/{message_id}/reaction"  # PUT set / DELETE remove (own)
    MESSAGES_HIDE = "/hide"  # POST delete-for-me (batch)
    MESSAGES_FILE_URL = "/{message_id}/file-url"
    MESSAGES_RECEIPTS = "/{message_id}/receipts"  # sender-only read-by / delivered-to
    # Batch 4
    MESSAGES_FORWARD = "/{message_id}/forward"  # POST {conversation_ids}
    MESSAGES_STAR = "/{message_id}/star"  # PUT star / DELETE unstar (own, private)
    MESSAGES_STARRED = "/starred"  # GET my starred messages, all conversations
    LINK_PREVIEW = "/link-preview"  # GET ?url=
    # Batch 5 (media). The two legacy inline-upload routes stay:
    MESSAGES_UPLOAD = "/upload/{conversation_id}"  # POST multipart/form-data ≤ 25 MB
    MESSAGES_VOICE_NOTE = "/voice-notes/{conversation_id}"  # POST multipart/form-data
    # Presigned (multipart) upload for files / video up to 100 MB.
    MESSAGES_UPLOAD_INTENT = "/upload-intent/{conversation_id}"  # POST → urls
    MESSAGES_UPLOAD_COMPLETE = "/upload-complete/{conversation_id}"  # POST → MessageOut
    MESSAGES_EXPORT_AUDIT = "/{message_id}/export-audit"  # POST before save/share
    MESSAGES_VOTE = "/{message_id}/vote"  # PUT {option_ids} / DELETE (own votes)

    # Groups (M5) — router mounted at /api/v1 (see ApiPrefix.GROUPS).
    GROUPS_LIST = "/groups"
    GROUPS_CREATE = "/groups"
    GROUPS_DETAIL = "/groups/{group_id}"
    GROUPS_AVATAR = "/groups/{group_id}/avatar"
    GROUPS_INVITES = "/groups/{group_id}/invites"
    GROUPS_INVITE_DETAIL = "/groups/{group_id}/invites/{invite_id}"
    GROUPS_INVITE_ACCEPT = "/groups/{group_id}/invites/{invite_id}/accept"
    GROUPS_INVITE_DECLINE = "/groups/{group_id}/invites/{invite_id}/decline"
    GROUP_INVITE_TOKEN_ACCEPT = "/group-invites/{token}/accept"
    GROUPS_MEMBER_DETAIL = "/groups/{group_id}/members/{user_id}"
    GROUPS_MEMBERS = "/groups/{group_id}/members"
    GROUPS_MEMBER_BAN = "/groups/{group_id}/members/{user_id}/ban"
    GROUPS_TRANSFER_OWNERSHIP = "/groups/{group_id}/transfer-ownership"
    ME_GROUPS = "/me/groups"

    # Admin
    ADMIN_ORGS = "/orgs"
    ADMIN_VERIFY_ORG = "/orgs/{org_id}/verify"
    ADMIN_REJECT_ORG = "/orgs/{org_id}/reject"
    ADMIN_REPORTS = "/reports"  # GET moderation queue (super-admin)
    ADMIN_REPORT_DETAIL = "/reports/{report_id}"  # PATCH status
    ADMIN_AUDIT = "/audit"  # GET ?user_id=&action=&from=&to=&cursor= (batch 7)

    # WebSocket
    WS = "/ws"  # user-scoped socket (A1)
    WS_ORG = "/ws/{org_id}"  # legacy alias — path org ignored, one release only

    # Audit (batch 6) — client-detected events worth a row.
    AUDIT_SCREENSHOT = "/screenshot"  # POST {conversation_id}

    # App metadata (batch 6) — unauthenticated.
    APP_MIN_VERSION = "/min-version"
    APP_LEGAL = "/legal"

    # Scheduled messages (batch 7) — bare V1 prefix.
    SCHEDULED_DETAIL = "/scheduled/{scheduled_id}"  # DELETE cancel (own, pending)

    # Universal links / app links (batch 7) — root, unauthenticated.
    WELL_KNOWN_AASA = "/.well-known/apple-app-site-association"
    WELL_KNOWN_ASSETLINKS = "/.well-known/assetlinks.json"

    # Billing
    BILLING_STATUS = ""
    BILLING_CHECKOUT = "/checkout"
    BILLING_PORTAL = "/portal"
    BILLING_WEBHOOK = "/webhook"
    BILLING_APPLE = "/apple"
    BILLING_APPLE_NOTIFICATIONS = "/apple/notifications"
