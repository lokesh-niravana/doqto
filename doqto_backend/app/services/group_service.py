"""Group lifecycle (M5): create, join-policy state machine, invites, membership
sync, role capabilities, ownership transfer, post-policy gate.

A Group is a `groups` row paired 1:1 with a NETWORK conversation (org_id NULL,
type=group). The **membership-sync invariant** is the spine of this service:
whenever `group_members` gains or loses an ACTIVE member, `conversation_members`
mirrors it (so the existing conversation/message endpoints gate group-chat
access with no new plumbing) and `group.member_count` is kept accurate. All of
that flows through `_add_membership` / `_remove_membership`, both of which call
the single `_sync_member` helper.

Every mutation is audit-logged. Notifications + WS fan out AFTER commit.
"""
from __future__ import annotations

import secrets
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import Request
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.ws_manager import ws_manager
from app.core import constants
from app.core.enums import (
    OrgStatus,
    AuditAction,
    ConversationType,
    GroupInviteState,
    GroupMemberDmPolicy,
    GroupMemberState,
    GroupPostPolicy,
    GroupRole,
    WsEventServer,
)
from app.core.permissions import can_add_to_group
from app.core.rate_limit import enforce_rate_limit
from app.models import (
    Organization,
    Conversation,
    ConversationMember,
    Group,
    GroupInvite,
    GroupMember,
    User,
)
from app.services.audit_service import AuditService
from app.services.message_service import MessageService
from app.services.notification_service import (
    TYPE_GROUP_INVITE_RECEIVED,
    NotificationService,
)
from app.services.relationship_service import RelationshipService

_ROLE_RANK = {
    GroupRole.OWNER: 3,
    GroupRole.ADMIN: 2,
    GroupRole.MODERATOR: 1,
    GroupRole.MEMBER: 0,
}


def _rank(role: str) -> int:
    return _ROLE_RANK[GroupRole(role)]


def _now() -> datetime:
    return datetime.now(timezone.utc)


class GroupError(Exception):
    def __init__(self, code: str, *, status_code: int = 400) -> None:
        super().__init__(code)
        self.code = code
        self.status_code = status_code


