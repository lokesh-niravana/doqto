"""Central relationship permission module (A4) — PURE, no I/O.

This is the security boundary for the networking layer. Every function takes a
fully-materialised RelationshipContext (built by relationship_service from
Redis + Postgres) and returns a Decision. Because it is pure, it is unit-tested
to 100% branch coverage in tests/test_permissions.py.

Binding rules (from the spec §6.3 decision table, adapted):
  1. Blocks come first — a block in EITHER direction denies silently
     (mode='denied'); the caller translates that into a generic
     "user_unavailable" so a block is never observable.
  2. **Same-org colleagues always resolve to mode='open'** for messaging and
     are always allowed to view/invite/add — regardless of connection state.
     This preserves today's org-chat behaviour byte-for-byte (acceptance
     test 6) and is checked BEFORE any external-networking gate.
  3. External (cross-org) paths require external networking enabled for BOTH
     parties' orgs; otherwise denied('networking_disabled').
  4. Message request tier: a stranger who is allowed to reach out but is not a
     connection resolves to mode='request' (message request), not 'open'.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal
from uuid import UUID

from app.core.enums import (
    Discoverability,
    DmPolicy,
    InvitePolicy,
    LastSeenVisibility,
    OnlineVisibility,
    ProfileFieldVisibility,
)

Mode = Literal["open", "request", "denied"]


@dataclass(frozen=True)
class PrivacySnapshot:
    """A user's effective privacy settings (defaults applied by the loader)."""

    invite_policy: InvitePolicy = InvitePolicy.EVERYONE
    dm_policy: DmPolicy = DmPolicy.CONNECTIONS_AND_REQUESTS
    discoverability: Discoverability = Discoverability.EVERYONE
    show_mutual_connections: bool = True
    # Batch 2 — presence + profile-field visibility.
    last_seen_visibility: LastSeenVisibility = LastSeenVisibility.CONNECTIONS
    online_visibility: OnlineVisibility = OnlineVisibility.SAME_AS_LAST_SEEN
    profile_photo_visibility: ProfileFieldVisibility = ProfileFieldVisibility.EVERYONE
    about_visibility: ProfileFieldVisibility = ProfileFieldVisibility.EVERYONE
    read_receipts: bool = True


@dataclass(frozen=True)
class RelationshipContext:
    viewer_id: UUID
    target_id: UUID
    shared_org_ids: frozenset[UUID] = frozenset()
    is_first_degree: bool = False
    is_blocked_either_way: bool = False
    viewer_privacy: PrivacySnapshot = field(default_factory=PrivacySnapshot)
    target_privacy: PrivacySnapshot = field(default_factory=PrivacySnapshot)
    external_networking_enabled_for_both: bool = True
    target_account_age_days: int = 3650
    has_pending_invitation: bool = False
    existing_conversation_access: str | None = None
    # Best member_dm_policy across the groups BOTH are active members of
    # ('open' | 'request' | 'denied'); None when they share no group. Loaded by
    # relationship_service via GroupService.group_dm_decision (M5 §9.4).
    shared_group_dm_mode: str | None = None


@dataclass(frozen=True)
class Decision:
    allowed: bool
    mode: Mode
    reason: str

    @staticmethod
    def open(reason: str = "ok") -> "Decision":
        return Decision(allowed=True, mode="open", reason=reason)

    @staticmethod
    def request(reason: str = "message_request") -> "Decision":
        return Decision(allowed=True, mode="request", reason=reason)

    @staticmethod
    def denied(reason: str) -> "Decision":
        return Decision(allowed=False, mode="denied", reason=reason)


def _is_colleague(ctx: RelationshipContext) -> bool:
    return bool(ctx.shared_org_ids)


# --------------------------------------------------------------------------- #
# Profile visibility
# --------------------------------------------------------------------------- #
def can_view_profile(ctx: RelationshipContext) -> Decision:
    if ctx.is_blocked_either_way:
        return Decision.denied("blocked")
    # Colleagues and connections can always see each other (regression rule).
    if _is_colleague(ctx) or ctx.is_first_degree:
        return Decision.open("colleague_or_connection")
    disc = ctx.target_privacy.discoverability
    if disc == Discoverability.EVERYONE:
        return Decision.open("discoverable")
    # 'connections' and 'nobody' both fail here (not a connection, not a colleague).
    return Decision.denied("not_discoverable")


# --------------------------------------------------------------------------- #
# Connection invitations
# --------------------------------------------------------------------------- #
def can_send_invitation(ctx: RelationshipContext) -> Decision:
    if ctx.is_blocked_either_way:
        return Decision.denied("blocked")
    if ctx.viewer_id == ctx.target_id:
        return Decision.denied("self")
    if ctx.is_first_degree:
        return Decision.denied("already_connected")
    if ctx.has_pending_invitation:
        return Decision.denied("invitation_exists")
    # Colleagues may always connect — internal, no kill-switch gate.
    if _is_colleague(ctx):
        return Decision.open("colleague")
    # External path from here on.
    if not ctx.external_networking_enabled_for_both:
        return Decision.denied("networking_disabled")
    policy = ctx.target_privacy.invite_policy
    if policy == InvitePolicy.NOBODY:
        return Decision.denied("invite_policy_nobody")
    if policy == InvitePolicy.SHARED_GROUP_OR_ORG:
        # No shared org (checked above) and shared groups are M5 — deny for now.
        return Decision.denied("invite_policy_shared_only")
    if policy == InvitePolicy.SECOND_DEGREE:
        # Second-degree resolution requires the graph, which is not in this pure
        # context (M1 default is EVERYONE). Conservative: deny pure strangers.
        return Decision.denied("invite_policy_second_degree")
    # EVERYONE
    return Decision.open("everyone")


# --------------------------------------------------------------------------- #
# Direct messaging  (open | request | denied)
# --------------------------------------------------------------------------- #
def _direct_decision(ctx: RelationshipContext) -> Decision:
    """Colleagues (shared org) and first-degree connections may chat. Two
    doctors whose ONLY relationship is a shared group follow that group's
    member_dm_policy: 'open' lets them chat; 'request' asks them to connect
    first (the message-request tier is gone, so a connection is the request);
    'disabled' keeps the group's members apart outside the group."""
    if ctx.is_blocked_either_way:
        return Decision.denied("blocked")
    if ctx.viewer_id == ctx.target_id:
        return Decision.denied("self")
    if _is_colleague(ctx):
        return Decision.open("colleague")
    if ctx.is_first_degree:
        return Decision.open("connection")
    if ctx.shared_group_dm_mode == "open":
        return Decision.open("shared_group")
    if ctx.shared_group_dm_mode == "request":
        return Decision.denied("group_dm_request")
    if ctx.shared_group_dm_mode == "denied":
        return Decision.denied("group_dm_disabled")
    return Decision.denied("not_connected")


def can_start_direct(ctx: RelationshipContext) -> Decision:
    """Can the viewer create/open a direct conversation with the target?"""
    return _direct_decision(ctx)


def can_message(ctx: RelationshipContext) -> Decision:
    """Can the viewer send into a direct conversation with the target? Same
    rule as starting one — the relationship is re-checked on every send so a
    removed connection or a block freezes the thread."""
    return _direct_decision(ctx)


# --------------------------------------------------------------------------- #
# Group membership (M5 refines; M1 provides a sensible boundary)
# --------------------------------------------------------------------------- #
def can_add_to_group(ctx: RelationshipContext) -> Decision:
    if ctx.is_blocked_either_way:
        return Decision.denied("blocked")
    if ctx.viewer_id == ctx.target_id:
        return Decision.denied("self")
    if _is_colleague(ctx) or ctx.is_first_degree:
        return Decision.open("colleague_or_connection")
    if not ctx.external_networking_enabled_for_both:
        return Decision.denied("networking_disabled")
    return Decision.denied("not_connected")


# --------------------------------------------------------------------------- #
# Presence + profile-field visibility (batch 2)
# --------------------------------------------------------------------------- #
# "connections" means the people a doctor already works with: first-degree
# connections AND same-org colleagues (the same regression rule that lets
# colleagues always see each other's profile — org member lists have shown
# presence since M0 and must keep doing so). Strangers only get
# everyone-scoped fields.
def _is_close(ctx: RelationshipContext) -> bool:
    return _is_colleague(ctx) or ctx.is_first_degree


def can_see_last_seen(ctx: RelationshipContext) -> bool:
    """May the viewer see the target's last_seen_at? Reciprocal: a viewer who
    hides their own last seen sees nobody's. Blocked pairs see nothing."""
    if ctx.is_blocked_either_way or ctx.viewer_id == ctx.target_id:
        return False
    if ctx.viewer_privacy.last_seen_visibility == LastSeenVisibility.NOBODY:
        return False
    vis = ctx.target_privacy.last_seen_visibility
    if vis == LastSeenVisibility.EVERYONE:
        return True
    if vis == LastSeenVisibility.CONNECTIONS:
        return _is_close(ctx)
    return False


def can_see_online(ctx: RelationshipContext) -> bool:
    """May the viewer see the target as online/away right now? Follows the
    last-seen audience unless the target hid online status outright."""
    if ctx.target_privacy.online_visibility == OnlineVisibility.NOBODY:
        return False
    return can_see_last_seen(ctx)


def _field_visible(ctx: RelationshipContext, vis: ProfileFieldVisibility) -> bool:
    if ctx.is_blocked_either_way:
        return False
    if vis == ProfileFieldVisibility.EVERYONE:
        return True
    return _is_close(ctx)


def can_see_profile_photo(ctx: RelationshipContext) -> bool:
    return _field_visible(ctx, ctx.target_privacy.profile_photo_visibility)


def can_see_about(ctx: RelationshipContext) -> bool:
    return _field_visible(ctx, ctx.target_privacy.about_visibility)
