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
}

final groupMembersProvider = AsyncNotifierProvider.autoDispose
    .family<GroupMembersNotifier, List<GroupMember>, String>(
        GroupMembersNotifier.new);
