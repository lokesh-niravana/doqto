"""Push notification pipeline — sender-side, PHI-free, always pushed (no presence gate).

Dev default (PUSH_PROVIDER=log) is a logging stub;
real FCM slots in later via PUSH_PROVIDER=fcm + credentials in config.

Payload policy: title/body are the fixed constants PUSH_TITLE /
PUSH_BODY_NEW_MESSAGE (or "<sender name> sent you a message" — directory data,
not PHI). Never message content (HIPAA: pushes transit
Apple/Google unencrypted-to-us). Data carries only the conversation UUID for
deep-linking; collapse key dedupes per conversation. Mentions (batch 4) send
"<sender> mentioned you in <group>" to the people named INSTEAD of the generic
banner — still names only.

Batch 6: each recipient's notification settings pick `aps.sound`
("default" / "<tone>.caf" / silent), the Android channel (messages / groups /
invitations) and priority; a per-chat `conversation_prefs.custom_tone` wins;
reaction pushes are dropped when the recipient turned them off; mention pushes
bypass the chat mute but honour the tone. "New sign-in on <device>" goes to the
user's own devices — a device model is not PHI.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from enum import Enum
from typing import Protocol

import httpx
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql import func

from app.core.config import settings
from app.core.constants import (
    PUSH_BODY_MENTION_FALLBACK,
    PUSH_BODY_NEW_MESSAGE,
    PUSH_BODY_NEW_SIGN_IN_FALLBACK,
    PUSH_CHANNEL_INVITATIONS,
    PUSH_CHANNEL_MESSAGES,
    PUSH_TITLE,
)
from app.db.postgres import SessionLocal
from app.models import Conversation, ConversationPref, DeviceToken, User
from app.services.conversation_prefs_service import ConversationPrefsService
from app.services.message_service import MessageService
from app.services.notification_settings_service import NotificationSettingsService, PushPrefs

log = logging.getLogger("doqto.push")

# How long Apple/Google hold a push for a phone that is off or offline. The
# device gets it when it reconnects, app running or not. APNs keeps the newest
# per collapse id, so a conversation arrives as one up-to-date banner.
PUSH_TTL_SECONDS = 28 * 24 * 3600


def fcm_message(
    *, token: str, title: str, body: str, data: dict[str, str], collapse_key: str,
    now: float | None = None, badge: int | None = None,
    sound: str | None = "default", channel_id: str | None = None,
    high_priority: bool = True,
) -> dict:
    """FCM HTTP v1 message. Pure, so the delivery contract is testable.
    `badge` is the recipient's total unread (not content) → `aps.badge`.
    `sound` is "default", "<tone>.caf" or None (silent); `channel_id` is the
    Android notification channel; `high_priority=False` lets Android defer."""
    now = time.time() if now is None else now
    aps: dict = {}
    if sound is not None:
        aps["sound"] = sound
    if badge is not None:
        aps["badge"] = badge
    android: dict = {
        "collapse_key": collapse_key,
        "priority": "high" if high_priority else "normal",
        "ttl": f"{PUSH_TTL_SECONDS}s",
    }
    android_notification: dict = {}
    if channel_id:
        android_notification["channel_id"] = channel_id
    if sound is not None:
        # Android plays the raw resource of the same name ("default" = system).
        android_notification["sound"] = sound.removesuffix(".caf")
    if android_notification:
        android["notification"] = android_notification
    return {
        "token": token,
        "notification": {"title": title, "body": body},
        "data": data,
        "android": android,
        "apns": {
            "headers": {
                "apns-collapse-id": collapse_key,
                "apns-priority": "10",
                "apns-push-type": "alert",
                "apns-expiration": str(int(now) + PUSH_TTL_SECONDS),
            },
            "payload": {"aps": aps},
        },
    }


def reaction_body(actor_name: str | None, emoji: str) -> str:
    return f"{actor_name or 'Someone'} reacted {emoji} to your message"


def group_invite_body(actor_name: str | None, group_name: str) -> str:
    """Names only — a doctor's name and a group name are directory data."""
    return f"{actor_name or 'Someone'} invited you to {group_name}"


