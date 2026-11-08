"""Cross-stack enum contract. Wire values MUST match docs/enums.md and lib/core/enums/*.dart.

Python 3.11+ `StrEnum`: member value IS the wire string. A CI parity check
(`scripts/check_enum_parity.py`) verifies this file against docs/enums.md
and the Dart enums on every build.
"""

from enum import StrEnum


class UserRole(StrEnum):
    DOCTOR = "doctor"
    SUPER_ADMIN = "super_admin"


class OrgStatus(StrEnum):
    PENDING = "pending"
    ACTIVE = "active"
    SUSPENDED = "suspended"


class OrgRole(StrEnum):
    ADMIN = "admin"
    DOCTOR = "doctor"


class PracticeType(StrEnum):
    INDEPENDENT = "independent"
    SPECIALTY_GROUP = "specialty_group"
    COMMUNITY_HOSPITAL = "community_hospital"


class ConversationType(StrEnum):
    DIRECT = "direct"
    GROUP = "group"


class ConversationAccess(StrEnum):
    OPEN = "open"
    PENDING_REQUEST = "pending_request"
    DECLINED = "declined"


class ExternalDmPolicy(StrEnum):
    """Backend-only org admin policy — not mirrored in Dart (no client wire use)."""

    DISABLED = "disabled"
    CONNECTIONS_ONLY = "connections_only"
    CONNECTIONS_AND_REQUESTS = "connections_and_requests"


class DirectoryVisibility(StrEnum):
    """Backend-only org admin policy — not mirrored in Dart (no client wire use)."""

    ORG_ONLY = "org_only"
    NETWORK = "network"
    PUBLIC = "public"


class InvitationStatus(StrEnum):
    # Connection-invitation lifecycle (networking graph, M1).
    PENDING = "pending"
    ACCEPTED = "accepted"
    IGNORED = "ignored"
    WITHDRAWN = "withdrawn"
    EXPIRED = "expired"


class InvitePolicy(StrEnum):
    # Who may send me a connection invitation (user_privacy_settings, M1).
    EVERYONE = "everyone"
    SECOND_DEGREE = "second_degree"
    SHARED_GROUP_OR_ORG = "shared_group_or_org"
    NOBODY = "nobody"


class DmPolicy(StrEnum):
    # Who may open a direct conversation with me (user_privacy_settings, M1).
    EVERYONE = "everyone"
    CONNECTIONS_AND_REQUESTS = "connections_and_requests"
    CONNECTIONS_ONLY = "connections_only"
    NOBODY = "nobody"


class Discoverability(StrEnum):
    # Who may find me in search / view my profile (user_privacy_settings, M1).
    EVERYONE = "everyone"
    CONNECTIONS = "connections"
    NOBODY = "nobody"


class LastSeenVisibility(StrEnum):
    # Who may see when I was last online (user_privacy_settings, batch 2).
    # Reciprocal: a user who picks `nobody` sees nobody else's either.
    EVERYONE = "everyone"
    CONNECTIONS = "connections"
    NOBODY = "nobody"


class OnlineVisibility(StrEnum):
    # Whether my live "online" state follows my last-seen audience or is hidden.
    SAME_AS_LAST_SEEN = "same_as_last_seen"
    NOBODY = "nobody"


class ProfileFieldVisibility(StrEnum):
    # Who may see my profile photo / about text (user_privacy_settings, batch 2).
    EVERYONE = "everyone"
    CONNECTIONS = "connections"


class ReportReason(StrEnum):
    # Why a user or message is being reported (POST /network/reports). SHARED:
    # the client renders the reason picker from it.
    SPAM = "spam"
    HARASSMENT = "harassment"
    PHI_MISUSE = "phi_misuse"
    IMPERSONATION = "impersonation"
    OTHER = "other"


class ReportSubjectType(StrEnum):
    """Backend-only — what a report points at."""

    USER = "user"
    MESSAGE = "message"


class ReportStatus(StrEnum):
    """Moderation report lifecycle — backend-only (queue UI is M7). Set by
    super-admins via PATCH /admin/reports/{id}."""

    OPEN = "open"
    REVIEWING = "reviewing"
    ACTIONED = "actioned"
    DISMISSED = "dismissed"


class GroupRole(StrEnum):
    # SHARED (client renders role pills): §9.3 capability ladder.
    OWNER = "owner"
    ADMIN = "admin"
    MODERATOR = "moderator"
    MEMBER = "member"


class GroupPostPolicy(StrEnum):
    """Backend-only — who may post in the group conversation."""

    ALL_MEMBERS = "all_members"
    ADMINS_ONLY = "admins_only"


class GroupMemberDmPolicy(StrEnum):
    """Backend-only — whether a member may DM a co-member from group context."""

    OPEN = "open"
    REQUEST = "request"
    DISABLED = "disabled"


