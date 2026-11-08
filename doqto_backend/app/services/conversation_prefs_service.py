"""Per-member conversation preferences (batch 3): pin, archive, mute, mark
unread, clear chat, delete chat. Everything here is private to one user —
other members never learn about it, and nothing it stores is PHI.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.constants import PINNED_CONVERSATIONS_MAX
from app.core.enums import ConversationType
from app.models import Conversation, ConversationPref, Mute
from app.schemas.conversation import ConversationPrefsIn, ConversationPrefsOut


class PrefsError(Exception):
    """Code string is the API `detail`; the router maps it to a status."""


class ConversationPrefsService:
    @staticmethod
    def to_out(pref: ConversationPref | None) -> ConversationPrefsOut:
        if pref is None:
            return ConversationPrefsOut()
        return ConversationPrefsOut.model_validate(pref)

    @staticmethod
    def is_muted(pref: ConversationPref | None, now: datetime | None = None) -> bool:
        if pref is None or pref.muted_until is None:
            return False
        return pref.muted_until > (now or datetime.now(tz=timezone.utc))

    @staticmethod
    def is_hidden(pref: ConversationPref | None, conv: Conversation) -> bool:
        """Deleted-for-me and nothing new since: off the list."""
        return (
            pref is not None
            and pref.hidden_until_seq is not None
            and conv.last_seq <= pref.hidden_until_seq
        )

    @staticmethod
    async def get(
        *, conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> ConversationPref | None:
        return await db.scalar(
            select(ConversationPref).where(
                ConversationPref.conversation_id == conversation_id,
                ConversationPref.user_id == user_id,
            )
        )

    @staticmethod
    async def for_user(
        *, user_id: uuid.UUID, db: AsyncSession, conversation_ids: list[uuid.UUID] | None = None
    ) -> dict[uuid.UUID, ConversationPref]:
        """All of one user's pref rows, keyed by conversation (one query)."""
        stmt = select(ConversationPref).where(ConversationPref.user_id == user_id)
        if conversation_ids is not None:
            if not conversation_ids:
                return {}
            stmt = stmt.where(ConversationPref.conversation_id.in_(conversation_ids))
        rows = await db.scalars(stmt)
        return {p.conversation_id: p for p in rows.all()}

    @staticmethod
    async def muted_user_ids(*, user_id: uuid.UUID, db: AsyncSession) -> set[uuid.UUID]:
        """People this user muted (user-level `mutes`, M1) — no pushes from them."""
        rows = await db.scalars(select(Mute.muted_user_id).where(Mute.user_id == user_id))
        return set(rows.all())

    @staticmethod
    async def update(
        *,
        conv: Conversation,
        user_id: uuid.UUID,
        body: ConversationPrefsIn,
        db: AsyncSession,
    ) -> tuple[ConversationPref, bool]:
        """Apply a partial update. Returns (row, changed). Idempotent: the
        same values again change nothing and raise nothing."""
        pref = await ConversationPrefsService.get(
            conversation_id=conv.id, user_id=user_id, db=db
        )
        if pref is None:
            pref = ConversationPref(conversation_id=conv.id, user_id=user_id)
            db.add(pref)
            await db.flush()
        changed = False
        provided = body.model_fields_set
        now = datetime.now(tz=timezone.utc)

        if "pinned" in provided and body.pinned is not None:
            if body.pinned and pref.pinned_at is None:
                count = await db.scalar(
                    select(func.count())
                    .select_from(ConversationPref)
                    .where(
                        ConversationPref.user_id == user_id,
                        ConversationPref.pinned_at.is_not(None),
                        ConversationPref.conversation_id != conv.id,
                    )
                )
                if (count or 0) >= PINNED_CONVERSATIONS_MAX:
                    raise PrefsError("pin_limit")
                pref.pinned_at = now
                changed = True
            elif not body.pinned and pref.pinned_at is not None:
                pref.pinned_at = None
                changed = True
        if "archived" in provided and body.archived is not None and pref.archived != body.archived:
            pref.archived = body.archived
            changed = True
        if "muted_until" in provided:
            # A mute that already lapsed reads the same as "not muted".
            new = body.muted_until
            if new is not None and new <= now:
                new = None
            if pref.muted_until != new:
                pref.muted_until = new
                changed = True
        for field in ("custom_tone", "custom_vibrate", "theme", "wallpaper"):
            if field in provided and getattr(pref, field) != getattr(body, field):
                setattr(pref, field, getattr(body, field))
                changed = True
        if (
            "marked_unread" in provided
            and body.marked_unread is not None
            and pref.marked_unread != body.marked_unread
        ):
            pref.marked_unread = body.marked_unread
            changed = True
        if body.delete_chat:
            # Groups are left, not deleted — the existing leave endpoint does
            # that. Direct chats: clear + hide until something new arrives.
            if conv.type == ConversationType.GROUP:
                raise PrefsError("delete_group_use_leave")
            if pref.cleared_before_seq != conv.last_seq or pref.hidden_until_seq != conv.last_seq:
                pref.cleared_before_seq = conv.last_seq
                pref.hidden_until_seq = conv.last_seq
                changed = True
            if pref.pinned_at is not None or pref.marked_unread:
                pref.pinned_at = None
                pref.marked_unread = False
                changed = True
        elif body.clear_chat and pref.cleared_before_seq != conv.last_seq:
            pref.cleared_before_seq = conv.last_seq
            changed = True
        if changed:
            pref.updated_at = now
            await db.flush()
        return pref, changed

    @staticmethod
    async def clear_marked_unread(
        *, conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> bool:
        """Opening a chat (mark read) drops its manual unread dot."""
        pref = await ConversationPrefsService.get(
            conversation_id=conversation_id, user_id=user_id, db=db
        )
        if pref is None or not pref.marked_unread:
            return False
        pref.marked_unread = False
        await db.flush()
        return True
