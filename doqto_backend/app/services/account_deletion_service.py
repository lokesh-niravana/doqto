from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone

from fastapi.concurrency import run_in_threadpool
from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.enums import AuditAction
from app.models import (
    AppInvite,
    Block,
    Connection,
    ConnectionInvitation,
    ConnectionRemoval,
    ConversationMember,
    ConversationPref,
    DeviceToken,
    GroupInvite,
    GroupMember,
    Message,
    MessageEdit,
    MessageReaction,
    MessageReceipt,
    MessageStar,
    Mute,
    Notification,
    OrgMember,
    PollOption,
    PollVote,
    Report,
    ScheduledMessage,
    Session,
    SuggestionDismissal,
    UploadIntent,
    User,
    UserNotificationSettings,
    UserPrivacySettings,
)
from app.services.audit_service import AuditService
from app.services.compliance_service import not_under_legal_hold
from app.services.file_service import FileService
from app.services.stripe_client import StripeGateway

logger = logging.getLogger(__name__)

# Subscriptions Stripe will never charge again.
TERMINAL_STATUSES = frozenset({"canceled", "incomplete_expired"})


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
        stripe: StripeGateway | None = None,
        multipart_aborts: list[tuple[str, str]] | None = None,
    ) -> list[str]:
        """Returns the S3 keys of everything the account owned (attachments,
        thumbnails, the avatar). The caller deletes those objects once the
        transaction has committed — see [delete_objects]."""
        uid = user.id

        # Stop the billing before the account goes, or a deleted doctor keeps
        # being charged. Best effort: deletion is a legal right and must not
        # depend on Stripe being configured or reachable.
        # Ask Stripe rather than trust the mirror: a webhook may not have
        # landed yet, and a customer can hold more than one subscription.
        if stripe is not None and user.stripe_customer_id:
            try:
                subs = await run_in_threadpool(stripe.list_subscriptions, user.stripe_customer_id)
                for sub in subs:
                    if sub.status not in TERMINAL_STATUSES:
                        await run_in_threadpool(stripe.cancel_subscription, sub.id)
            except Exception:
                logger.exception("account deletion user=%s: stripe cancel failed", uid)

        # Audit first: after the scrub there is no name left to record, and the
        # row must survive the deletion it describes.
        await AuditService.log(
            db,
            user_id=uid,
            action=AuditAction.ACCOUNT_DELETED,
            ip_address=ip_address,
            user_agent=user_agent,
            # Nothing that identifies the person: the public deletion page
            # promises the retained audit record carries no identifying
            # information, and an NPI names a doctor in the public registry.
            metadata={"had_phone": bool(user.phone)},
        )

        # 1. PHI in authored content. Messages are kept as tombstones so the
        # other party's thread does not develop holes, but every byte of
        # content, transcript and attachment reference is dropped.
        # Legal hold (batch 7): messages in a held org's conversations are
        # tombstoned (hidden) but their content survives until the hold lifts.
        # The stored objects have to be collected before the keys are nulled:
        # the purge job finds objects through these columns, so nulling them
        # without deleting would orphan the files in S3 for good.
        authored = select(Message.id).where(Message.sender_id == uid, not_under_legal_hold())
        object_keys: list[str] = []
        for s3_key, thumb_key in (
            await db.execute(
                select(Message.s3_key, Message.thumb_key).where(
                    Message.sender_id == uid, not_under_legal_hold()
                )
            )
        ).all():
            if s3_key:
                object_keys.append(s3_key)
            if thumb_key:
                object_keys.append(thumb_key)
        if user.avatar_url:
            object_keys.append(user.avatar_url)
        # Earlier versions of edited messages are message content too.
        await db.execute(delete(MessageEdit).where(MessageEdit.message_id.in_(authored)))
        await db.execute(
            update(Message)
            .where(Message.sender_id == uid, not_under_legal_hold())
            .values(
                content_encrypted=None,
                transcript_encrypted=None,
                caption_encrypted=None,
                waveform=None,
                s3_key=None,
                thumb_key=None,
                file_name=None,
                file_size_bytes=None,
                is_deleted=True,
            )
        )
        await db.execute(
            update(Message).where(Message.sender_id == uid).values(is_deleted=True)
        )
        # Poll option text is PHI too (votes cascade); the user's own votes on
        # other people's polls go with their membership.
        await db.execute(
            delete(PollOption).where(
                PollOption.message_id.in_(
                    select(Message.id).where(Message.sender_id == uid, not_under_legal_hold())
                )
            )
        )
        await db.execute(delete(PollVote).where(PollVote.user_id == uid))
        # Uploads that were started but never attached to a message: their
        # files are only findable through these rows, so collect them first.
        # A multipart upload that never completed is not an object yet — its
        # parts can only be discarded by aborting the upload, which needs the
        # upload id, so those go to [multipart_aborts] for after the commit.
        for s3_key, thumb_key, upload_id in (
            await db.execute(
                select(UploadIntent.s3_key, UploadIntent.thumb_key, UploadIntent.upload_id).where(
                    UploadIntent.user_id == uid, UploadIntent.completed_at.is_(None)
                )
            )
        ).all():
            object_keys.append(s3_key)
            if upload_id and multipart_aborts is not None:
                multipart_aborts.append((s3_key, upload_id))
            if thumb_key:
                object_keys.append(thumb_key)
        await db.execute(delete(UploadIntent).where(UploadIntent.user_id == uid))
        await db.execute(delete(ScheduledMessage).where(ScheduledMessage.sender_id == uid))
        await db.execute(delete(MessageReceipt).where(MessageReceipt.user_id == uid))

        # 2. Membership and delivery surfaces.
        for stmt in (
            delete(ConversationMember).where(ConversationMember.user_id == uid),
            delete(DeviceToken).where(DeviceToken.user_id == uid),
            delete(OrgMember).where(OrgMember.user_id == uid),
            delete(GroupMember).where(GroupMember.user_id == uid),
            delete(UserPrivacySettings).where(UserPrivacySettings.user_id == uid),
            delete(UserNotificationSettings).where(UserNotificationSettings.user_id == uid),
            delete(ConversationPref).where(ConversationPref.user_id == uid),
            delete(MessageStar).where(MessageStar.user_id == uid),
            delete(MessageReaction).where(MessageReaction.user_id == uid),
            # Device name and IP address of every sign-in.
            delete(Session).where(Session.user_id == uid),
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
            delete(SuggestionDismissal).where(SuggestionDismissal.user_id == uid),
            delete(SuggestionDismissal).where(SuggestionDismissal.dismissed_user_id == uid),
            delete(AppInvite).where(AppInvite.inviter_id == uid),
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
        # Apple can't be told to cancel; the doctor does that in iPhone
        # Settings. Release the subscription so a new account can claim it.
        user.apple_original_transaction_id = None
        user.apple_expires_at = None
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
        user.status_text = None
        user.status_expires_at = None
        user.pin_hash = None
        # Subscriptions were cancelled above; drop the link to the customer.
        user.stripe_customer_id = None
        user.stripe_subscription_id = None
        user.deleted_at = datetime.now(tz=timezone.utc)
        return object_keys

    @staticmethod
    async def delete_objects(
        keys: list[str],
        user_id: uuid.UUID | None = None,
        multipart_aborts: list[tuple[str, str]] | None = None,
    ) -> None:
        """Remove the account's stored files. Best effort and after commit:
        the database no longer references them, so a failure here leaves an
        unreachable object, never a dangling reference.

        With [user_id], also removes everything filed under the user's id:
        account exports (name, phone, email, NPI; see ExportService.key_for)
        and every profile photo ever uploaded, not only the current one.
        [multipart_aborts] are (key, upload_id) pairs of uploads that never
        completed; aborting discards their parts."""
        for key, upload_id in multipart_aborts or []:
            try:
                await FileService.abort_multipart_upload(key=key, upload_id=upload_id)
            except Exception:
                logger.exception("account deletion: could not abort upload %s", upload_id)
        for key in keys:
            try:
                await FileService.delete_object(key=key)
            except Exception:
                logger.exception("account deletion: could not delete object %s", key)
        if user_id is not None:
            for prefix in (f"exports/{user_id}/", f"avatars/{user_id}/"):
                try:
                    await FileService.delete_prefix(prefix=prefix)
                except Exception:
                    logger.exception("account deletion: could not delete %s", prefix)