def mention_body(actor_name: str | None, group_name: str | None) -> str:
    """'Dr X mentioned you in <group>' — names only (directory data). Never
    the message text."""
    if not actor_name:
        return PUSH_BODY_MENTION_FALLBACK
    if group_name:
        return f"{actor_name} mentioned you in {group_name}"
    return f"{actor_name} mentioned you"


def new_sign_in_body(device_name: str | None) -> str:
    """'New sign-in on iPhone 16 Pro' — a device model is not PHI (batch 6)."""
    if not device_name:
        return PUSH_BODY_NEW_SIGN_IN_FALLBACK
    return f"New sign-in on {device_name}"


def new_message_body(sender_name: str | None, unread: int) -> str:
    """Sender name is directory data, not PHI; the count is not content."""
    if not sender_name:
        return PUSH_BODY_NEW_MESSAGE
    if unread > 1:
        return f"{sender_name} sent you {unread} new messages"
    return f"{sender_name} sent you a message"


class PushResult(str, Enum):
    SENT = "sent"
    # Transient or configuration failure (e.g. FCM 401 "Invalid APNs
    # credential"): keep the token, but never log it as sent. That mislabel
    # hid a broken APNs key for every iPhone (2026-11-03).
    FAILED = "failed"
    # Token permanently invalid (unregistered/expired): prune the row.
    DEAD = "dead-token"


class PushSender(Protocol):
    async def send(
        self,
        *,
        token: str,
        title: str,
        body: str,
        data: dict[str, str],
        collapse_key: str,
        badge: int | None = None,
        sound: str | None = "default",
        channel_id: str | None = None,
        high_priority: bool = True,
    ) -> PushResult:
        """Deliver one push and say what happened."""
        ...


class DevLogPushSender:
    """Local dev stub — logs instead of sending."""

    async def send(
        self,
        *,
        token: str,
        title: str,
        body: str,
        data: dict[str, str],
        collapse_key: str,
        badge: int | None = None,
        sound: str | None = "default",
        channel_id: str | None = None,
        high_priority: bool = True,
    ) -> PushResult:
        log.info(
            "[FAKE PUSH] %s → %s / %s %s badge=%s sound=%s channel=%s",
            token[:12], title, body, data, badge, sound, channel_id,
        )
        return PushResult.SENT


class FcmPushSender:
    """FCM HTTP v1. FCM_SERVICE_ACCOUNT_JSON is any google-auth credential
    JSON (service-account key or workload-identity external_account)."""

    _SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

    def __init__(self) -> None:
        if not settings.FCM_PROJECT_ID or not settings.FCM_SERVICE_ACCOUNT_JSON:
            raise RuntimeError(
                "PUSH_PROVIDER=fcm requires FCM_PROJECT_ID and FCM_SERVICE_ACCOUNT_JSON"
            )
        from google.auth import load_credentials_from_dict

        self._creds, _ = load_credentials_from_dict(
            json.loads(settings.FCM_SERVICE_ACCOUNT_JSON), scopes=[self._SCOPE]
        )
        self._url = f"https://fcm.googleapis.com/v1/projects/{settings.FCM_PROJECT_ID}/messages:send"

    def _bearer(self) -> str:
        from google.auth.transport.requests import Request

        if not self._creds.valid:
            self._creds.refresh(Request())  # ponytail: sync refresh, ~1/hour
        return self._creds.token

    async def send(
        self,
        *,
        token: str,
        title: str,
        body: str,
        data: dict[str, str],
        collapse_key: str,
        badge: int | None = None,
        sound: str | None = "default",
        channel_id: str | None = None,
        high_priority: bool = True,
    ) -> PushResult:
        message = fcm_message(
            token=token, title=title, body=body, data=data, collapse_key=collapse_key, badge=badge,
            sound=sound, channel_id=channel_id, high_priority=high_priority,
        )
        bearer = await asyncio.to_thread(self._bearer)
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                self._url, json={"message": message}, headers={"Authorization": f"Bearer {bearer}"}
            )
        if resp.status_code == 200:
            return PushResult.SENT
        # UNREGISTERED / NOT_FOUND: token is dead, prune it. Anything else: keep.
        dead = resp.status_code == 404 or "UNREGISTERED" in resp.text
        # One line, with the reason: the old multi-line dump cut off before it.
        try:
            err = resp.json().get("error", {})
            reason = f'{err.get("status")}: {err.get("message")}'
        except ValueError:
            reason = resp.text[:200].replace("\n", " ")
        log.warning("fcm send failed %s %s", resp.status_code, reason)
        return PushResult.DEAD if dead else PushResult.FAILED


