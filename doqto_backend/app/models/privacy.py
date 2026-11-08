"""Per-user privacy settings (M1 + batch 2). Row absent = defaults (see
PrivacySnapshot defaults in app/core/permissions.py)."""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Integer, String, func, true
from sqlalchemy.dialects.postgresql import UUID as PgUUID
from sqlalchemy.orm import Mapped, mapped_column

from app.core.enums import (
    Discoverability,
    DmPolicy,
    InvitePolicy,
    LastSeenVisibility,
    OnlineVisibility,
    ProfileFieldVisibility,
)
from app.db.postgres import Base
from app.db.tables import Tables


class UserPrivacySettings(Base):
    __tablename__ = Tables.USER_PRIVACY_SETTINGS
    __table_args__ = (
        CheckConstraint(
            "invite_policy IN ('everyone', 'second_degree', 'shared_group_or_org', 'nobody')",
            name="ck_user_privacy_invite_policy",
        ),
        CheckConstraint(
            "dm_policy IN ('everyone', 'connections_and_requests', "
            "'connections_only', 'nobody')",
            name="ck_user_privacy_dm_policy",
        ),
        CheckConstraint(
            "discoverability IN ('everyone', 'connections', 'nobody')",
            name="ck_user_privacy_discoverability",
        ),
        CheckConstraint(
            "last_seen_visibility IN ('everyone', 'connections', 'nobody')",
            name="ck_user_privacy_last_seen_visibility",
        ),
        CheckConstraint(
            "online_visibility IN ('same_as_last_seen', 'nobody')",
            name="ck_user_privacy_online_visibility",
        ),
        CheckConstraint(
            "profile_photo_visibility IN ('everyone', 'connections')",
            name="ck_user_privacy_profile_photo_visibility",
        ),
        CheckConstraint(
            "about_visibility IN ('everyone', 'connections')",
            name="ck_user_privacy_about_visibility",
        ),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        PgUUID(as_uuid=True),
        ForeignKey(f"{Tables.USERS}.id", ondelete="CASCADE"),
        primary_key=True,
    )
    invite_policy: Mapped[InvitePolicy] = mapped_column(
        String(24),
        default=InvitePolicy.EVERYONE,
        server_default=InvitePolicy.EVERYONE.value,
        nullable=False,
    )
    dm_policy: Mapped[DmPolicy] = mapped_column(
        String(30),
        default=DmPolicy.CONNECTIONS_AND_REQUESTS,
        server_default=DmPolicy.CONNECTIONS_AND_REQUESTS.value,
        nullable=False,
    )
    discoverability: Mapped[Discoverability] = mapped_column(
        String(20),
        default=Discoverability.EVERYONE,
        server_default=Discoverability.EVERYONE.value,
        nullable=False,
    )
    show_mutual_connections: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default=true(), nullable=False
    )
    # --- batch 2: presence + profile field visibility + chat defaults ------ #
    last_seen_visibility: Mapped[LastSeenVisibility] = mapped_column(
        String(20),
        default=LastSeenVisibility.CONNECTIONS,
        server_default=LastSeenVisibility.CONNECTIONS.value,
        nullable=False,
    )
    online_visibility: Mapped[OnlineVisibility] = mapped_column(
        String(24),
        default=OnlineVisibility.SAME_AS_LAST_SEEN,
        server_default=OnlineVisibility.SAME_AS_LAST_SEEN.value,
        nullable=False,
    )
    profile_photo_visibility: Mapped[ProfileFieldVisibility] = mapped_column(
        String(20),
        default=ProfileFieldVisibility.EVERYONE,
        server_default=ProfileFieldVisibility.EVERYONE.value,
        nullable=False,
    )
    about_visibility: Mapped[ProfileFieldVisibility] = mapped_column(
        String(20),
        default=ProfileFieldVisibility.EVERYONE,
        server_default=ProfileFieldVisibility.EVERYONE.value,
        nullable=False,
    )
    # Direct chats only; groups always show read-by. Receipts are still
    # STORED when off (audit) — they are just not emitted / exposed.
    read_receipts: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default=true(), nullable=False
    )
    # Applied to new direct conversations this user creates (one of
    # DISAPPEAR_OPTIONS_SEC); NULL = off.
    default_disappear_sec: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Stored now, consumed by link previews (batch 4).
    link_previews: Mapped[bool] = mapped_column(
        Boolean, default=True, server_default=true(), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )
