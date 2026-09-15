from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import delete, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.enums import AuditAction
from app.models import (
    Block,
    Connection,
    ConnectionInvitation,
    ConnectionRemoval,
    ConversationMember,
    DeviceToken,
    GroupInvite,
    GroupMember,
    Message,
    MessageReceipt,
    Mute,
    Notification,
    OrgMember,
    Report,
    ScheduledMessage,
    User,
    UserPrivacySettings,
)
from app.services.audit_service import AuditService


class AccountDeletionService:
    """App Store 5.1.1(v) account deletion.

    A hard DELETE is not possible — most FKs to users.id are RESTRICT, and
    HIPAA §164.316(b)(2) requires audit records be kept for six years. So the
    row survives as a tombstone with every identifying field scrubbed, all
    PHI-bearing content is destroyed, and deleted_at makes the account
    unusable (see _user_from_token). Apple permits retaining data a
    regulated app is legally required to keep.
    """

    @staticmethod
    async def delete_account(
        *,
        user: User,
        db: AsyncSession,
        ip_address: str | None = None,
        user_agent: str | None = None,
    ) -> None:
        uid = user.id

        # Audit first: after the scrub there is no name left to record, and the
        # row must survive the deletion it describes.
        await AuditService.log(
            db,
            user_id=uid,
            action=AuditAction.ACCOUNT_DELETED,
            ip_address=ip_address,
            user_agent=user_agent,
            # phone is NULL for social-only accounts — minimum necessary either way.
            metadata={
                "phone": "****" + user.phone[-4:] if user.phone else "****none",
                "npi": user.npi_number,
            },
        )

        # 1. PHI in authored content. Messages are kept as tombstones so the
        # other party's thread does not develop holes, but every byte of
        # content, transcript and attachment reference is dropped.
        await db.execute(
            update(Message)
            .where(Message.sender_id == uid)
            .values(
                content_encrypted=None,
                transcript_encrypted=None,
                s3_key=None,
                file_name=None,
                file_size_bytes=None,
                is_deleted=True,
            )
        )
        await db.execute(delete(ScheduledMessage).where(ScheduledMessage.sender_id == uid))
        await db.execute(delete(MessageReceipt).where(MessageReceipt.user_id == uid))

        # 2. Membership and delivery surfaces.
        for stmt in (
            delete(ConversationMember).where(ConversationMember.user_id == uid),
            delete(DeviceToken).where(DeviceToken.user_id == uid),
            delete(OrgMember).where(OrgMember.user_id == uid),
            delete(GroupMember).where(GroupMember.user_id == uid),
            delete(UserPrivacySettings).where(UserPrivacySettings.user_id == uid),
        ):
            await db.execute(stmt)

        # 3. Social graph, both directions.
        for stmt in (
            delete(Notification).where(Notification.user_id == uid),
            delete(Notification).where(Notification.actor_id == uid),
            delete(ConnectionInvitation).where(ConnectionInvitation.sender_id == uid),
            delete(ConnectionInvitation).where(ConnectionInvitation.recipient_id == uid),
            delete(Connection).where(Connection.user_id == uid),
            delete(Connection).where(Connection.connected_user_id == uid),
            delete(ConnectionRemoval).where(ConnectionRemoval.user_a == uid),
            delete(ConnectionRemoval).where(ConnectionRemoval.user_b == uid),
            delete(Block).where(Block.blocker_id == uid),
            delete(Block).where(Block.blocked_id == uid),
            delete(Mute).where(Mute.user_id == uid),
            delete(Mute).where(Mute.muted_user_id == uid),
            delete(GroupInvite).where(GroupInvite.inviter_id == uid),
            delete(GroupInvite).where(GroupInvite.invitee_id == uid),
            delete(Report).where(Report.reporter_id == uid),
        ):
            await db.execute(stmt)

        # 4. Scrub identity. phone is String(20) and npi_number CHAR(10), both
        # unique — the tombstone values must fit and must not collide.
        stub = uid.hex
        user.phone = f"d{stub[:19]}"
        user.npi_number = stub[:10]
        user.email = None
        # Must be cleared, or the provider account still resolves to this
        # tombstone and signing in again would adopt a deleted user.
        user.firebase_uid = None
        user.full_name = "Deleted user"
        user.handle = None
        user.headline = None
        user.specialty = None
        user.bio = None
        user.city = None
        user.state = None
        user.years_of_experience = None
        user.skills = []
        user.avatar_url = None
        user.avatar_color = None
        user.password_hash = None
        user.last_seen_at = None
        user.deleted_at = datetime.now(tz=timezone.utc)
