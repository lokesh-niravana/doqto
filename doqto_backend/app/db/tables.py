"""Single source of truth for table names. ORM models + Alembic migrations + raw SQL all reference these."""


class Tables:
    ORGANIZATIONS = "organizations"
    USERS = "users"
    ORG_MEMBERS = "org_members"
    # Public directory of US practices (CMS / NPPES), refreshed by
    # scripts/import_org_directory.py
    ORG_DIRECTORY = "org_directory"
    ORG_DIRECTORY_MEMBERS = "org_directory_members"
    CONVERSATIONS = "conversations"
    CONVERSATION_MEMBERS = "conversation_members"
    DIRECT_CONVERSATION_KEYS = "direct_conversation_keys"
    MESSAGES = "messages"
    SCHEDULED_MESSAGES = "scheduled_messages"
    MESSAGE_RECEIPTS = "message_receipts"
    MESSAGE_EDITS = "message_edits"
    MESSAGE_HIDES = "message_hides"
    AUDIT_LOGS = "audit_logs"
    DEVICE_TOKENS = "device_tokens"
    # Networking graph (M1)
    CONNECTION_INVITATIONS = "connection_invitations"
    CONNECTIONS = "connections"
    CONNECTION_REMOVALS = "connection_removals"
    BLOCKS = "blocks"
    MUTES = "mutes"
    SUGGESTION_DISMISSALS = "suggestion_dismissals"
    REPORTS = "reports"
    USER_PRIVACY_SETTINGS = "user_privacy_settings"
    NOTIFICATIONS = "notifications"
    # Groups (M5)
    GROUPS = "groups"
    GROUP_MEMBERS = "group_members"
    GROUP_INVITES = "group_invites"
