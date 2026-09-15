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


class ReportStatus(StrEnum):
    """Moderation report lifecycle — backend-only (queue UI is M7)."""

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


class TranscribeSpecialty(StrEnum):
    PRIMARYCARE = "PRIMARYCARE"
    CARDIOLOGY = "CARDIOLOGY"
    RADIOLOGY = "RADIOLOGY"
    NEUROLOGY = "NEUROLOGY"
    UROLOGY = "UROLOGY"
