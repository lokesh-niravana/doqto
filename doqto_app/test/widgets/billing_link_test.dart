import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/billing.dart';
import 'package:doqto_app/data/repositories/billing_repository.dart';
import 'package:doqto_app/state/auth_state.dart';

// Stripe sends the browser back to `doqto:///billing`. There is no page
// there: the resume hook re-checks billing, and the link just lands in the app.

class _Stage extends AuthNotifier {
  _Stage(this.stage);
  final AuthStage stage;
  @override
  AuthState build() => AuthState(stage, null);
}

class _Billing extends BillingRepository {
  _Billing() : super(ApiClient());
  @override
  Future<Billing> status() async => const Billing(
        entitled: false,
        reason: 'expired',
        monthlyCents: 899,
        yearlyCents: 8000,
      );
}

Future<String> _land(WidgetTester tester, AuthStage stage) async {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(() => _Stage(stage)),
      billingRepositoryProvider.overrideWithValue(_Billing()),
    ],
  );
  addTearDown(container.dispose);
  final router = container.read(routerProvider);
  router.go('/billing');
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pump();
  final path = router.routerDelegate.currentConfiguration.uri.path;
  // Tear the landing screen down and let its entrance timers run out.
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
  return path;
}

void main() {
  testWidgets('the Stripe return link lands a signed-in doctor on chats',
      (tester) async {
    expect(await _land(tester, AuthStage.signedIn), AppRoutes.chats);
  });

  testWidgets('the Stripe return link keeps an unpaid doctor on the paywall',
      (tester) async {
    expect(await _land(tester, AuthStage.needsSubscription), AppRoutes.paywall);
  });
}
