import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/websocket_client.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/org_repository.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/org_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_socket.dart';

Organization _org(String status) => Organization.fromJson({
      'id': 'o1',
      'name': 'Sim Clinic',
      'invite_code': 'ABC123',
      'status': status,
      'created_at': '2026-01-01T00:00:00Z',
    });

OrgMember _member(String id) => OrgMember.fromJson({
      'id': id,
      'full_name': 'Dr $id',
      'org_role': 'doctor',
      'joined_at': '2026-01-01T00:00:00Z',
    });

class _Repo extends OrgRepository {
  _Repo() : super(ApiClient());
  int memberLists = 0;
  @override
  Future<List<OrgMember>> members(String orgId) async {
    memberLists++;
    return [_member('u1'), _member('u2')];
  }
}

/// Signed in; counts how often the stage is re-resolved instead of hitting
/// the network.
class _Auth extends AuthNotifier {
  int refreshes = 0;
  @override
  AuthState build() => AuthState(
        AuthStage.pendingVerification,
        User.fromJson({
          'id': 'me',
          'phone': '+15550000101',
          'full_name': 'Me',
          'npi_number': '1234567893',
          'role': 'doctor',
          'created_at': '2026-09-05T00:00:00Z',
        }),
      );
  @override
  Future<void> refreshOrgStatus() async => refreshes++;
}

void main() {
  late _Repo repo;
  late FakeSocket socket;
  late ProviderContainer c;
  late _Auth auth;

  setUp(() {
    repo = _Repo();
    socket = FakeSocket();
    c = ProviderContainer(overrides: [
      websocketClientProvider.overrideWithValue(socket),
      orgRepositoryProvider.overrideWithValue(repo),
      authProvider.overrideWith(_Auth.new),
      realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
    ]);
    auth = c.read(authProvider.notifier) as _Auth;
    c.read(orgProvider.notifier).setCurrent(_org('pending'));
  });
  tearDown(() => c.dispose());

  test('a verification decision re-resolves the auth stage — no polling',
      () async {
    socket.emit(WsEventServer.orgUpdated, {'org_id': 'o1', 'status': 'active'});
    await settle();
    expect(auth.refreshes, 1);
  });

  test('an org event without a status change is not a stage change', () async {
    // Someone joined: members refresh (below), but auth stays put.
    socket.emit(WsEventServer.orgUpdated, {'org_id': 'o1', 'status': 'pending'});
    await settle();
    expect(auth.refreshes, 0);
  });

  test('being added to an org we do not know about re-resolves too', () async {
    socket.emit(WsEventServer.orgUpdated, {'org_id': 'o9', 'status': 'active'});
    await settle();
    expect(auth.refreshes, 1);
  });

  test('members refetch on org changes, profile edits and reconnect', () async {
    final sub = c.listen(orgMembersProvider('o1'), (_, _) {});
    addTearDown(sub.close);
    await c.read(orgMembersProvider('o1').future);
    expect(repo.memberLists, 1);

    socket.emit(WsEventServer.orgUpdated, {'org_id': 'o1', 'status': 'pending'});
    await settle();
    expect(repo.memberLists, 2);

    socket.emit(WsEventServer.orgUpdated, {'org_id': 'other', 'status': 'active'});
    await settle();
    expect(repo.memberLists, 2);

    socket.emit(WsEventServer.profileUpdated, {'user_id': 'u2'});
    await settle();
    expect(repo.memberLists, 3);

    socket.emitState(WsConnState.connected);
    await settle();
    expect(repo.memberLists, 4);
  });
}
