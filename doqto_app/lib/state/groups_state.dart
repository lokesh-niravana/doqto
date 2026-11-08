import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/api/websocket_client.dart';
import '../data/models/group.dart';
import 'auth_state.dart';
import 'realtime_state.dart';

/// The two "My groups" buckets, tagged by which /me/groups query produced each
/// entry so the tab can render an Invited chip. Groups are invite-only, so
/// there is no third "requested" bucket.
class MyGroupsData {
  final List<Group> member;
  final List<Group> invited;

  const MyGroupsData({this.member = const [], this.invited = const []});

  bool get isEmpty => member.isEmpty && invited.isEmpty;
}

/// True when [event] is about group [groupId] — either by `group_id` or, for
/// the conversation-keyed member events, by the group's conversation id.
bool _isAboutGroup(WsEvent event, {required String groupId, String? conversationId}) {
  switch (event.type) {
    case WsEventServer.groupUpdated:
    case WsEventServer.groupMemberJoined:
    case WsEventServer.groupInviteReceived:
      return event.data['group_id'] == groupId;
    case WsEventServer.memberAdded:
    case WsEventServer.memberRemoved:
      return conversationId != null &&
          event.data['conversation_id'] == conversationId;
    default:
      return false;
  }
}

/// The signed-in user's groups. Cache-first (Hive) for the member list so a
/// cold start offline still paints; live-refreshes on every group event that
/// can change the buckets (joined, invited, updated, removed) and on
/// reconnect — same idiom as [ConnectionsNotifier].
class MyGroupsNotifier extends AsyncNotifier<MyGroupsData> {
  @override
  Future<MyGroupsData> build() async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        switch (event.type) {
          case WsEventServer.groupMemberJoined:
          case WsEventServer.groupInviteReceived:
          case WsEventServer.groupUpdated:
            refresh();
          case WsEventServer.memberRemoved:
            // Only my own removal changes which groups I'm in.
            if (event.data['user_id'] == ref.read(authProvider).user?.id) {
              refresh();
            }
          default:
            break;
        }
      },
    );

    final cache = ref.read(groupsCacheProvider);
    final cachedMembers = cache.myGroups();
    if (cachedMembers != null) {
      state = AsyncData(MyGroupsData(member: cachedMembers)); // instant paint
    }
    try {
      final data = await _fetch();
      await cache.putMyGroups(data.member);
      return data;
    } catch (_) {
      if (cachedMembers != null) {
        return MyGroupsData(member: cachedMembers);
      }
      rethrow;
    }
  }

  Future<MyGroupsData> _fetch() async {
    final repo = ref.read(groupsRepositoryProvider);
    // Member list is required; invited is a best-effort adornment.
    final member = (await repo.myGroups(state: 'member'))
        .map((g) => g.copyWith(membershipTag: GroupMembershipTag.member))
        .toList();
    List<Group> invited = const [];
    try {
      invited = (await repo.myGroups(state: 'invited'))
          .map((g) => g.copyWith(membershipTag: GroupMembershipTag.invited))
          .toList();
    } catch (_) {}
    return MyGroupsData(member: member, invited: invited);
  }

  Future<void> refresh() async {
    try {
      final data = await _fetch();
      await ref.read(groupsCacheProvider).putMyGroups(data.member);
      state = AsyncData(data); // stays on previous data → no flash
    } catch (_) {
      // Offline refresh: keep showing what we have.
    }
  }

  /// Accept a pending invite from the tab: the row jumps to "member" at once
  /// (role member, count +1); the server confirms with a refresh, a failure
  /// puts the invite back and rethrows for the snackbar.
  Future<void> acceptInvite(Group g) async {
    final inviteId = g.inviteId;
    final before = state.valueOrNull;
    if (inviteId == null || before == null) return;
    final optimistic = g.copyWith(
      myRole: GroupRole.member,
      myState: GroupMemberState.active,
      memberCount: g.memberCount + 1,
      membershipTag: GroupMembershipTag.member,
      clearInvite: true,
    );
    state = AsyncData(MyGroupsData(
      member: [optimistic, ...before.member],
      invited: [for (final x in before.invited) if (x.id != g.id) x],
    ));
    try {
      await ref.read(groupsRepositoryProvider).acceptInvite(g.id, inviteId);
      ref.invalidate(groupDetailProvider(g.id));
      await refresh();
    } catch (e) {
      state = AsyncData(before);
      rethrow;
    }
  }

  /// Decline: the row disappears at once; a failure brings it back.
  Future<void> declineInvite(Group g) async {
    final inviteId = g.inviteId;
    final before = state.valueOrNull;
    if (inviteId == null || before == null) return;
    state = AsyncData(MyGroupsData(
      member: before.member,
      invited: [for (final x in before.invited) if (x.id != g.id) x],
    ));
    try {
      await ref.read(groupsRepositoryProvider).declineInvite(g.id, inviteId);
    } catch (e) {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final myGroupsProvider =
    AsyncNotifierProvider<MyGroupsNotifier, MyGroupsData>(MyGroupsNotifier.new);

/// Self-loading detail for one group, keyed by id. Refetches in place when the
/// group changes under us (name/policies edited, a member joined or left,
/// roles moved) and on reconnect. Carries the leave flow with an optimistic
/// flip; every mutation invalidates [myGroupsProvider] so the tab stays
/// truthful. There is no join flow — groups are invite-only.
class GroupDetailNotifier extends FamilyAsyncNotifier<Group, String> {
  @override
  Future<Group> build(String groupId) async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        final convId = state.valueOrNull?.conversationId;
        if (_isAboutGroup(event, groupId: groupId, conversationId: convId)) {
          refresh();
        }
      },
    );
    return ref.read(groupsRepositoryProvider).getGroup(groupId);
  }

  Group? get _g => state.valueOrNull;

  Future<void> refresh() async {
    try {
      state = AsyncData(await ref.read(groupsRepositoryProvider).getGroup(arg));
    } catch (_) {
      // Keep showing what we have.
    }
  }

  Future<void> leave(String myUserId) async {
    final g = _g;
    if (g == null) return;
    state = AsyncData(g.copyWith(
      clearMyRole: true,
      membershipTag: GroupMembershipTag.none,
      memberCount: g.memberCount > 0 ? g.memberCount - 1 : 0,
    ));
    try {
      await ref.read(groupsRepositoryProvider).removeMember(arg, myUserId);
      ref.invalidate(myGroupsProvider);
      ref.invalidate(groupMembersProvider(arg));
    } catch (e) {
      state = AsyncData(g);
      rethrow;
    }
  }

  // ---- Invite (non-member with a pending invite) --------------------------

  /// Accept my pending invite: I become a member at once (so the chat opens
  /// without waiting); the server's answer confirms, a failure rolls back.
  Future<void> acceptInvite() async {
    final g = _g;
    final inviteId = g?.inviteId;
    if (g == null || inviteId == null) return;
    state = AsyncData(g.copyWith(
      myRole: GroupRole.member,
      myState: GroupMemberState.active,
      memberCount: g.memberCount + 1,
      membershipTag: GroupMembershipTag.member,
      clearInvite: true,
    ));
    try {
      await ref.read(groupsRepositoryProvider).acceptInvite(arg, inviteId);
      ref.invalidate(myGroupsProvider);
      ref.invalidate(groupMembersProvider(arg));
      await refresh();
    } catch (e) {
      state = AsyncData(g);
      rethrow;
    }
  }

  Future<void> declineInvite() async {
    final g = _g;
    final inviteId = g?.inviteId;
    if (g == null || inviteId == null) return;
    state = AsyncData(g.copyWith(clearInvite: true));
    try {
      await ref.read(groupsRepositoryProvider).declineInvite(arg, inviteId);
      ref.invalidate(myGroupsProvider);
    } catch (e) {
      state = AsyncData(g);
      rethrow;
    }
  }

  // ---- Owner / admin: identity + settings (optimistic, rollback) ---------

  Future<void> updateGroup({
    String? name,
    String? description,
    String? postPolicy,
    String? memberDmPolicy,
  }) async {
    final g = _g;
    if (g == null) return;
    state = AsyncData(g.copyWith(
      name: name,
      description: description,
      postPolicy: postPolicy,
      memberDmPolicy: memberDmPolicy,
    ));
    try {
      final fresh = await ref.read(groupsRepositoryProvider).updateGroup(
            arg,
            name: name,
            description: description,
            postPolicy: postPolicy,
            memberDmPolicy: memberDmPolicy,
          );
      state = AsyncData(fresh.copyWith(membershipTag: g.membershipTag));
      ref.invalidate(myGroupsProvider);
    } catch (e) {
      state = AsyncData(g);
      rethrow;
    }
  }

  Future<void> setAvatar(File file) async {
    final g = _g;
    if (g == null) return;
    final fresh = await ref.read(groupsRepositoryProvider).uploadAvatar(arg, file);
    state = AsyncData(fresh.copyWith(membershipTag: g.membershipTag));
    ref.invalidate(myGroupsProvider);
  }

  Future<void> removeAvatar() async {
    final g = _g;
    if (g == null) return;
    state = AsyncData(g.copyWith(clearAvatar: true));
    try {
      final fresh = await ref.read(groupsRepositoryProvider).deleteAvatar(arg);
      state = AsyncData(fresh.copyWith(membershipTag: g.membershipTag));
      ref.invalidate(myGroupsProvider);
    } catch (e) {
      state = AsyncData(g);
      rethrow;
    }
  }

  // ---- Owner / admin: members ---------------------------------------------

  Future<void> invite(String userId) =>
      ref.read(groupsRepositoryProvider).inviteUser(arg, userId);

  Future<void> changeRole(String userId, GroupRole role) async {
    final members = ref.read(groupMembersProvider(arg).notifier);
    final undo = members.applyRole(userId, role);
    try {
      await ref.read(groupsRepositoryProvider).changeRole(arg, userId, role);
    } catch (e) {
      undo();
      rethrow;
    }
  }

  Future<void> removeMember(String userId) => _drop(
        userId,
        () => ref.read(groupsRepositoryProvider).removeMember(arg, userId),
      );

  Future<void> banMember(String userId) => _drop(
        userId,
        () => ref.read(groupsRepositoryProvider).banMember(arg, userId),
      );

  Future<void> _drop(String userId, Future<void> Function() call) async {
    final g = _g;
    final members = ref.read(groupMembersProvider(arg).notifier);
    final undo = members.drop(userId);
    if (g != null) {
      state = AsyncData(g.copyWith(
        memberCount: g.memberCount > 0 ? g.memberCount - 1 : 0,
      ));
    }
    try {
      await call();
    } catch (e) {
      undo();
      if (g != null) state = AsyncData(g);
      rethrow;
    }
  }

  /// Owner → admin, target → owner. Both rows flip at once.
  Future<void> transferOwnership(String userId, String myUserId) async {
    final g = _g;
    final members = ref.read(groupMembersProvider(arg).notifier);
    final undoMe = members.applyRole(myUserId, GroupRole.admin);
    final undoThem = members.applyRole(userId, GroupRole.owner);
    if (g != null) state = AsyncData(g.copyWith(myRole: GroupRole.admin));
    try {
      await ref.read(groupsRepositoryProvider).transferOwnership(arg, userId);
      await refresh();
    } catch (e) {
      undoThem();
      undoMe();
      if (g != null) state = AsyncData(g);
      rethrow;
    }
  }
}

