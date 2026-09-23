import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/billing.dart';
import 'package:doqto_app/data/repositories/billing_repository.dart';
import 'package:doqto_app/data/services/url_opener.dart';
import 'package:doqto_app/ui/screens/payments/payments_screen.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

class _FakeBilling extends BillingRepository {
  _FakeBilling() : super(ApiClient());
  final List<String> checkouts = [];
  Object? checkoutError;
  Billing value = const Billing(
    entitled: false,
    reason: 'expired',
    monthlyCents: 899,
    yearlyCents: 8000,
  );

  @override
  Future<Billing> status() async => value;

  @override
  Future<String> checkoutUrl(String plan) async {
    if (checkoutError != null) throw checkoutError!;
    checkouts.add(plan);
    // Stripe's webhook has landed by the time the doctor is back, so the
    // post-checkout poll ends on its first refresh instead of leaving timers.
    value = const Billing(
      entitled: true,
      reason: 'subscribed',
      monthlyCents: 899,
      yearlyCents: 8000,
    );
    return 'https://checkout.stripe.test/$plan';
  }

  @override
  Future<String> portalUrl() async => 'https://portal.stripe.test/s';
}

void main() {
  late _FakeBilling billing;
  late FakeUrlOpener opener;

  setUp(() {
    billing = _FakeBilling();
    opener = FakeUrlOpener();
  });

  Future<void> pump(WidgetTester tester, {PaymentsMode mode = PaymentsMode.paywall}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        billingRepositoryProvider.overrideWithValue(billing),
        urlOpenerProvider.overrideWithValue(opener),
      ],
      child: MaterialApp(home: PaymentsScreen(mode: mode)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the paywall explains itself and offers both plans', (tester) async {
    await pump(tester);

    expect(find.text(Strings.paywallTitle), findsOneWidget);
    // Nothing is held hostage, and the screen says so.
    expect(find.textContaining('still readable'), findsOneWidget);
    expect(find.text(Strings.planMonthly), findsOneWidget);
    expect(find.text(Strings.planYearly), findsOneWidget);
  });

  testWidgets('prices and the saving come from the server', (tester) async {
    billing.value = const Billing(
      entitled: false,
      reason: 'expired',
      monthlyCents: 1000,
      yearlyCents: 6000,
    );
    await pump(tester);

    expect(find.text('\$10.00/mo'), findsOneWidget);
    expect(find.text('\$60/yr'), findsOneWidget);
    expect(find.textContaining('50%'), findsOneWidget);
  });

  testWidgets('Subscribe opens Stripe in the browser for the chosen plan',
      (tester) async {
    await pump(tester);

    await tester.tap(find.widgetWithText(AppButton, Strings.planSubscribe).first);
    await tester.pumpAndSettle();

    // Yearly is preselected.
    expect(billing.checkouts, ['yearly']);
    expect(opener.opened, ['https://checkout.stripe.test/yearly']);
  });

  testWidgets('a checkout failure is explained, not swallowed', (tester) async {
    billing.checkoutError = ApiException('billing_unavailable', status: 503);
    await pump(tester);

    await tester.tap(find.widgetWithText(AppButton, Strings.planSubscribe).first);
    await tester.pumpAndSettle();

    expect(find.textContaining('temporarily unavailable'), findsOneWidget);
    expect(opener.opened, isEmpty);
  });

  testWidgets('the paywall has no way to skip', (tester) async {
    await pump(tester);

    expect(find.text(Strings.planSkip), findsNothing);
  });

  testWidgets('onboarding keeps the free trial and the skip', (tester) async {
    await pump(tester, mode: PaymentsMode.onboarding);

    // AppButton paints its label twice (an invisible copy holds the width),
    // so count buttons by label, not Text widgets.
    expect(
      find.byWidgetPredicate(
          (w) => w is AppButton && w.label == Strings.planStartTrial),
      findsOneWidget,
    );
    expect(find.text(Strings.planSkip), findsOneWidget);
  });
}