class GroupMemberState(StrEnum):
    """Client may render active/left; banned/removed are moderation states."""

    ACTIVE = "active"
    BANNED = "banned"
    LEFT = "left"
    REMOVED = "removed"


class GroupInviteState(StrEnum):
    """Backend-only — invite lifecycle (direct + link)."""

    PENDING = "pending"
    ACCEPTED = "accepted"
    DECLINED = "declined"
    REVOKED = "revoked"
    EXPIRED = "expired"


class MessageType(StrEnum):
    TEXT = "text"
    VOICE_NOTE = "voice_note"
    IMAGE = "image"
    FILE = "file"
    SYSTEM = "system"
    # Batch 5 (media): a video clip (poster thumbnail in thumb_key) and a poll
    # (question in the body, options/votes in poll_options / poll_votes).
    VIDEO = "video"
    POLL = "poll"


class TranscriptStatus(StrEnum):
    NONE = "none"
    PENDING = "pending"
    COMPLETED = "completed"
    FAILED = "failed"


class ScheduledMessageStatus(StrEnum):
    PENDING = "pending"
    SENT = "sent"
    FAILED = "failed"


class PresenceStatus(StrEnum):
    ONLINE = "online"
    AWAY = "away"
    OFFLINE = "offline"


class WsEventServer(StrEnum):
    NEW_MESSAGE = "new_message"
    TRANSCRIPT_READY = "transcript_ready"
    MESSAGE_DELIVERED = "message_delivered"
    MESSAGE_READ = "message_read"
    MESSAGE_EDITED = "message_edited"
    MESSAGE_DELETED = "message_deleted"
    MESSAGE_REACTED = "message_reacted"
    PRESENCE_UPDATE = "presence_update"
    MEMBER_ADDED = "member_added"
    MEMBER_REMOVED = "member_removed"
    SYSTEM_MESSAGE = "system_message"
    TYPING_START = "typing_start"
    TYPING_STOP = "typing_stop"
    HEARTBEAT_ACK = "heartbeat_ack"
    # Networking graph (M1) — recipient-scoped.
    INVITATION_RECEIVED = "invitation_received"
    INVITATION_ACCEPTED = "invitation_accepted"
    CONNECTION_REMOVED = "connection_removed"
    NOTIFICATION_CREATED = "notification_created"
    # Message-request tier (M4) — recipient-scoped. SHARED (client renders them).
    CONVERSATION_REQUEST_RECEIVED = "conversation_request_received"
    CONVERSATION_REQUEST_ACCEPTED = "conversation_request_accepted"
    CONVERSATION_REQUEST_DECLINED = "conversation_request_declined"
    # Groups (M5) — recipient-scoped. SHARED (client renders them).
    GROUP_INVITE_RECEIVED = "group_invite_received"
    GROUP_MEMBER_JOINED = "group_member_joined"
    # Realtime sync — recipient-scoped. Sent for every mutation another user
    # can observe so the client never has to poll.
    CONNECTED = "connected"
    INVITATION_WITHDRAWN = "invitation_withdrawn"
    ORG_UPDATED = "org_updated"
    GROUP_UPDATED = "group_updated"
    PROFILE_UPDATED = "profile_updated"
    # Conversation preferences (batch 3) — sent ONLY to the user's own devices.
    CONVERSATION_PREFS_UPDATED = "conversation_prefs_updated"
    # Message features (batch 4). Pin events go to every member; the star
    # event only to the actor's own devices (stars are private).
    MESSAGE_PINNED = "message_pinned"
    MESSAGE_UNPINNED = "message_unpinned"
    MESSAGE_STARRED = "message_starred"
    # Polls (batch 5) — every member: tallies + voter ids after a vote change.
    POLL_UPDATED = "poll_updated"
    # Settings (batch 6) — all sent ONLY to the user's own devices.
    SESSION_CREATED = "session_created"
    SESSION_REVOKED = "session_revoked"
    NOTIFICATION_SETTINGS_UPDATED = "notification_settings_updated"


class WsEventClient(StrEnum):
    HEARTBEAT = "heartbeat"
    TYPING_START = "typing_start"
    TYPING_STOP = "typing_stop"


class DevicePlatform(StrEnum):
    IOS = "ios"
    ANDROID = "android"


class JwtTokenType(StrEnum):
    ACCESS = "access"
    REFRESH = "refresh"