final groupDetailProvider =
    AsyncNotifierProvider.family<GroupDetailNotifier, Group, String>(
        GroupDetailNotifier.new);

/// Active members of a group (auto-disposed with the screen). Refetches in
/// place on joins, removals, role changes and reconnect.
class GroupMembersNotifier
    extends AutoDisposeFamilyAsyncNotifier<List<GroupMember>, String> {
  @override
  Future<List<GroupMember>> build(String groupId) async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        // The detail provider (if built) knows the conversation id that the
        // member_added/removed events are keyed by.
        final convId = ref.exists(groupDetailProvider(groupId))
            ? ref.read(groupDetailProvider(groupId)).valueOrNull?.conversationId
            : null;
        if (_isAboutGroup(event, groupId: groupId, conversationId: convId)) {
          refresh();
        }
      },
    );
    return ref.read(groupsRepositoryProvider).members(groupId);
  }

  Future<void> refresh() async {
    try {
      state = AsyncData(await ref.read(groupsRepositoryProvider).members(arg));
    } catch (_) {
      // Keep showing what we have.
    }
  }

  /// Optimistic role flip; returns the undo.
  void Function() applyRole(String userId, GroupRole role) {
    final before = state.valueOrNull;
    if (before == null) return () {};
    state = AsyncData([
      for (final m in before) if (m.userId == userId) m.copyWith(role: role) else m,
    ]);
    return () => state = AsyncData(before);
  }

  /// Optimistic removal; returns the undo.
  void Function() drop(String userId) {
    final before = state.valueOrNull;
    if (before == null) return () {};
    state = AsyncData([for (final m in before) if (m.userId != userId) m]);
    return () => state = AsyncData(before);
  }
}

