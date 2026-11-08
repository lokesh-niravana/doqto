import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/compliance.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/compliance_repository.dart';
import 'package:doqto_app/data/repositories/org_repository.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/org_state.dart';
import 'package:doqto_app/state/realtime_state.dart';
import 'package:doqto_app/ui/screens/my_org/access_requests_screen.dart';
import 'package:doqto_app/ui/screens/my_org/org_policies_screen.dart';
import 'package:doqto_app/ui/screens/my_org/org_reports_screen.dart';

import '../support/fake_socket.dart';

// My Org → Policies / Access requests / Reports (batch 7).

Organization _org() => Organization.fromJson({
      'id': 'o1',
      'name': 'Sim Clinic',
      'invite_code': 'ABC123',
      'status': 'active',
      'created_at': '2026-01-01T00:00:00Z',
    });

OrgMember _member(String id, String role) => OrgMember.fromJson({
      'id': id,
      'full_name': 'Dr $id',
      'org_role': role,
      'joined_at': '2026-01-01T00:00:00Z',
    });

AccessRequest _req(String id, {required String requester, String status = 'pending', String? expires}) =>
    AccessRequest.fromJson({
      'id': id,
      'org_id': 'o1',
      'conversation_id': 'c1',
      'requester_id': requester,
      'reason': 'Reason for $id',
      'status': status,
      'expires_at': expires,
      'created_at': '2026-11-01T00:00:00Z',
    });

OrgReport _report(String id, String status, {String reason = 'spam'}) => OrgReport.fromJson({
      'id': id,
      'reporter_id': 'u2',
      'subject_type': 'message',
      'subject_id': 'm1',
      'reason': reason,
      'details': 'details $id',
      'status': status,
      'created_at': '2026-11-01T00:00:00Z',
    });

class _OrgRepo extends OrgRepository {
  _OrgRepo(this.myRole) : super(ApiClient());
  final String myRole;
  @override
  Future<List<OrgMember>> members(String orgId) async => [_member('me', myRole), _member('u2', 'admin')];
}

class _Repo extends ComplianceRepository {
  _Repo() : super(ApiClient());
  OrgPolicies current = const OrgPolicies();
  final patches = <Map<String, dynamic>>[];
  bool fail = false;
  List<AccessRequest> requests = [];
  final decisions = <String>[];
  Map<String, String>? created;
  List<OrgReport> reportRows = [];
  final statusChanges = <(String, ReportStatus)>[];

  @override
  Future<OrgPolicies> policies(String orgId) async => current;
  @override
  Future<OrgPolicies> patchPolicies(String orgId, Map<String, dynamic> patch) async {
    patches.add(patch);
    if (fail) throw ApiException('org_admin_required', status: 403);
    current = current.apply(patch);
    return current;
  }

  @override
  Future<List<AccessRequest>> accessRequests(String orgId) async => requests;
  @override
  Future<AccessRequest> approveAccessRequest(String orgId, String requestId) async {
    decisions.add('approve:$requestId');
    return requests.firstWhere((r) => r.id == requestId).copyWith(status: AccessRequestStatus.approved);
  }

  @override
  Future<AccessRequest> rejectAccessRequest(String orgId, String requestId) async {
    decisions.add('reject:$requestId');
    return requests.firstWhere((r) => r.id == requestId).copyWith(status: AccessRequestStatus.rejected);
  }

  @override
  Future<AccessRequest> createAccessRequest(String orgId,
      {required String conversationId, required String reason}) async {
    created = {'conversation_id': conversationId, 'reason': reason};
    return _req('new', requester: 'me');
  }

  @override
  Future<List<OrgReport>> reports(String orgId, {String status = 'all'}) async => reportRows;
  @override
  Future<OrgReport> setReportStatus(String orgId, String reportId, ReportStatus status) async {
    statusChanges.add((reportId, status));
    if (fail) throw ApiException('report_not_found', status: 404);
    return reportRows.firstWhere((r) => r.id == reportId).copyWith(status: status);
  }
}

