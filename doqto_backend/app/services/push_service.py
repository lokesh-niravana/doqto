"""Push notification pipeline — sender-side, PHI-free, always pushed (no presence gate).

Dev default (PUSH_PROVIDER=log) is a logging stub;
real FCM slots in later via PUSH_PROVIDER=fcm + credentials in config.

Payload policy: title/body are the fixed constants PUSH_TITLE /
PUSH_BODY_NEW_MESSAGE (or "<sender name> sent you a message" — directory data,
not PHI). Never message content (HIPAA: pushes transit
Apple/Google unencrypted-to-us). Data carries only the conversation UUID for
deep-linking; collapse key dedupes per conversation.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from typing import Protocol

import httpx
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.sql import func

from app.core.config import settings
from app.core.constants import (
    PUSH_BODY_NEW_MESSAGE,
    PUSH_TITLE,
)
from app.db.postgres import SessionLocal
from app.models import DeviceToken, User

log = logging.getLogger("doqto.push")


class PushSender(Protocol):
    async def send(
        self, *, token: str, title: str, body: str, data: dict[str, str], collapse_key: str
    ) -> bool:
        """Deliver one push. Returns False iff the token is permanently
        invalid (unregistered/expired) and its row should be pruned."""
        ...


class DevLogPushSender:
    """Local dev stub — logs instead of sending."""

    async def send(
        self, *, token: str, title: str, body: str, data: dict[str, str], collapse_key: str
    ) -> bool:
        log.info("[FAKE PUSH] %s → %s / %s %s", token[:12], title, body, data)
        return True


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
    ) -> bool:
        message = {
            "token": token,
            "notification": {"title": title, "body": body},
            "data": data,
            "android": {"collapse_key": collapse_key, "priority": "high"},
            "apns": {
                "headers": {"apns-collapse-id": collapse_key, "apns-priority": "10"},
                "payload": {"aps": {"sound": "default"}},
            },
        }
        bearer = await asyncio.to_thread(self._bearer)
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                self._url, json={"message": message}, headers={"Authorization": f"Bearer {bearer}"}
            )
        if resp.status_code == 200:
            return True
        # UNREGISTERED / NOT_FOUND: token is dead, prune it. Anything else: keep.
        dead = resp.status_code == 404 or "UNREGISTERED" in resp.text
        log.warning("fcm send failed %s %s", resp.status_code, resp.text[:200])
        return not dead


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
    ) -> None:
        """Fire-and-forget: never blocks or fails the send path."""
        asyncio.create_task(
            PushService._dispatch(
                conversation_id=conversation_id,
                recipient_ids=recipient_ids,
                sender_id=sender_id,
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
                    ok = await sender.send(
                        token=row.token,
                        title=title,
                        body=body,
                        data=data,
                        collapse_key=collapse_key,
                    )
                    log.info("push %s user=%s", "sent" if ok else "dead-token", recipient_id)
                    if not ok:
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
    ) -> None:
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
                body = f"{name} sent you a message" if name else PUSH_BODY_NEW_MESSAGE
                for uid in recipient_ids:
                    if uid == sender_id:
                        continue
                    # No presence gate: a killed/backgrounded iOS app keeps its
                    # socket "open" for minutes, and FCM already suppresses
                    # foreground display on both platforms — no duplicates.
                    rows = (
                        await db.scalars(
                            select(DeviceToken).where(DeviceToken.user_id == uid)
                        )
                    ).all()
                    for row in rows:
                        ok = await sender.send(
                            token=row.token,
                            title=PUSH_TITLE,
                            body=body,
                            data=data,
                            collapse_key=str(conversation_id),
                        )
                        log.info("push %s user=%s conv=%s", "sent" if ok else "dead-token", uid, conversation_id)
                        if not ok:
                            await db.delete(row)  # permanently-invalid token
                await db.commit()
        except Exception:  # noqa: BLE001 — never propagate into the send path
            log.exception("push dispatch failed for conversation %s", conversation_id)
