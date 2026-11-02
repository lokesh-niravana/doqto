import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/websocket_client.dart';
import 'package:doqto_app/data/models/group.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/groups_repository.dart';
import 'package:doqto_app/data/services/groups_cache.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/groups_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_socket.dart';

Group _group(String id, {String name = 'Cardiology'}) => Group.fromJson({
      'id': id,
      'name': name,
      'member_count': 2,
      'conversation_id': 'conv-$id',
      'my_role': 'member',
      'my_state': 'active',
    });

GroupMember _member(String id) => GroupMember.fromJson({
      'user_id': id,
      'full_name': 'Dr $id',
      'role': 'member',
      'state': 'active',
    });

class _Repo extends GroupsRepository {
  _Repo() : super(ApiClient());
  final calls = <String, int>{};
  void _count(String k) => calls[k] = (calls[k] ?? 0) + 1;
  String g1Name = 'Cardiology';

  @override
  Future<Group> getGroup(String id) async {
    _count('detail:$id');
    return _group(id, name: id == 'g1' ? g1Name : 'Other');
  }

  @override
  Future<List<GroupMember>> members(String groupId) async {
    _count('members:$groupId');
    return [_member('u1'), _member('u2')];
  }

  @override
  Future<List<Group>> myGroups({String state = 'member'}) async {
    _count('mine:$state');
    return state == 'member' ? [_group('g1')] : const [];
  }
}

class _NoCache extends GroupsCache {
  @override
  List<Group>? myGroups() => null;
  @override
  Future<void> putMyGroups(List<Group> list) async {}
}

class _Me extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        AuthStage.signedIn,
        User.fromJson({
          'id': 'me',
          'phone': '+15550000101',
          'full_name': 'Me',
          'npi_number': '1234567893',
          'role': 'doctor',
          'created_at': '2026-09-05T00:00:00Z',
        }),
      );
}

void main() {
  late _Repo repo;
  late FakeSocket socket;
  late ProviderContainer c;

  setUp(() {
    repo = _Repo();
    socket = FakeSocket();
    c = ProviderContainer(overrides: [
      websocketClientProvider.overrideWithValue(socket),
      groupsRepositoryProvider.overrideWithValue(repo),
      groupsCacheProvider.overrideWithValue(_NoCache()),
      authProvider.overrideWith(_Me.new),
      realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
    ]);
  });
  tearDown(() => c.dispose());

  test('group detail refetches on its own events only', () async {
    final sub = c.listen(groupDetailProvider('g1'), (_, _) {});
    addTearDown(sub.close);
    await c.read(groupDetailProvider('g1').future);
    expect(repo.calls['detail:g1'], 1);

    repo.g1Name = 'Cardiology Leads';
    socket.emit(WsEventServer.groupUpdated, {'group_id': 'g1'});
    await settle();
    expect(repo.calls['detail:g1'], 2);
    expect(c.read(groupDetailProvider('g1')).value!.name, 'Cardiology Leads');

    socket.emit(WsEventServer.groupUpdated, {'group_id': 'g2'});
    socket.emit(WsEventServer.memberRemoved, {'conversation_id': 'conv-g2'});
    await settle();
    expect(repo.calls['detail:g1'], 2, reason: 'another group');

    // Member events are keyed by conversation id.
    socket.emit(WsEventServer.memberRemoved,
        {'conversation_id': 'conv-g1', 'user_id': 'u2'});
    await settle();
    socket.emit(WsEventServer.groupMemberJoined, {'group_id': 'g1'});
    await settle();
    expect(repo.calls['detail:g1'], 4);

    // Same tick → one refetch (the coalescer), not two.
    socket.emit(WsEventServer.groupUpdated, {'group_id': 'g1'});
    socket.emit(WsEventServer.groupUpdated, {'group_id': 'g1'});
    await settle();
    expect(repo.calls['detail:g1'], 5);
  });

  test('member list refetches on joins, removals and role changes', () async {
    final sub = c.listen(groupMembersProvider('g1'), (_, _) {});
    addTearDown(sub.close);
    final detail = c.listen(groupDetailProvider('g1'), (_, _) {});
    addTearDown(detail.close);
    await c.read(groupDetailProvider('g1').future);
    await c.read(groupMembersProvider('g1').future);
    expect(repo.calls['members:g1'], 1);

    socket.emit(WsEventServer.groupMemberJoined, {'group_id': 'g1'});
    await settle();
    socket.emit(WsEventServer.memberRemoved, {'conversation_id': 'conv-g1'});
    await settle();
    socket.emit(WsEventServer.groupUpdated, {'group_id': 'g1'}); // roles
    await settle();
    expect(repo.calls['members:g1'], 4);

    socket.emit(WsEventServer.groupMemberJoined, {'group_id': 'g2'});
    await settle();
    expect(repo.calls['members:g1'], 4);
  });

  test('my groups refresh on invites, joins, updates and my own removal',
      () async {
    await c.read(myGroupsProvider.future);
    expect(repo.calls['mine:member'], 1);

    socket.emit(WsEventServer.groupInviteReceived, {'group_id': 'g3'});
    await settle();
    socket.emit(WsEventServer.groupMemberJoined, {'group_id': 'g1'});
    await settle();
    socket.emit(WsEventServer.groupUpdated, {'group_id': 'g1'});
    await settle();
    expect(repo.calls['mine:member'], 4);

    socket.emit(WsEventServer.memberRemoved,
        {'conversation_id': 'conv-g1', 'user_id': 'someone-else'});
    await settle();
    expect(repo.calls['mine:member'], 4, reason: 'not my membership');

    socket.emit(WsEventServer.memberRemoved,
        {'conversation_id': 'conv-g1', 'user_id': 'me'});
    await settle();
    expect(repo.calls['mine:member'], 5);

    socket.emitState(WsConnState.connected);
    await settle();
    expect(repo.calls['mine:member'], 6);
  });
}
