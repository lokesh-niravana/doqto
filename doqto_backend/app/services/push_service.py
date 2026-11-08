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
    PUSH_TITLE,
)
from app.db.postgres import SessionLocal
from app.models import Conversation, DeviceToken, User
from app.services.message_service import MessageService

log = logging.getLogger("doqto.push")

# How long Apple/Google hold a push for a phone that is off or offline. The
# device gets it when it reconnects, app running or not. APNs keeps the newest
# per collapse id, so a conversation arrives as one up-to-date banner.
PUSH_TTL_SECONDS = 28 * 24 * 3600


def fcm_message(
    *, token: str, title: str, body: str, data: dict[str, str], collapse_key: str,
    now: float | None = None,
) -> dict:
    """FCM HTTP v1 message. Pure, so the delivery contract is testable."""
    now = time.time() if now is None else now
    return {
        "token": token,
        "notification": {"title": title, "body": body},
        "data": data,
        "android": {
            "collapse_key": collapse_key,
            "priority": "high",
            "ttl": f"{PUSH_TTL_SECONDS}s",
        },
        "apns": {
            "headers": {
                "apns-collapse-id": collapse_key,
                "apns-priority": "10",
                "apns-push-type": "alert",
                "apns-expiration": str(int(now) + PUSH_TTL_SECONDS),
            },
            "payload": {"aps": {"sound": "default"}},
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
        self, *, token: str, title: str, body: str, data: dict[str, str], collapse_key: str
    ) -> PushResult:
        """Deliver one push and say what happened."""
        ...


class DevLogPushSender:
    """Local dev stub — logs instead of sending."""

    async def send(
        self, *, token: str, title: str, body: str, data: dict[str, str], collapse_key: str
    ) -> bool:
        log.info("[FAKE PUSH] %s → %s / %s %s", token[:12], title, body, data)
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
        self, *, token: str, title: str, body: str, data: dict[str, str], collapse_key: str
    ) -> PushResult:
        message = fcm_message(
            token=token, title=title, body=body, data=data, collapse_key=collapse_key
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
            await PushService._dispatch_simple(
                recipient_id=uid,
                title=PUSH_TITLE,
                body=body,
                data={"type": "mention", "conversation_id": str(conversation_id)},
                collapse_key=str(conversation_id),
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
                name = await db.scalar(select(User.full_name).where(User.id == actor_id))
        except Exception:  # noqa: BLE001
            log.exception("reaction push name lookup failed")
            name = None
        await PushService._dispatch_simple(
            recipient_id=author_id,
            title=PUSH_TITLE,
            body=reaction_body(name, emoji),
            data={"type": "reaction", "conversation_id": str(conversation_id)},
            collapse_key=f"reaction:{conversation_id}",
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
            )
        )

    @staticmethod
    async def _dispatch_simple(
        *,
        recipient_id: uuid.UUID,
        title: str,
        body: str,
        data: dict[str, str],
        collapse_key: str,
    ) -> None:
        """Presence-gated single-recipient push (fire-and-forget)."""
        try:
            sender = _sender()
            async with SessionLocal() as db:
                rows = (
                    await db.scalars(
                        select(DeviceToken).where(DeviceToken.user_id == recipient_id)
                    )
                ).all()
                for row in rows:
                    result = await sender.send(
                        token=row.token,
                        title=title,
                        body=body,
                        data=data,
                        collapse_key=collapse_key,
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
