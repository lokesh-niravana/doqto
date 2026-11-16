import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/websocket_client.dart';
import 'package:doqto_app/data/models/compliance.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/repositories/compliance_repository.dart';
import 'package:doqto_app/state/compliance_state.dart';
import 'package:doqto_app/state/org_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_socket.dart';

Organization _org() => Organization.fromJson({
      'id': 'o1',
      'name': 'Sim Clinic',
      'invite_code': 'ABC123',
      'status': 'active',
      'created_at': '2026-01-01T00:00:00Z',
      'policies': {'allow_copy': false},
    });

AccessRequest _req(String id, {String status = 'pending'}) => AccessRequest.fromJson({
      'id': id,
      'org_id': 'o1',
      'conversation_id': 'c1',
      'requester_id': 'u2',
      'reason': 'audit',
      'status': status,
      'created_at': '2026-11-01T00:00:00Z',
    });

class _Repo extends ComplianceRepository {
  _Repo() : super(ApiClient());
  int policyGets = 0;
  int requestGets = 0;
  bool fail = false;
  OrgPolicies current = const OrgPolicies(allowCopy: false);
  final patches = <Map<String, dynamic>>[];

  @override
  Future<OrgPolicies> policies(String orgId) async {
    policyGets++;
    return current;
  }

  @override
  Future<OrgPolicies> patchPolicies(String orgId, Map<String, dynamic> patch) async {
    patches.add(patch);
    if (fail) throw ApiException('org_admin_required', status: 403);
    current = current.apply(patch);
    return current;
  }

  @override
  Future<List<AccessRequest>> accessRequests(String orgId) async {
    requestGets++;
    return [_req('r1')];
  }

  @override
  Future<AccessRequest> approveAccessRequest(String orgId, String requestId) async {
    if (fail) throw ApiException('self_approval_forbidden', status: 403);
    return _req(requestId, status: 'approved');
  }
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
      complianceRepositoryProvider.overrideWithValue(repo),
      realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
    ]);
    c.read(orgProvider.notifier).setCurrent(_org());
  });
  tearDown(() => c.dispose());

  test('policies load once and refetch on org_updated for this org and on reconnect', () async {
    final sub = c.listen(orgPoliciesProvider('o1'), (_, _) {});
    addTearDown(sub.close);
    expect((await c.read(orgPoliciesProvider('o1').future)).allowCopy, isFalse);
    expect(repo.policyGets, 1);

    socket.emit(WsEventServer.orgUpdated, {'org_id': 'other', 'status': 'active'});
    await settle();
    expect(repo.policyGets, 1);

    repo.current = const OrgPolicies(allowCopy: true);
    socket.emit(WsEventServer.orgUpdated, {'org_id': 'o1', 'status': 'active'});
    await settle();
    expect(repo.policyGets, 2);
    expect(c.read(orgPoliciesProvider('o1')).value!.allowCopy, isTrue);

    socket.emitState(WsConnState.connected);
    await settle();
    expect(repo.policyGets, 3);
  });

  test('the effective policies fall back to the org snapshot until loaded', () async {
    repo.current = const OrgPolicies(allowCopy: true);
    expect(c.read(currentOrgPoliciesProvider).allowCopy, isFalse,
        reason: 'still loading: the org payload said allow_copy=false');
    final sub = c.listen(currentOrgPoliciesProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(orgPoliciesProvider('o1').future);
    expect(c.read(currentOrgPoliciesProvider).allowCopy, isTrue);
    c.read(orgProvider.notifier).clear();
    expect(c.read(currentOrgPoliciesProvider).allowCopy, isTrue, reason: 'no org = defaults');
  });

  test('a policy change is optimistic, sends one key and rolls back on failure', () async {
    final sub = c.listen(orgPoliciesProvider('o1'), (_, _) {});
    addTearDown(sub.close);
    await c.read(orgPoliciesProvider('o1').future);

    await c.read(orgPoliciesProvider('o1').notifier).change({'legal_hold': true});
    expect(repo.patches, [
      {'legal_hold': true}
    ]);
    expect(c.read(orgPoliciesProvider('o1')).value!.legalHold, isTrue);

    repo.fail = true;
    await expectLater(
      c.read(orgPoliciesProvider('o1').notifier).change({'retention_days': 30}),
      throwsA(isA<ApiException>()),
    );
    expect(c.read(orgPoliciesProvider('o1')).value!.retentionDays, isNull);
    expect(c.read(orgPoliciesProvider('o1')).value!.legalHold, isTrue);
  });

  test('access requests refetch on access_request_updated for this org', () async {
    final sub = c.listen(accessRequestsProvider('o1'), (_, _) {});
    addTearDown(sub.close);
    await c.read(accessRequestsProvider('o1').future);
    expect(repo.requestGets, 1);
    socket.emit(WsEventServer.accessRequestUpdated,
        {'org_id': 'o1', 'access_request_id': 'r1', 'status': 'approved'});
    await settle();
    expect(repo.requestGets, 2);
    socket.emit(WsEventServer.accessRequestUpdated,
        {'org_id': 'o9', 'access_request_id': 'r9', 'status': 'approved'});
    await settle();
    expect(repo.requestGets, 2);
  });

  test('approving patches the row at once and rolls back when refused', () async {
    final sub = c.listen(accessRequestsProvider('o1'), (_, _) {});
    addTearDown(sub.close);
    await c.read(accessRequestsProvider('o1').future);
    await c.read(accessRequestsProvider('o1').notifier).decide('r1', approve: true);
    expect(c.read(accessRequestsProvider('o1')).value!.single.status, AccessRequestStatus.approved);

    repo.fail = true;
    c.invalidate(accessRequestsProvider('o1'));
    await c.read(accessRequestsProvider('o1').future);
    await expectLater(
      c.read(accessRequestsProvider('o1').notifier).decide('r1', approve: true),
      throwsA(isA<ApiException>()),
    );
    expect(c.read(accessRequestsProvider('o1')).value!.single.status, AccessRequestStatus.pending);
  });
}
