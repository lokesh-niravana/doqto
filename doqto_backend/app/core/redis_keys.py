"""Redis key builders. Never f-string a Redis key inline — always use these."""

from uuid import UUID


def presence_key(user_id: UUID | str) -> str:
    return f"presence:{user_id}"





def session_key(jti: str) -> str:
    """Access-token session (TTL = ACCESS_TOKEN_TTL_SECONDS)."""
    return f"session:{jti}"


def refresh_session_key(jti: str) -> str:
    """Refresh-token session (TTL = REFRESH_TOKEN_TTL_SECONDS). Access and
    refresh tokens of a pair share the jti but must expire independently."""
    return f"session_refresh:{jti}"


def unread_key(user_id: UUID | str, conversation_id: UUID | str) -> str:
    return f"unread:{user_id}:{conversation_id}"


def ws_connections_key(org_id: UUID | str) -> str:
    return f"ws_connections:{org_id}"


def rate_limit_key(user_id: UUID | str, endpoint: str) -> str:
    return f"rate_limit:{user_id}:{endpoint}"


def first_degree_key(user_id: UUID | str) -> str:
    """Set of a user's first-degree connection ids (networking graph, M1)."""
    return f"net:fd:{user_id}"


def second_degree_key(user_id: UUID | str) -> str:
    """Cached second-degree connection ids (computed on demand, TTL'd — M1)."""
    return f"net:sd:{user_id}"


def org_policy_key(org_id: UUID | str) -> str:
    """Cached org networking policy (kill switch / DM policy — M1)."""
    return f"org:policy:{org_id}"


# Pub/sub channel for cross-instance WebSocket fanout.
WS_EVENTS_CHANNEL = "ws:events"


def purge_lock_key() -> str:
    """Singleton lock so only one replica runs the disappearing-message purge."""
    return "lock:purge_expired"


def scheduled_send_lock_key() -> str:
    """Singleton lock so only one replica delivers due scheduled messages."""
    return "lock:scheduled_send"