class AuditAction(StrEnum):
    LOGIN = "login"
    LOGOUT = "logout"
    REGISTER = "register"
    ACCOUNT_DELETED = "account_deleted"
    OTP_REQUESTED = "otp_requested"
    OTP_VERIFIED = "otp_verified"
    # Sign-in through a social provider (Google/Facebook/Apple) brokered by
    # Firebase. Phone sign-in keeps logging OTP_VERIFIED.
    SOCIAL_VERIFIED = "social_verified"
    ORG_CREATED = "org_created"
    ORG_JOINED = "org_joined"
    ORG_VERIFIED = "org_verified"
    ORG_POLICY_CHANGED = "org_policy_changed"
    MEMBER_REMOVED = "member_removed"
    CONVERSATION_CREATED = "conversation_created"
    CONVERSATION_ACCESSED = "conversation_accessed"
    GROUP_MEMBER_ADDED = "group_member_added"
    GROUP_MEMBER_LEFT = "group_member_left"
    GROUP_MEMBER_REMOVED = "group_member_removed"
    MESSAGE_SENT = "message_sent"
    MESSAGE_READ = "message_read"
    MESSAGE_EDITED = "message_edited"
    MESSAGE_DELETED = "message_deleted"
    FILE_UPLOADED = "file_uploaded"
    FILE_ACCESSED = "file_accessed"
    # Networking graph (M1)
    INVITATION_SENT = "invitation_sent"
    INVITATION_ACCEPTED = "invitation_accepted"
    INVITATION_IGNORED = "invitation_ignored"
    INVITATION_WITHDRAWN = "invitation_withdrawn"
    CONNECTION_REMOVED = "connection_removed"
    USER_BLOCKED = "user_blocked"
    USER_UNBLOCKED = "user_unblocked"
    REPORT_FILED = "report_filed"
    NETWORKING_POLICY_DENIED = "networking_policy_denied"
    # Message-request tier (M4) — backend-only (NOT in the parity SHARED set).
    MESSAGE_REQUEST_SENT = "message_request_sent"
    MESSAGE_REQUEST_ACCEPTED = "message_request_accepted"
    MESSAGE_REQUEST_DECLINED = "message_request_declined"
    # Groups (M5) — backend-only. GROUP_MEMBER_REMOVED (above) covers remove/ban.
    GROUP_CREATED = "group_created"
    GROUP_JOINED = "group_joined"
    GROUP_JOIN_APPROVED = "group_join_approved"
    GROUP_JOIN_REJECTED = "group_join_rejected"
    GROUP_ROLE_CHANGED = "group_role_changed"
    GROUP_OWNERSHIP_TRANSFERRED = "group_ownership_transferred"
    GROUP_INVITE_SENT = "group_invite_sent"
    GROUP_INVITE_ACCEPTED = "group_invite_accepted"
    MESSAGE_RECEIPTS_READ = "message_receipts_read"
    # Privacy screen (batch 2) — backend-only.
    PRIVACY_UPDATED = "privacy_updated"
    # Conversation preferences (batch 3) — backend-only.
    CONVERSATION_PREFS_UPDATED = "conversation_prefs_updated"
    # Message features (batch 4) — backend-only.
    MESSAGE_FORWARDED = "message_forwarded"
    MESSAGE_PINNED = "message_pinned"
    MESSAGE_UNPINNED = "message_unpinned"
    STARRED_MESSAGES_READ = "starred_messages_read"
    REPORT_STATUS_CHANGED = "report_status_changed"
    LINK_PREVIEW_FETCHED = "link_preview_fetched"
    # Media (batch 5) — backend-only.
    FILE_EXPORTED = "file_exported"
    POLL_VOTED = "poll_voted"
    # Settings (batch 6) — backend-only.
    SCREENSHOT_TAKEN = "screenshot_taken"
    NOTIFICATION_SETTINGS_UPDATED = "notification_settings_updated"
    SESSION_REVOKED = "session_revoked"
    PHONE_CHANGED = "phone_changed"
    PIN_SET = "pin_set"
    PIN_REMOVED = "pin_removed"
    PIN_VERIFIED = "pin_verified"
    PIN_RESET_REQUESTED = "pin_reset_requested"
    PIN_RESET_COMPLETED = "pin_reset_completed"
    ACCOUNT_EXPORTED = "account_exported"
    STATUS_UPDATED = "status_updated"


class TranscribeSpecialty(StrEnum):
    PRIMARYCARE = "PRIMARYCARE"
    CARDIOLOGY = "CARDIOLOGY"
    RADIOLOGY = "RADIOLOGY"
    NEUROLOGY = "NEUROLOGY"
    UROLOGY = "UROLOGY"


class StatusPreset(StrEnum):
    # SHARED (batch 6): the status under a doctor's name. Stored as the wire
    # value in users.status_text; anything else there is custom text.
    ON_CALL = "on_call"
    IN_CLINIC = "in_clinic"
    IN_SURGERY = "in_surgery"
    OFF_DUTY = "off_duty"
    AVAILABLE = "available"


class VibratePattern(StrEnum):
    # SHARED (batch 6): notification vibration (Android only; iOS ignores it).
    DEFAULT = "default"
    SHORT = "short"
    LONG = "long"
    OFF = "off"
