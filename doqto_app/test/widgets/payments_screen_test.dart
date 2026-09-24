import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/api/websocket_client.dart';
import 'package:doqto_app/data/models/billing.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/repositories/billing_repository.dart';
import 'package:doqto_app/data/repositories/org_repository.dart';
import 'package:doqto_app/data/services/push_token_provider.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/billing_state.dart';
import 'package:doqto_app/ui/screens/payments/payments_screen.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

// The plan picker is the last onboarding step: both plans on screen, yearly
// preselected, and the user leaves by starting the trial or skipping. Subscribe
// is covered in paywall_test.dart.

User _user() => User.fromJson({
      'id': 'u1',
      'phone': '+15555550100',
      'full_name': 'Vimal Nanavati',
      'npi_number': '1851408082',
      'role': 'doctor',
      'created_at': DateTime.now().toIso8601String(),
    });

Organization _org(OrgStatus status) => Organization(
      id: 'o1',
      name: 'Bonita Cardiology',
      address: null,
      city: 'Bonita',
      state: 'CA',
      practiceType: null,
      inviteCode: 'BONI·4827',
      status: status,
      reviewNotes: null,
      verifiedAt: null,
      createdAt: DateTime.now(),
      memberCount: 1,
    );

class _FakeOrgRepository extends OrgRepository {
  _FakeOrgRepository(this.orgs) : super(ApiClient());
  final List<Organization> orgs;
  int listMineCalls = 0;

  @override
  Future<List<Organization>> listMine() async {
    listMineCalls++;
    return orgs;
  }
}

/// Signing in with an active org opens a real socket, which never completes in
/// a test — stub it so `completePayment` can finish.
class _FakeWebsocketClient extends WebsocketClient {
  int connects = 0;

  @override
  Future<void> connect({
    required String orgId,
    required Future<String?> Function() tokenProvider,
  }) async {
    connects++;
  }
}

/// A doctor fresh out of registration is in their trial. Leaving the picker
/// re-resolves the stage, which asks billing first; never hit the real API.
class _FakeBillingRepository extends BillingRepository {
  _FakeBillingRepository() : super(ApiClient());

  @override
  Future<Billing> status() async => const Billing(
        entitled: true,
        reason: 'trial',
        monthlyCents: 899,
        yearlyCents: 8000,
      );
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : super(ApiClient(), TokenStorage());

  @override
  Future<User> register({
    required String fullName,
    required String? specialty,
    required String npiNumber,
    String? city,
    String? state,
  }) async =>
      _user();
}

void main() {
  late _FakeOrgRepository orgRepo;
  late _FakeWebsocketClient ws;

  setUp(() {
    orgRepo = _FakeOrgRepository(const []);
    ws = _FakeWebsocketClient();
  });

  /// Pumps the picker with the user parked on [AuthStage.needsPayment], which
  /// is exactly where registration leaves them.
  Future<ProviderContainer> pump(WidgetTester tester, {bool web = true}) async {
    final container = ProviderContainer(overrides: [
      webCheckoutProvider.overrideWithValue(web),
      orgRepositoryProvider.overrideWithValue(orgRepo),
      authRepositoryProvider.overrideWithValue(_FakeAuthRepository()),
      websocketClientProvider.overrideWithValue(ws),
      pushTokenProviderProvider.overrideWithValue(StubPushTokenProvider()),
      billingRepositoryProvider.overrideWithValue(_FakeBillingRepository()),
    ]);
    addTearDown(container.dispose);

    await container.read(authProvider.notifier).completeRegistration(
          fullName: 'Vimal Nanavati',
          npiNumber: '1851408082',
        );
    expect(container.read(authProvider).stage, AuthStage.needsPayment,
        reason: 'registration must hand off to the plan picker');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PaymentsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// Which plan row holds the checked radio.
  String selectedPlan(WidgetTester tester) {
    final row = find
        .ancestor(
          of: find.byIcon(Icons.radio_button_checked),
          matching: find.byType(Row),
        )
        .first;
    for (final name in [Strings.planMonthly, Strings.planYearly]) {
      if (find.descendant(of: row, matching: find.text(name)).evaluate().isNotEmpty) {
        return name;
      }
    }
    return 'none';
  }

  final startTrial = find.byWidgetPredicate(
      (w) => w is AppButton && w.label == Strings.planStartTrial);

  Future<void> leave(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    // Bounded pumps: the button shows an indeterminate spinner while working.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('shows both plans, with yearly selected by default', (tester) async {
    await pump(tester);

    expect(find.text(Strings.planTitle), findsOneWidget);
    expect(find.text(Strings.planMonthly), findsOneWidget);
    // Prices are the server's, formatted by Billing.
    expect(find.text('\$8.99/mo'), findsOneWidget);
    expect(find.text(Strings.planYearly), findsOneWidget);
    expect(find.text('\$80/yr'), findsOneWidget);
    expect(find.text('Save 26% · \$6.67/mo'), findsOneWidget);
    expect(find.text(Strings.planSkip), findsOneWidget);

    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(selectedPlan(tester), Strings.planYearly);
  });

  testWidgets('tapping a plan moves the selection', (tester) async {
    await pump(tester);

    await tester.tap(find.text(Strings.planMonthly));
    await tester.pumpAndSettle();
    expect(selectedPlan(tester), Strings.planMonthly);

    await tester.tap(find.text(Strings.planYearly));
    await tester.pumpAndSettle();
    expect(selectedPlan(tester), Strings.planYearly);

    // Exactly one plan is ever selected.
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_off), findsOneWidget);
  });

  testWidgets('Start trial ends onboarding — no org needed', (tester) async {
    final container = await pump(tester);

    await leave(tester, startTrial);

    expect(orgRepo.listMineCalls, 1);
    expect(container.read(authProvider).stage, AuthStage.signedIn);
    // No org yet, so no socket — joining one later connects it.
    expect(ws.connects, 0);
  });

  testWidgets('Skip for now ends onboarding too', (tester) async {
    final container = await pump(tester);

    await leave(tester, find.text(Strings.planSkip));

    expect(container.read(authProvider).stage, AuthStage.signedIn);
  });

  testWidgets('an existing active org signs the user straight in', (tester) async {
    orgRepo = _FakeOrgRepository([_org(OrgStatus.active)]);
    final container = await pump(tester);

    await leave(tester, startTrial);

    expect(container.read(authProvider).stage, AuthStage.signedIn);
    expect(ws.connects, 1, reason: 'an active org gets the realtime socket');
  });

  testWidgets('an org still under review lands on the pending screen',
      (tester) async {
    orgRepo = _FakeOrgRepository([_org(OrgStatus.pending)]);
    final container = await pump(tester);

    await leave(tester, startTrial);

    expect(container.read(authProvider).stage, AuthStage.pendingVerification);
  });

  testWidgets('without web checkout (Android) only the trial is on offer',
      (tester) async {
    final container = await pump(tester, web: false);

    expect(find.text(Strings.planTrialStarts), findsOneWidget);
    expect(find.text(Strings.planSubscribe), findsNothing);
    expect(find.text(Strings.planMonthly), findsNothing);
    expect(find.text(Strings.planYearly), findsNothing);
    expect(find.textContaining('\$'), findsNothing);

    await leave(tester, startTrial);

    expect(container.read(authProvider).stage, AuthStage.signedIn);
  });
}