class GroupService:
    # ------------------------------------------------------------------ #
    # Membership sync invariant
    # ------------------------------------------------------------------ #
    @staticmethod
    async def _sync_member(
        group: Group, user_id: uuid.UUID, *, add: bool, db: AsyncSession
    ) -> None:
        """Mirror an ACTIVE group_members change onto conversation_members so the
        group chat's existing membership gate stays correct. Idempotent."""
        existing = await db.scalar(
            select(ConversationMember).where(
                ConversationMember.conversation_id == group.conversation_id,
                ConversationMember.user_id == user_id,
            )
        )
        if add:
            if existing is None:
                db.add(
                    ConversationMember(
                        conversation_id=group.conversation_id, user_id=user_id
                    )
                )
        else:
            if existing is not None:
                await db.delete(existing)

    @staticmethod
    async def _recount(group: Group, db: AsyncSession) -> None:
        n = await db.scalar(
            select(func.count())
            .select_from(GroupMember)
            .where(
                GroupMember.group_id == group.id,
                GroupMember.state == GroupMemberState.ACTIVE,
            )
        )
        group.member_count = int(n or 0)

    @staticmethod
    async def _get_member(
        group_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> GroupMember | None:
        return await db.scalar(
            select(GroupMember).where(
                GroupMember.group_id == group_id, GroupMember.user_id == user_id
            )
        )

    @staticmethod
    async def require_active_member(
        group: Group, user_id: uuid.UUID, db: AsyncSession
    ) -> GroupMember:
        m = await GroupService._get_member(group.id, user_id, db)
        if m is None or m.state != GroupMemberState.ACTIVE:
            raise GroupError("not_a_group_member", status_code=403)
        return m

    @staticmethod
    async def _add_membership(
        group: Group,
        user_id: uuid.UUID,
        *,
        role: GroupRole,
        invited_by: uuid.UUID | None,
        db: AsyncSession,
    ) -> GroupMember:
        """Insert or reactivate an ACTIVE group member + mirror + recount."""
        m = await GroupService._get_member(group.id, user_id, db)
        if m is None:
            m = GroupMember(
                group_id=group.id,
                user_id=user_id,
                role=role,
                state=GroupMemberState.ACTIVE,
                invited_by=invited_by,
            )
            db.add(m)
        else:
            m.state = GroupMemberState.ACTIVE
            m.role = role
            m.invited_by = invited_by
            m.joined_at = _now()
        await db.flush()
        await GroupService._sync_member(group, user_id, add=True, db=db)
        await GroupService._recount(group, db)
        return m

    @staticmethod
    async def _remove_membership(
        group: Group,
        member: GroupMember,
        *,
        state: GroupMemberState,
        db: AsyncSession,
    ) -> None:
        member.state = state
        await db.flush()
        await GroupService._sync_member(group, member.user_id, add=False, db=db)
        await GroupService._recount(group, db)

    # ------------------------------------------------------------------ #
    # Create
    # ------------------------------------------------------------------ #
    @staticmethod
    async def create(
        *,
        request: Request,
        owner: User,
        name: str,
        description: str | None,
        post_policy: GroupPostPolicy,
        member_dm_policy: GroupMemberDmPolicy,
        org_id: uuid.UUID | None,
        db: AsyncSession,
    ) -> Group:
        # Quotas: N/day + a hard cap on concurrently-owned active groups.
        await enforce_rate_limit(
            owner.id, "group_created", constants.GROUP_CREATE_QUOTA_PER_DAY, 86400
        )
        owned = await db.scalar(
            select(func.count()).select_from(Group).where(Group.owner_id == owner.id)
        )
        if (owned or 0) >= constants.GROUP_MAX_OWNED:
            raise GroupError("group_owner_limit", status_code=429)
        if org_id is not None:
            # Groups wait for the org to be verified.
            org = await db.get(Organization, org_id)
            if org is None or org.status != OrgStatus.ACTIVE:
                raise GroupError("org_not_verified", status_code=403)

        # One transaction: conversation (network group) + group + owner as
        # group_member(owner) AND conversation_member (via create_conversation).
        conv = await MessageService.create_conversation(
            org_id=None,
            creator_id=owner.id,
            conv_type=ConversationType.GROUP,
            name=name,
            member_ids=[],
            db=db,
        )
        group = Group(
            conversation_id=conv.id,
            name=name,
            description=description,
            post_policy=post_policy,
            member_dm_policy=member_dm_policy,
            owner_id=owner.id,
            org_id=org_id,
            member_count=1,
        )
        db.add(group)
        await db.flush()
        db.add(
            GroupMember(
                group_id=group.id,
                user_id=owner.id,
                role=GroupRole.OWNER,
                state=GroupMemberState.ACTIVE,
            )
        )
        await AuditService.log_request(
            request,
            user_id=owner.id,
            action=AuditAction.GROUP_CREATED,
            resource_type="group",
            resource_id=group.id,
            db=db,
        )
        await db.commit()
        await db.refresh(group)
        return group

    # ------------------------------------------------------------------ #
    # Membership helpers shared with the invite flow
    # ------------------------------------------------------------------ #
    @staticmethod
    async def _join_now(
        *,
        request: Request,
        user: User,
        group: Group,
        invited_by: uuid.UUID | None,
        db: AsyncSession,
    ) -> str:
        await GroupService._add_membership(
            group, user.id, role=GroupRole.MEMBER, invited_by=invited_by, db=db
        )
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.GROUP_JOINED,
            resource_type="group",
            resource_id=group.id,
            db=db,
        )
        conv = await db.scalar(
            select(Conversation).where(Conversation.id == group.conversation_id)
        )
        sys_msg = await MessageService.send_system(
            conv=conv, sender_id=user.id, content=f"{user.full_name} joined", db=db
        )
        sys_out = MessageService.to_out(sys_msg)
        recipients = await MessageService.member_ids(
            conversation_id=group.conversation_id, db=db
        )
        await db.commit()
        # Fan out: system banner into the open thread + explicit member-joined.
        await ws_manager.publish_to_users(
            recipients, WsEventServer.NEW_MESSAGE, sys_out.model_dump(mode="json")
        )
        await ws_manager.publish_to_users(
            [r for r in recipients if r != user.id],
            WsEventServer.GROUP_MEMBER_JOINED,
            {
                "group_id": str(group.id),
                "user_id": str(user.id),
                "user_name": user.full_name,
            },
        )
        return "joined"

    @staticmethod
    async def create_direct_invite(
        *, request: Request, inviter: User, group: Group, invitee_id: uuid.UUID, db: AsyncSession
    ) -> GroupInvite:
        await GroupService.require_active_member(group, inviter.id, db)
        if invitee_id == inviter.id:
            raise GroupError("cannot_invite_self")
        invitee = await db.scalar(select(User).where(User.id == invitee_id))
        if invitee is None:
            raise GroupError("user_unavailable", status_code=404)
        existing = await GroupService._get_member(group.id, invitee_id, db)
        if existing is not None and existing.state == GroupMemberState.ACTIVE:
            raise GroupError("already_a_member", status_code=409)

        # Consent boundary: NO bulk-add. The invitee must be reachable from the
        # inviter — 1st-degree connection OR same org (permission module).
        ctx = await RelationshipService.load_context(inviter.id, invitee_id, db)
        decision = can_add_to_group(ctx)
        if not decision.allowed:
            raise GroupError("not_invitable", status_code=403)

        invite = GroupInvite(
            group_id=group.id, inviter_id=inviter.id, invitee_id=invitee_id
        )
        db.add(invite)
        await db.flush()
        await AuditService.log_request(
            request,
            user_id=inviter.id,
            action=AuditAction.GROUP_INVITE_SENT,
            resource_type="group",
            resource_id=group.id,
            db=db,
            metadata={"invitee_id": str(invitee_id)},
        )
        notif = await NotificationService.create(
            db=db,
            user_id=invitee_id,
            type=TYPE_GROUP_INVITE_RECEIVED,
            actor_id=inviter.id,
            subject_type="group",
            subject_id=group.id,
            payload={"actor_name": inviter.full_name, "group_name": group.name},
        )
        unread = await NotificationService.unread_count(db=db, user_id=invitee_id)
        await db.commit()
        await ws_manager.publish_to_users(
            [invitee_id],
            WsEventServer.GROUP_INVITE_RECEIVED,
            {
                "group_id": str(group.id),
                "invite_id": str(invite.id),
                "inviter_id": str(inviter.id),
                "inviter_name": inviter.full_name,
                "group_name": group.name,
            },
        )
        await NotificationService.publish(notification=notif, unread_count=unread)
        return invite

    @staticmethod
    async def create_link_invite(
        *,
        request: Request,
        inviter: User,
        group: Group,
        max_uses: int | None,
        expires_at: datetime | None,
        db: AsyncSession,
    ) -> GroupInvite:
        member = await GroupService.require_active_member(group, inviter.id, db)
        # Link invites are broader reach than a direct invite → admin+ only.
        if _rank(member.role) < _rank(GroupRole.ADMIN):
            raise GroupError("not_authorized", status_code=403)
        token = secrets.token_urlsafe(constants.GROUP_INVITE_TOKEN_BYTES)
        invite = GroupInvite(
            group_id=group.id,
            inviter_id=inviter.id,
            token=token,
            max_uses=max_uses,
            expires_at=expires_at,
        )
        db.add(invite)
        await db.flush()
        await AuditService.log_request(
            request,
            user_id=inviter.id,
            action=AuditAction.GROUP_INVITE_SENT,
            resource_type="group",
            resource_id=group.id,
            db=db,
            metadata={"link": True},
        )
        await db.commit()
        await db.refresh(invite)
        return invite

    @staticmethod
    async def accept_direct_invite(
        *, request: Request, user: User, group: Group, invite_id: uuid.UUID, db: AsyncSession
    ) -> None:
        invite = await db.scalar(select(GroupInvite).where(GroupInvite.id == invite_id))
        if invite is None or invite.group_id != group.id or invite.invitee_id != user.id:
            raise GroupError("invite_not_found", status_code=404)
        if invite.state != GroupInviteState.PENDING:
            raise GroupError("invite_not_pending", status_code=409)
        invite.state = GroupInviteState.ACCEPTED
        await GroupService._accept_invite_membership(
            request=request, user=user, group=group, inviter_id=invite.inviter_id, db=db
        )

    @staticmethod
    async def accept_link_invite(
        *, request: Request, user: User, token: str, db: AsyncSession
    ) -> Group:
        invite = await db.scalar(select(GroupInvite).where(GroupInvite.token == token))
        if invite is None or invite.state != GroupInviteState.PENDING:
            raise GroupError("invite_not_found", status_code=404)
        if invite.expires_at is not None:
            exp = invite.expires_at
            if exp.tzinfo is None:
                exp = exp.replace(tzinfo=timezone.utc)
            if _now() >= exp:
                invite.state = GroupInviteState.EXPIRED
                await db.commit()
                raise GroupError("invite_expired", status_code=404)
        if invite.max_uses is not None and invite.use_count >= invite.max_uses:
            raise GroupError("invite_exhausted", status_code=409)
        group = await db.scalar(select(Group).where(Group.id == invite.group_id))
        if group is None:
            raise GroupError("invite_not_found", status_code=404)
        existing = await GroupService._get_member(group.id, user.id, db)
        if existing is not None and existing.state == GroupMemberState.ACTIVE:
            raise GroupError("already_a_member", status_code=409)
        invite.use_count += 1
        if invite.max_uses is not None and invite.use_count >= invite.max_uses:
            invite.state = GroupInviteState.ACCEPTED
        await GroupService._accept_invite_membership(
            request=request, user=user, group=group, inviter_id=invite.inviter_id, db=db
        )
        return group

    @staticmethod
    async def _accept_invite_membership(
        *,
        request: Request,
        user: User,
        group: Group,
        inviter_id: uuid.UUID,
        db: AsyncSession,
    ) -> None:
        await GroupService._add_membership(
            group, user.id, role=GroupRole.MEMBER, invited_by=inviter_id, db=db
        )
        await AuditService.log_request(
            request,
            user_id=user.id,
            action=AuditAction.GROUP_INVITE_ACCEPTED,
            resource_type="group",
            resource_id=group.id,
            db=db,
        )
        conv = await db.scalar(
            select(Conversation).where(Conversation.id == group.conversation_id)
        )
        sys_msg = await MessageService.send_system(
            conv=conv, sender_id=user.id, content=f"{user.full_name} joined", db=db
        )
        sys_out = MessageService.to_out(sys_msg)
        recipients = await MessageService.member_ids(
            conversation_id=group.conversation_id, db=db
        )
        await db.commit()
        await ws_manager.publish_to_users(
            recipients, WsEventServer.NEW_MESSAGE, sys_out.model_dump(mode="json")
        )
        await ws_manager.publish_to_users(
            [r for r in recipients if r != user.id],
            WsEventServer.GROUP_MEMBER_JOINED,
            {
                "group_id": str(group.id),
                "user_id": str(user.id),
                "user_name": user.full_name,
            },
        )

    @staticmethod
    async def decline_invite(
        *, user: User, group: Group, invite_id: uuid.UUID, db: AsyncSession
    ) -> None:
        invite = await db.scalar(select(GroupInvite).where(GroupInvite.id == invite_id))
        if invite is None or invite.group_id != group.id or invite.invitee_id != user.id:
            raise GroupError("invite_not_found", status_code=404)
        if invite.state != GroupInviteState.PENDING:
            raise GroupError("invite_not_pending", status_code=409)
        invite.state = GroupInviteState.DECLINED
        await db.commit()

    @staticmethod
    async def revoke_invite(
        *, actor: User, group: Group, invite_id: uuid.UUID, db: AsyncSession
    ) -> None:
        member = await GroupService.require_active_member(group, actor.id, db)
        if _rank(member.role) < _rank(GroupRole.ADMIN):
            raise GroupError("not_authorized", status_code=403)
        invite = await db.scalar(select(GroupInvite).where(GroupInvite.id == invite_id))
        if invite is None or invite.group_id != group.id:
            raise GroupError("invite_not_found", status_code=404)
        invite.state = GroupInviteState.REVOKED
        await db.commit()

    # ------------------------------------------------------------------ #
    # Roles, removal, ban, transfer (§9.3 capability matrix)
    # ------------------------------------------------------------------ #
    @staticmethod
    async def change_role(
        *,
        request: Request,
        actor: User,
        group: Group,
        target_id: uuid.UUID,
        new_role: GroupRole,
        db: AsyncSession,
    ) -> None:
        actor_m = await GroupService.require_active_member(group, actor.id, db)
        target_m = await GroupService._get_member(group.id, target_id, db)
        if target_m is None or target_m.state != GroupMemberState.ACTIVE:
            raise GroupError("member_not_found", status_code=404)
        if new_role == GroupRole.OWNER:
            raise GroupError("use_transfer_ownership")
        if target_m.role == GroupRole.OWNER:
            raise GroupError("cannot_change_owner_role", status_code=403)
        # Granting or revoking ADMIN is owner-only; moderator/member reshuffles
        # are allowed to admins who outrank the target.
        touches_admin = new_role == GroupRole.ADMIN or target_m.role == GroupRole.ADMIN
        if touches_admin:
            if actor_m.role != GroupRole.OWNER:
                raise GroupError("owner_only", status_code=403)
        else:
            if _rank(actor_m.role) < _rank(GroupRole.ADMIN) or _rank(actor_m.role) <= _rank(
                target_m.role
            ):
                raise GroupError("not_authorized", status_code=403)
        target_m.role = new_role
        await AuditService.log_request(
            request,
            user_id=actor.id,
            action=AuditAction.GROUP_ROLE_CHANGED,
            resource_type="group",
            resource_id=group.id,
            db=db,
            metadata={"member_id": str(target_id), "role": new_role.value},
        )
        await db.commit()

    @staticmethod
    async def remove_member(
        *, request: Request, actor: User, group: Group, target_id: uuid.UUID, db: AsyncSession
    ) -> None:
        """Self-leave (target == actor) or an admin removing another member.
        The owner cannot leave without transferring ownership first (409)."""
        actor_m = await GroupService.require_active_member(group, actor.id, db)
        is_self = target_id == actor.id
        if is_self:
            if actor_m.role == GroupRole.OWNER:
                raise GroupError("owner_must_transfer", status_code=409)
            target_m = actor_m
            state = GroupMemberState.LEFT
        else:
            target_m = await GroupService._get_member(group.id, target_id, db)
            if target_m is None or target_m.state != GroupMemberState.ACTIVE:
                raise GroupError("member_not_found", status_code=404)
            if _rank(actor_m.role) < _rank(GroupRole.ADMIN) or _rank(actor_m.role) <= _rank(
                target_m.role
            ):
                raise GroupError("not_authorized", status_code=403)
            state = GroupMemberState.REMOVED
        await GroupService._remove_membership(group, target_m, state=state, db=db)
        await AuditService.log_request(
            request,
            user_id=actor.id,
            action=(
                AuditAction.GROUP_MEMBER_LEFT
                if is_self
                else AuditAction.GROUP_MEMBER_REMOVED
            ),
            resource_type="group",
            resource_id=group.id,
            db=db,
            metadata={"member_id": str(target_id)},
        )
        recipients = await MessageService.member_ids(
            conversation_id=group.conversation_id, db=db
        )
        await db.commit()
        await ws_manager.publish_to_users(
            [*recipients, target_id],
            WsEventServer.MEMBER_REMOVED,
            {"conversation_id": str(group.conversation_id), "user_id": str(target_id)},
        )

    @staticmethod
    async def ban_member(
        *, request: Request, actor: User, group: Group, target_id: uuid.UUID, db: AsyncSession
    ) -> None:
        actor_m = await GroupService.require_active_member(group, actor.id, db)
        if _rank(actor_m.role) < _rank(GroupRole.ADMIN):
            raise GroupError("not_authorized", status_code=403)
        if target_id == actor.id:
            raise GroupError("cannot_ban_self")
        target_m = await GroupService._get_member(group.id, target_id, db)
        if target_m is None:
            raise GroupError("member_not_found", status_code=404)
        if target_m.role == GroupRole.OWNER or _rank(actor_m.role) <= _rank(target_m.role):
            raise GroupError("not_authorized", status_code=403)
        await GroupService._remove_membership(
            group, target_m, state=GroupMemberState.BANNED, db=db
        )
        await AuditService.log_request(
            request,
            user_id=actor.id,
            action=AuditAction.GROUP_MEMBER_REMOVED,
            resource_type="group",
            resource_id=group.id,
            db=db,
            metadata={"member_id": str(target_id), "banned": True},
        )
        recipients = await MessageService.member_ids(
            conversation_id=group.conversation_id, db=db
        )
        await db.commit()
        await ws_manager.publish_to_users(
            [*recipients, target_id],
            WsEventServer.MEMBER_REMOVED,
            {"conversation_id": str(group.conversation_id), "user_id": str(target_id)},
        )

    @staticmethod
    async def transfer_ownership(
        *, request: Request, actor: User, group: Group, new_owner_id: uuid.UUID, db: AsyncSession
    ) -> None:
        actor_m = await GroupService.require_active_member(group, actor.id, db)
        if actor_m.role != GroupRole.OWNER:
            raise GroupError("owner_only", status_code=403)
        if new_owner_id == actor.id:
            raise GroupError("already_owner")
        target_m = await GroupService._get_member(group.id, new_owner_id, db)
        if target_m is None or target_m.state != GroupMemberState.ACTIVE:
            raise GroupError("member_not_found", status_code=404)
        actor_m.role = GroupRole.ADMIN
        target_m.role = GroupRole.OWNER
        group.owner_id = new_owner_id
        await AuditService.log_request(
            request,
            user_id=actor.id,
            action=AuditAction.GROUP_OWNERSHIP_TRANSFERRED,
            resource_type="group",
            resource_id=group.id,
            db=db,
            metadata={"new_owner_id": str(new_owner_id)},
        )
        await db.commit()

    # ------------------------------------------------------------------ #
    # Post-policy gate + member DM policy (wired from the send path / M6)
    # ------------------------------------------------------------------ #
    @staticmethod
    async def check_post_allowed(
        *, conversation_id: uuid.UUID, user_id: uuid.UUID, db: AsyncSession
    ) -> bool:
        """True unless the conversation has a linked group whose post_policy is
        admins_only and the sender is not an owner/admin. Legacy org group chats
        (no groups row) are always allowed."""
        group = await db.scalar(
            select(Group).where(Group.conversation_id == conversation_id)
        )
        if group is None or group.post_policy == GroupPostPolicy.ALL_MEMBERS:
            return True
        member = await GroupService._get_member(group.id, user_id, db)
        if member is None or member.state != GroupMemberState.ACTIVE:
            return False
        return _rank(member.role) >= _rank(GroupRole.ADMIN)

    @staticmethod
    async def group_dm_decision(
        *, group: Group, actor_id: uuid.UUID, target_id: uuid.UUID, db: AsyncSession
    ) -> str:
        """member_dm_policy gate for a co-member DM opened FROM group context.
        Returns 'open' | 'request' | 'denied'. (Full group-context DM plumbing is
        M6; this is the standing gate.)"""
        actor_m = await GroupService._get_member(group.id, actor_id, db)
        target_m = await GroupService._get_member(group.id, target_id, db)
        if (
            actor_m is None
            or actor_m.state != GroupMemberState.ACTIVE
            or target_m is None
            or target_m.state != GroupMemberState.ACTIVE
        ):
            return "denied"
        if group.member_dm_policy == GroupMemberDmPolicy.DISABLED:
            return "denied"
        if group.member_dm_policy == GroupMemberDmPolicy.OPEN:
            return "open"
        return "request"