class _Auth extends AuthNotifier {
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

late _Repo _repo;

Widget _app(Widget home, {String myRole = 'admin'}) {
  final socket = FakeSocket();
  return ProviderScope(
    overrides: [
      websocketClientProvider.overrideWithValue(socket),
      complianceRepositoryProvider.overrideWithValue(_repo),
      orgRepositoryProvider.overrideWithValue(_OrgRepo(myRole)),
      authProvider.overrideWith(_Auth.new),
      realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
    ],
    child: Consumer(builder: (context, ref, child) {
      // Seed the current org once the scope exists.
      final org = ref.watch(orgProvider).current;
      if (org == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(orgProvider.notifier).setCurrent(_org()));
      }
      return MaterialApp(home: home);
    }),
  );
}

Future<void> _open(WidgetTester tester, Widget home, {String myRole = 'admin'}) async {
  await tester.pumpWidget(_app(home, myRole: myRole));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => _repo = _Repo());

  group('Policies', () {
    testWidgets('admin: a switch sends a one-key PATCH; legal hold asks first', (tester) async {
      await _open(tester, const OrgPoliciesScreen());
      expect(find.text(Strings.orgPoliciesTitle), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('policy-switch-allow_copy')));
      await tester.pumpAndSettle();
      expect(_repo.patches, [
        {'allow_copy': false}
      ]);

      final list = find.descendant(
          of: find.byKey(const ValueKey('policies-list')), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('policy-switch-legal_hold')), 120,
          scrollable: list);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('policy-switch-legal_hold')));
      await tester.pumpAndSettle();
      expect(find.text(Strings.orgPolicyLegalHoldOnTitle), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('policy-confirm-cancel')));
      await tester.pumpAndSettle();
      expect(_repo.patches, hasLength(1), reason: 'cancel sends nothing');

      await tester.tap(find.byKey(const ValueKey('policy-switch-legal_hold')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('policy-confirm-ok')));
      await tester.pumpAndSettle();
      expect(_repo.patches.last, {'legal_hold': true});
      expect(find.byKey(const ValueKey('policy-legal-hold-note')), findsOneWidget);
    });

    testWidgets('admin: retention confirms and a refused save rolls back', (tester) async {
      await _open(tester, const OrgPoliciesScreen());
      final list = find.descendant(
          of: find.byKey(const ValueKey('policies-list')), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('policy-row-retention_days')), 120,
          scrollable: list);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('policy-row-retention_days')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('policy-opt-retention_days-90')));
      await tester.pumpAndSettle();
      expect(find.text(Strings.orgPolicyRetentionTitle), findsOneWidget);
      _repo.fail = true;
      await tester.tap(find.byKey(const ValueKey('policy-confirm-ok')));
      await tester.pumpAndSettle();
      expect(_repo.patches, [
        {'retention_days': 90}
      ]);
      expect(find.text(Strings.orgPolicyRetentionForever), findsOneWidget, reason: 'rolled back');
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('member: read-only values, no switches', (tester) async {
      _repo.current = const OrgPolicies(allowCopy: false, retentionDays: 30, legalHold: true);
      await _open(tester, const OrgPoliciesScreen(), myRole: 'doctor');
      expect(find.text(Strings.myOrgMemberPolicies), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.byKey(const ValueKey('policy-switch-allow_copy')), findsNothing);
      expect(tester.widget<Text>(find.byKey(const ValueKey('policy-value-allow_copy'))).data, Strings.policyOff);
      final list = find.descendant(
          of: find.byKey(const ValueKey('policies-list')), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('policy-value-retention_days')), 120,
          scrollable: list);
      expect(tester.widget<Text>(find.byKey(const ValueKey('policy-value-retention_days'))).data, '30 days');
      expect(tester.widget<Text>(find.byKey(const ValueKey('policy-value-legal_hold'))).data, Strings.policyOn);
      expect(find.text(Strings.orgPoliciesReadOnlyFooter), findsOneWidget);
    });
  });

  group('Access requests', () {
    testWidgets('another admin\'s pending request offers approve / reject; mine waits', (tester) async {
      _repo.requests = [_req('r1', requester: 'u2'), _req('r2', requester: 'me')];
      await _open(tester, const AccessRequestsScreen());
      expect(find.byKey(const ValueKey('access-request-approve-r1')), findsOneWidget);
      expect(find.byKey(const ValueKey('access-request-approve-r2')), findsNothing);
      expect(find.text(Strings.accessRequestAwaitingOther), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('access-request-approve-r1')));
      await tester.pumpAndSettle();
      expect(find.text(Strings.accessRequestApproveTitle), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('access-request-approve-confirm')));
      await tester.pumpAndSettle();
      expect(_repo.decisions, ['approve:r1']);
      expect(find.text(Strings.accessRequestStatusApproved), findsOneWidget);
      expect(find.byKey(const ValueKey('access-request-approve-r1')), findsNothing);
    });

    testWidgets('my approved request shows the audited-view button while the window is open', (tester) async {
      final future = DateTime.now().toUtc().add(const Duration(hours: 20)).toIso8601String();
      final past = DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String();
      _repo.requests = [
        _req('mine', requester: 'me', status: 'approved', expires: future),
        _req('old', requester: 'me', status: 'approved', expires: past),
        _req('theirs', requester: 'u2', status: 'approved', expires: future),
      ];
      await _open(tester, const AccessRequestsScreen());
      expect(find.byKey(const ValueKey('access-request-open-mine')), findsOneWidget);
      expect(find.byKey(const ValueKey('access-request-open-old')), findsNothing);
      expect(find.byKey(const ValueKey('access-request-open-theirs')), findsNothing);
    });

    testWidgets('create sheet: reason required, keyboard drops on tap outside, sends both fields',
        (tester) async {
      await _open(tester, const AccessRequestsScreen());
      expect(find.text(Strings.accessRequestsEmpty), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('access-request-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('access-request-sheet')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('access-request-submit')));
      await tester.pumpAndSettle();
      expect(find.text(Strings.accessRequestReasonRequired), findsOneWidget);
      expect(find.text(Strings.accessRequestConversationRequired), findsOneWidget);
      expect(_repo.created, isNull);

      final conv = find.descendant(
          of: find.byKey(const ValueKey('access-request-conversation')), matching: find.byType(TextField));
      final reason = find.descendant(
          of: find.byKey(const ValueKey('access-request-reason')), matching: find.byType(TextField));
      await tester.tap(conv);
      await tester.enterText(conv, 'c1');
      await tester.tap(reason);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.enterText(reason, 'Patient complaint review');
      // Keyboard rule: tapping the sheet title drops the keypad.
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('access-request-sheet')),
          matching: find.text(Strings.accessRequestNew)));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.tap(find.byKey(const ValueKey('access-request-submit')));
      await tester.pumpAndSettle();
      expect(_repo.created, {'conversation_id': 'c1', 'reason': 'Patient complaint review'});
      expect(find.byKey(const ValueKey('access-request-sheet')), findsNothing);
      expect(find.text(Strings.accessRequestCreated), findsOneWidget);
      expect(find.byKey(const ValueKey('access-request-new')), findsOneWidget);
    });
  });

  group('Reports', () {
    testWidgets('chips filter by status; tapping a card changes its status', (tester) async {
      _repo.reportRows = [_report('a', 'open'), _report('b', 'dismissed', reason: 'phi_misuse')];
      await _open(tester, const OrgReportsScreen());
      expect(find.byKey(const ValueKey('report-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-b')), findsOneWidget);
      expect(find.text('details a'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reports-filter-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-b')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('report-a')));
      await tester.pumpAndSettle();
      expect(find.text(Strings.orgReportChangeStatus), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('report-opt-status-reviewing')));
      await tester.pumpAndSettle();
      expect(_repo.statusChanges, [('a', ReportStatus.reviewing)]);
      // Now filtered out of "Open".
      expect(find.byKey(const ValueKey('report-a')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('reports-filter-reviewing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-a')), findsOneWidget);
      expect(tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('report-status-a')),
        matching: find.byType(Text),
      )).data, Strings.orgReportStatusReviewing);
    });

    testWidgets('a refused status change rolls back with a toast', (tester) async {
      _repo.reportRows = [_report('a', 'open')];
      await _open(tester, const OrgReportsScreen());
      _repo.fail = true;
      await tester.tap(find.byKey(const ValueKey('report-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('report-opt-status-actioned')));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('report-status-a')),
        matching: find.byType(Text),
      )).data, Strings.orgReportStatusOpen);
    });
  });
}