final groupMembersProvider = AsyncNotifierProvider.autoDispose
    .family<GroupMembersNotifier, List<GroupMember>, String>(
        GroupMembersNotifier.new);

/// Pending invites (direct + link) of a group — owner/admin only; the server
/// answers 403 for members, which the section hides on. Create and revoke
/// are optimistic; `group_updated` (a decline, a revoke elsewhere) refreshes.
class GroupInvitesNotifier
    extends AutoDisposeFamilyAsyncNotifier<List<GroupInvite>, String> {
  @override
  Future<List<GroupInvite>> build(String groupId) async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        if (event.type == WsEventServer.groupUpdated &&
            event.data['group_id'] == groupId) {
          refresh();
        }
      },
    );
    return ref.read(groupsRepositoryProvider).listInvites(groupId);
  }

  Future<void> refresh() async {
    try {
      state = AsyncData(await ref.read(groupsRepositoryProvider).listInvites(arg));
    } catch (_) {}
  }

  Future<GroupInvite> createLink({int? maxUses, DateTime? expiresAt}) async {
    final invite = await ref
        .read(groupsRepositoryProvider)
        .createLinkInvite(arg, maxUses: maxUses, expiresAt: expiresAt);
    state = AsyncData([invite, ...(state.valueOrNull ?? const [])]);
    return invite;
  }

  Future<void> revoke(String inviteId) async {
    final before = state.valueOrNull ?? const <GroupInvite>[];
    state = AsyncData([for (final i in before) if (i.id != inviteId) i]);
    try {
      await ref.read(groupsRepositoryProvider).revokeInvite(arg, inviteId);
    } catch (e) {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final groupInvitesProvider = AsyncNotifierProvider.autoDispose
    .family<GroupInvitesNotifier, List<GroupInvite>, String>(
        GroupInvitesNotifier.new);
