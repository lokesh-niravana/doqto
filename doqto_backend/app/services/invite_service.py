"""Invite a colleague: look doctors up in the NPI Registry, tell the viewer
which are already on Doqto, and remember invites so the invitee is connected
to whoever invited them the moment their registration finishes.

The registry is public data; a Doqto account behind an NPI is only revealed
when people search would show that doctor to this viewer anyway
(`_visibility`). Everyone else reads as "invite".
"""
from __future__ import annotations

import asyncio
import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime

import httpx
from sqlalchemy import and_, or_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core.enums import InvitationStatus, WsEventServer
from app.models import AppInvite, Connection, ConnectionInvitation, User, UserPrivacySettings
from app.services.notification_service import TYPE_INVITE_JOINED, NotificationService
from app.services.org_directory_service import NPPES_URL
from app.services.people_search_service import _visibility
from app.services.relationship_service import RelationshipService

_TITLE = re.compile(r"^(dr\.?|doctor)\s+", re.I)
# Allopathic (207) and osteopathic (208) physician taxonomy codes.
_PHYSICIAN = re.compile(r"^20[78]")
MAX_HITS = 25


@dataclass
class NpiHit:
    npi: str
    name: str
    specialty: str | None
    location: str | None
    # message (connected) | requested (you asked) | connect | invite
    status: str
    user_id: uuid.UUID | None = None


async def fetch_nppes_people(params: dict[str, str]) -> list[dict]:
    """Raw NPPES individual (NPI-1) results. Patched in tests."""
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(
                NPPES_URL, params={"version": "2.1", "enumeration_type": "NPI-1", **params}
            )
        return resp.json().get("results", []) or []
    except (httpx.HTTPError, ValueError):
        return []


def _params(query: str, state: str | None) -> list[dict[str, str]]:
    q = _TITLE.sub("", query.strip()).replace(",", " ")
    if re.fullmatch(r"\d{10}", q):
        return [{"number": q}]
    words = [w for w in q.split() if w]
    if not words or len(words[-1]) < 2:
        return []
    # "Patel" → last name or first name; "Neel Patel" → first + last.
    # NPPES wildcards need two characters before the *.
    # Over-fetch: former names and non-physicians are dropped below.
    base = {"limit": "200", **({"state": state.upper()} if state else {})}
    if len(words) == 1:
        return [{"last_name": f"{words[0]}*", **base}, {"first_name": f"{words[0]}*", **base}]
    p = {"last_name": f"{words[-1]}*", **base}
    if len(words[0]) >= 2:
        p["first_name"] = f"{words[0]}*"
    return [p]


def _parse(r: dict) -> tuple[str, str, str | None, str | None] | None:
    b = r.get("basic") or {}
    first, last = (b.get("first_name") or "").title(), (b.get("last_name") or "").title()
    if not last:
        return None
    cred = (b.get("credential") or "").replace(".", "").strip()
    name = f"{first} {last}".strip() + (f", {cred}" if cred else "")
    primary = next((t for t in r.get("taxonomies", []) if t.get("primary")), {})
    if not _PHYSICIAN.match(primary.get("code") or ""):
        return None
    loc = next(
        (a for a in r.get("addresses", []) if a.get("address_purpose") == "LOCATION"), {}
    )
    city, st = (loc.get("city") or "").title(), loc.get("state") or ""
    where = ", ".join(x for x in (city, st) if x) or None
    return str(r.get("number")).zfill(10), name, primary.get("desc") or None, where