def _default_sender() -> PushSender:
    # Provider keyed on settings.
    if settings.PUSH_PROVIDER == "fcm":
        return FcmPushSender()
    return DevLogPushSender()


# Test seam: tests override this module-level factory to inject a fake sender.
sender_factory = _default_sender


def _sender() -> PushSender:
    return sender_factory()


class PushService:
    @staticmethod
    async def register_token(
        *, user_id: uuid.UUID, token: str, platform: str, db: AsyncSession
    ) -> None:
        """Upsert by token: re-registering reassigns the device to the caller
        (last login wins on a shared device) and bumps last_seen_at."""
        stmt = (
            pg_insert(DeviceToken)
            .values(user_id=user_id, token=token, platform=platform)
            .on_conflict_do_update(
                index_elements=[DeviceToken.token],
                set_={"user_id": user_id, "platform": platform, "last_seen_at": func.now()},
            )
        )
        await db.execute(stmt)
        await db.flush()

    @staticmethod
    async def unregister_token(*, user_id: uuid.UUID, token: str, db: AsyncSession) -> None:
        await db.execute(
            delete(DeviceToken).where(
                DeviceToken.token == token, DeviceToken.user_id == user_id
            )
        )
        await db.flush()

    @staticmethod
    def notify_new_message(
        *,
        conversation_id: uuid.UUID,
        recipient_ids: list[uuid.UUID],
        sender_id: uuid.UUID,
        skip_ids: set[uuid.UUID] | None = None,
    ) -> None:
        """Fire-and-forget: never blocks or fails the send path. `skip_ids`
        are members who get a different push for this message (mentions)."""
        asyncio.create_task(
            PushService._dispatch(
                conversation_id=conversation_id,
                recipient_ids=recipient_ids,
                sender_id=sender_id,
                skip_ids=skip_ids,
            )
        )

    @staticmethod
    def notify_mentions(
        *,
        conversation_id: uuid.UUID,
        mentioned_ids: list[uuid.UUID],
        sender_id: uuid.UUID,
    ) -> None:
        """'Dr X mentioned you in <group>' to each mentioned member (never the
        sender). Same collapse key as the conversation's new-message banner so
        it REPLACES it rather than stacking. Mentions bypass any per-chat mute
        the client applies — this push is the mute-proof path. Fire-and-forget."""
        asyncio.create_task(
            PushService._dispatch_mentions(
                conversation_id=conversation_id,
                mentioned_ids=mentioned_ids,
                sender_id=sender_id,
            )
        )

    @staticmethod
    async def _dispatch_mentions(
        *,
        conversation_id: uuid.UUID,
        mentioned_ids: list[uuid.UUID],
        sender_id: uuid.UUID,
    ) -> None:
        try:
            async with SessionLocal() as db:
                name = await db.scalar(select(User.full_name).where(User.id == sender_id))
                conv = await db.get(Conversation, conversation_id)
                group_name = conv.name if conv is not None else None
        except Exception:  # noqa: BLE001
            log.exception("mention push lookup failed")
            name, group_name = None, None
        body = mention_body(name, group_name)
        for uid in mentioned_ids:
            if uid == sender_id:
                continue
            # Mute is bypassed on purpose; the tone / channel still apply.
            prefs = await PushService._prefs_for(
                recipient_id=uid, conversation_id=conversation_id, conv=conv
            )
            await PushService._dispatch_simple(
                recipient_id=uid,
                title=PUSH_TITLE,
                body=body,
                data={"type": "mention", "conversation_id": str(conversation_id)},
                collapse_key=str(conversation_id),
                prefs=prefs,
            )

    @staticmethod
    def notify_reaction(
        *,
        conversation_id: uuid.UUID,
        author_id: uuid.UUID,
        actor_id: uuid.UUID,
        emoji: str,
    ) -> None:
        """'<name> reacted 👍 to your message' — a name is directory data and
        an emoji is not message content, so this stays PHI-free. Own collapse
        key so it never replaces a pending new-message banner. Fire-and-forget."""
        asyncio.create_task(
            PushService._dispatch_reaction(
                conversation_id=conversation_id,
                author_id=author_id,
                actor_id=actor_id,
                emoji=emoji,
            )
        )

    @staticmethod
    async def _dispatch_reaction(
        *,
        conversation_id: uuid.UUID,
        author_id: uuid.UUID,
        actor_id: uuid.UUID,
        emoji: str,
    ) -> None:
        try:
            async with SessionLocal() as db:
                if await PushService._silenced(
                    recipient_id=author_id, actor_id=actor_id, conversation_id=conversation_id, db=db
                ):
                    log.info("push muted user=%s conv=%s (reaction)", author_id, conversation_id)
                    return
                conv = await db.get(Conversation, conversation_id)
                prefs = await PushService._prefs_for(
                    recipient_id=author_id, conversation_id=conversation_id, conv=conv, db=db
                )
                if not prefs.reaction_notifications:
                    log.info("push off user=%s (reaction notifications)", author_id)
                    return
                name = await db.scalar(select(User.full_name).where(User.id == actor_id))
        except Exception:  # noqa: BLE001
            log.exception("reaction push name lookup failed")
            name, prefs = None, None
        await PushService._dispatch_simple(
            recipient_id=author_id,
            title=PUSH_TITLE,
            body=reaction_body(name, emoji),
            data={"type": "reaction", "conversation_id": str(conversation_id)},
            collapse_key=f"reaction:{conversation_id}",
            prefs=prefs,
        )

    @staticmethod
    def notify_group_invite(
        *,
        recipient_id: uuid.UUID,
        actor_name: str,
        group_name: str,
        group_id: uuid.UUID,
    ) -> None:
        """'Dr X invited you to <group>' — PHI-free; data carries only the group
        id so a tap lands on Group info. One banner per group (collapse key):
        a re-sent invite replaces, never stacks. Fire-and-forget."""
        asyncio.create_task(
            PushService._dispatch_simple(
                recipient_id=recipient_id,
                title=PUSH_TITLE,
                body=group_invite_body(actor_name, group_name),
                data={"type": "group_invite", "group_id": str(group_id)},
                collapse_key=f"group_invite:{group_id}",
                channel_id=PUSH_CHANNEL_INVITATIONS,
            )
        )

    @staticmethod
    def notify_invitation_received(
        *, recipient_id: uuid.UUID, actor_name: str, invitation_id: uuid.UUID
    ) -> None:
        """Directory data (a doctor's name) is NOT PHI — safe in a push body."""
        asyncio.create_task(
            PushService._dispatch_simple(
                recipient_id=recipient_id,
                title=PUSH_TITLE,
                body=f"{actor_name} wants to connect",
                data={"type": "invitation_received", "invitation_id": str(invitation_id)},
                collapse_key=f"invite:{invitation_id}",
                channel_id=PUSH_CHANNEL_INVITATIONS,
            )
        )

    @staticmethod
    def notify_invitation_accepted(
        *, recipient_id: uuid.UUID, actor_name: str
    ) -> None:
        asyncio.create_task(
            PushService._dispatch_simple(
                recipient_id=recipient_id,
                title=PUSH_TITLE,
                body=f"{actor_name} accepted your connection request",
                data={"type": "invitation_accepted"},
                collapse_key=f"accept:{recipient_id}",
                channel_id=PUSH_CHANNEL_INVITATIONS,
            )
        )

    @staticmethod
    def notify_invite_joined(
        *, recipient_id: uuid.UUID, actor_name: str, user_id: uuid.UUID | None
    ) -> None:
        asyncio.create_task(
            PushService._dispatch_simple(
                recipient_id=recipient_id,
                title=PUSH_TITLE,
                body=f"{actor_name} joined from your invite. You're connected.",
                data={"type": "invite_joined", "user_id": str(user_id or "")},
                collapse_key=f"joined:{user_id}",
                channel_id=PUSH_CHANNEL_INVITATIONS,
            )
        )

    @staticmethod
    def notify_new_sign_in(
        *, recipient_id: uuid.UUID, device_name: str | None, session_id: uuid.UUID
    ) -> None:
        """'New sign-in on iPhone 16 Pro' to the user's own devices (batch 6).
        A device model is not PHI. The new device itself usually has no push
        token yet, and ignores the event by session_id if it does."""
        asyncio.create_task(
            PushService._dispatch_simple(
                recipient_id=recipient_id,
                title=PUSH_TITLE,
                body=new_sign_in_body(device_name),
                data={"type": "new_sign_in", "session_id": str(session_id)},
                collapse_key=f"signin:{session_id}",
                channel_id=PUSH_CHANNEL_INVITATIONS,
            )
        )

    @staticmethod
    async def _prefs_for(
        *,
        recipient_id: uuid.UUID,
        conversation_id: uuid.UUID,
        conv: Conversation | None,
        db: AsyncSession | None = None,
        pref: ConversationPref | None = None,
    ) -> PushPrefs:
        """Sound / channel / priority for one recipient of one chat: the
        per-chat custom tone wins over the global messages / groups tone."""

        async def _load(session: AsyncSession) -> PushPrefs:
            row = pref
            if row is None:
                row = await ConversationPrefsService.get(
                    conversation_id=conversation_id, user_id=recipient_id, db=session
                )
            return await NotificationSettingsService.push_prefs(
                user_id=recipient_id,
                conv_type=conv.type if conv is not None else None,
                custom_tone=row.custom_tone if row is not None else None,
                db=session,
            )

        if db is not None:
            return await _load(db)
        async with SessionLocal() as session:
            return await _load(session)

    @staticmethod
    async def _silenced(
        *,
        recipient_id: uuid.UUID,
        actor_id: uuid.UUID,
        conversation_id: uuid.UUID,
        db: AsyncSession,
    ) -> bool:
        """True when the recipient muted this chat (conversation_prefs,
        batch 3) or muted the actor as a person (mutes, M1)."""
        pref = await ConversationPrefsService.get(
            conversation_id=conversation_id, user_id=recipient_id, db=db
        )
        if ConversationPrefsService.is_muted(pref):
            return True
        muted_people = await ConversationPrefsService.muted_user_ids(user_id=recipient_id, db=db)
        return actor_id in muted_people

    @staticmethod
    async def _dispatch_simple(
        *,
        recipient_id: uuid.UUID,
        title: str,
        body: str,
        data: dict[str, str],
        collapse_key: str,
        prefs: PushPrefs | None = None,
        channel_id: str = PUSH_CHANNEL_MESSAGES,
    ) -> None:
        """Single-recipient push (fire-and-forget). Carries the recipient's
        unread total as the icon badge — a number, never content. `prefs`
        (tone / channel / priority) wins over the bare `channel_id`."""
        sound: str | None = "default"
        high_priority = True
        if prefs is not None:
            sound, channel_id, high_priority = prefs.sound, prefs.channel_id, prefs.high_priority
        try:
            sender = _sender()
            async with SessionLocal() as db:
                rows = (
                    await db.scalars(
                        select(DeviceToken).where(DeviceToken.user_id == recipient_id)
                    )
                ).all()
                badge = (
                    await MessageService.unread_total(user_id=recipient_id, db=db) if rows else None
                )
                for row in rows:
                    result = await sender.send(
                        token=row.token,
                        title=title,
                        body=body,
                        data=data,
                        collapse_key=collapse_key,
                        badge=badge,
                        sound=sound,
                        channel_id=channel_id,
                        high_priority=high_priority,
                    )
                    log.info("push %s user=%s platform=%s", result.value, recipient_id, row.platform)
                    if result is PushResult.DEAD:
                        await db.delete(row)
                await db.commit()
        except Exception:  # noqa: BLE001 — never propagate into the caller
            log.exception("simple push dispatch failed for user %s", recipient_id)

    @staticmethod
    async def _dispatch(
        *,
        conversation_id: uuid.UUID,
        recipient_ids: list[uuid.UUID],
        sender_id: uuid.UUID,
        skip_ids: set[uuid.UUID] | None = None,
    ) -> None:
        skip = skip_ids or set()
        try:
            sender = _sender()
            # PHI-free by policy — constants only, plus the conversation UUID
            # for deep-linking. Nothing else may ever be added here.
            data = {"type": "new_message", "conversation_id": str(conversation_id)}
            # Own session — the request session is closed by the time this runs.
            async with SessionLocal() as db:
                # The sender's name is directory data, not PHI — the body may
                # carry it. Message content never goes in a push.
                name = await db.scalar(select(User.full_name).where(User.id == sender_id))
                conv = await db.get(Conversation, conversation_id)
                for uid in recipient_ids:
                    if uid == sender_id or uid in skip:
                        continue
                    # Muted chat, or a muted person (batch 3 / M1): no banner.
                    # The message still arrives over WS and in the list.
                    pref = await ConversationPrefsService.get(
                        conversation_id=conversation_id, user_id=uid, db=db
                    )
                    if ConversationPrefsService.is_muted(pref) or sender_id in (
                        await ConversationPrefsService.muted_user_ids(user_id=uid, db=db)
                    ):
                        log.info("push muted user=%s conv=%s", uid, conversation_id)
                        continue
                    prefs = await PushService._prefs_for(
                        recipient_id=uid, conversation_id=conversation_id, conv=conv, db=db, pref=pref
                    )
                    # The banner collapses per conversation, so it carries the
                    # unread count: eight messages read "8 new messages", not
                    # one indistinguishable banner.
                    unread = 0
                    if conv is not None:
                        counts = await MessageService.unread_counts(
                            conversations=[conv], user_id=uid, db=db
                        )
                        unread = counts.get(conversation_id, 0)
                    body = new_message_body(name, unread)
                    badge = await MessageService.unread_total(user_id=uid, db=db)
                    # No presence gate: a killed/backgrounded iOS app keeps its
                    # socket "open" for minutes, and FCM already suppresses
                    # foreground display on both platforms — no duplicates.
                    rows = (
                        await db.scalars(
                            select(DeviceToken).where(DeviceToken.user_id == uid)
                        )
                    ).all()
                    for row in rows:
                        result = await sender.send(
                            token=row.token,
                            title=PUSH_TITLE,
                            body=body,
                            data=data,
                            collapse_key=str(conversation_id),
                            badge=badge,
                            sound=prefs.sound,
                            channel_id=prefs.channel_id,
                            high_priority=prefs.high_priority,
                        )
                        log.info(
                            "push %s user=%s platform=%s conv=%s",
                            result.value, uid, row.platform, conversation_id,
                        )
                        if result is PushResult.DEAD:
                            await db.delete(row)  # permanently-invalid token
                await db.commit()
        except Exception:  # noqa: BLE001 — never propagate into the send path
            log.exception("push dispatch failed for conversation %s", conversation_id)