class InviteService:
    @staticmethod
    async def lookup(
        *, viewer_id: uuid.UUID, query: str, state: str | None, db: AsyncSession
    ) -> list[NpiHit]:
        queries = _params(query, state)
        if not queries:
            return []
        # NPPES also matches former names and lists A→Z, so "Patel" alone
        # returns hundreds of people once named Patel before any current one.
        # Keep current names only; a first name or state narrows the rest.
        def current(params: dict, r: dict) -> bool:
            b = r.get("basic") or {}
            return all(
                (b.get(k) or "").lower().startswith(params[k].rstrip("*").lower())
                for k in ("first_name", "last_name") if k in params
            )
        results = await asyncio.gather(*(fetch_nppes_people(p) for p in queries))
        seen_npis: set[str] = set()
        rows = []
        for params, raw in zip(queries, results):
            for r in raw:
                hit = current(params, r) and _parse(r)
                if hit and hit[0] not in seen_npis:
                    seen_npis.add(hit[0])
                    rows.append(hit)
        rows = rows[:MAX_HITS]
        npis = [r[0] for r in rows]

        viewer = await db.get(User, viewer_id)
        fd = await RelationshipService.first_degree_ids(viewer_id, db)
        blocked = await RelationshipService._blocked_ids(viewer_id, db)
        orgs = await RelationshipService._org_ids(viewer_id, db)
        _, visible = _visibility(viewer_id, fd, blocked, orgs)
        on_doqto = {
            u.npi_number: u.id
            for u in (
                await db.scalars(
                    select(User)
                    .outerjoin(UserPrivacySettings, UserPrivacySettings.user_id == User.id)
                    .where(*visible, User.npi_number.in_(npis))
                )
            ).all()
        } if npis else {}
        asked = set(
            (
                await db.scalars(
                    select(ConnectionInvitation.recipient_id).where(
                        ConnectionInvitation.sender_id == viewer_id,
                        ConnectionInvitation.status == InvitationStatus.PENDING.value,
                    )
                )
            ).all()
        )

        hits = []
        for npi, name, specialty, where in rows:
            if npi == viewer.npi_number:
                continue
            uid = on_doqto.get(npi)
            status = (
                "invite" if uid is None
                else "message" if uid in fd
                else "requested" if uid in asked
                else "connect"
            )
            hits.append(NpiHit(npi, name, specialty, where, status, uid))
        return hits

    @staticmethod
    async def record(*, inviter_id: uuid.UUID, npi: str, db: AsyncSession) -> None:
        await db.execute(
            insert(AppInvite)
            .values(inviter_id=inviter_id, npi=npi)
            .on_conflict_do_nothing()
        )

    @staticmethod
    async def connect_inviters(*, user: User, db: AsyncSession) -> None:
        """Connect a newly registered doctor to everyone who invited their NPI,
        then tell each inviter. Commits."""
        invites = (
            await db.scalars(
                select(AppInvite)
                .join(User, User.id == AppInvite.inviter_id)
                .where(
                    AppInvite.npi == user.npi_number,
                    AppInvite.joined_at.is_(None),
                    AppInvite.inviter_id != user.id,
                    User.deleted_at.is_(None),
                )
            )
        ).all()
        now = datetime.now(UTC)
        joined: list[tuple[uuid.UUID, object]] = []
        for inv in invites:
            inv.joined_at = now
            a, b = inv.inviter_id, user.id
            if await RelationshipService.is_blocked_either_way(a, b, db):
                continue
            already = await db.scalar(
                select(Connection.pair_id).where(
                    Connection.user_id == a, Connection.connected_user_id == b
                )
            )
            if already is None:
                pair = uuid.uuid4()
                db.add_all([
                    Connection(user_id=a, connected_user_id=b, pair_id=pair),
                    Connection(user_id=b, connected_user_id=a, pair_id=pair),
                ])
            # Any request between them is settled by the connection.
            pending = (
                await db.scalars(
                    select(ConnectionInvitation).where(
                        ConnectionInvitation.status == InvitationStatus.PENDING.value,
                        or_(
                            and_(ConnectionInvitation.sender_id == a,
                                 ConnectionInvitation.recipient_id == b),
                            and_(ConnectionInvitation.sender_id == b,
                                 ConnectionInvitation.recipient_id == a),
                        ),
                    )
                )
            ).all()
            for p in pending:
                p.status = InvitationStatus.ACCEPTED
                p.responded_at = now
            notif = await NotificationService.create(
                db=db,
                user_id=a,
                type=TYPE_INVITE_JOINED,
                actor_id=b,
                subject_type="user",
                subject_id=b,
                payload={"actor_name": user.full_name},
            )
            joined.append((a, notif))
        await db.commit()

        for inviter_id, notif in joined:
            await RelationshipService.add_edge_cache(inviter_id, user.id)
            # Same event as an accepted request: the inviter's connection
            # list refreshes.
            await ws_manager.publish_to_users(
                [inviter_id],
                WsEventServer.INVITATION_ACCEPTED,
                {"user_id": str(user.id), "user_name": user.full_name},
            )
            unread = await NotificationService.unread_count(db=db, user_id=inviter_id)
            await NotificationService.publish(notification=notif, unread_count=unread)
