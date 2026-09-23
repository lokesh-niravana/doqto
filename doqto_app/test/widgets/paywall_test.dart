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
import 'package:doqto_app/ui/screens/settings/settings_screen.dart';
import 'package:doqto_app/ui/widgets/app_pressable.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

class _FakeBilling extends BillingRepository {
  _FakeBilling() : super(ApiClient());
  final List<String> checkouts = [];
  int portals = 0;
  Object? checkoutError;
  Billing value = const Billing(
    entitled: false,
    reason: 'expired',
    monthlyCents: 899,
    yearlyCents: 8000,
  );

  int statusCalls = 0;
  /// When set, checkout leaves the doctor unpaid (the webhook hasn't landed).
  bool staysUnpaid = false;

  @override
  Future<Billing> status() async {
    statusCalls++;
    return value;
  }

  @override
  Future<String> checkoutUrl(String plan) async {
    if (checkoutError != null) throw checkoutError!;
    checkouts.add(plan);
    if (staysUnpaid) return 'https://checkout.stripe.test/$plan';
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
  Future<String> portalUrl() async {
    portals++;
    // The new card took and the retried invoice paid.
    value = const Billing(
      entitled: true,
      reason: 'subscribed',
      status: 'active',
      monthlyCents: 899,
      yearlyCents: 8000,
    );
    return 'https://portal.stripe.test/s';
  }
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

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        billingRepositoryProvider.overrideWithValue(billing),
        urlOpenerProvider.overrideWithValue(opener),
      ],
      child: const MaterialApp(home: SettingsScreen()),
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

  testWidgets('a browser that will not open is explained, and nothing polls',
      (tester) async {
    opener.result = false;
    await pump(tester);
    final before = billing.statusCalls;

    await tester.tap(find.widgetWithText(AppButton, Strings.planSubscribe).first);
    await tester.pumpAndSettle();

    expect(find.text(Strings.checkoutOpenFailed), findsOneWidget);
    expect(billing.statusCalls, before);
  });

  testWidgets('an unexpected checkout error is shown, not thrown',
      (tester) async {
    billing.checkoutError = StateError('platform said no');
    await pump(tester);

    await tester.tap(find.widgetWithText(AppButton, Strings.planSubscribe).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
  });

  testWidgets('"I have already paid" says so when the payment has not landed',
      (tester) async {
    await pump(tester);

    await tester.tap(find.text(Strings.paywallPaid));
    // Sign out is the one way off the paywall; it never waits on the poll.
    await tester.pump();
    final signOut = find.ancestor(
      of: find.text(Strings.paywallSignOut),
      matching: find.byType(AppPressable),
    );
    expect(tester.widget<AppPressable>(signOut).onTap, isNotNull);

    await tester.pumpAndSettle();
    expect(find.text(Strings.paywallNotPaidYet), findsOneWidget);
  });

  testWidgets('settings shows the trial countdown', (tester) async {
    billing.value = Billing(
      entitled: true,
      reason: 'trial',
      monthlyCents: 899,
      yearlyCents: 8000,
      trialEndsAt: DateTime.now().toUtc().add(const Duration(days: 3, hours: 2)),
    );
    await pumpSettings(tester);

    expect(find.text(Strings.subscriptionRow), findsOneWidget);
    expect(find.text(Strings.trialDaysLeft(4)), findsOneWidget);
  });

  testWidgets('settings opens the Stripe portal for a subscriber',
      (tester) async {
    billing.value = const Billing(
      entitled: true,
      reason: 'subscribed',
      status: 'active',
      plan: 'yearly',
      monthlyCents: 899,
      yearlyCents: 8000,
    );
    await pumpSettings(tester);

    await tester.tap(find.text(Strings.subscriptionRow));
    await tester.pumpAndSettle();

    expect(opener.opened, ['https://portal.stripe.test/s']);
  });

  testWidgets('settings flags a payment problem during grace', (tester) async {
    billing.value = const Billing(
      entitled: true,
      reason: 'grace',
      status: 'past_due',
      monthlyCents: 899,
      yearlyCents: 8000,
    );
    await pumpSettings(tester);

    expect(find.text(Strings.subscriptionGrace), findsOneWidget);
  });

  testWidgets('settings sends a trial doctor to checkout, not the portal',
      (tester) async {
    billing.value = Billing(
      entitled: true,
      reason: 'trial',
      monthlyCents: 899,
      yearlyCents: 8000,
      trialEndsAt: DateTime.now().toUtc().add(const Duration(days: 5)),
    );
    await pumpSettings(tester);

    await tester.tap(find.text(Strings.subscriptionRow));
    await tester.pumpAndSettle();

    expect(billing.checkouts, ['yearly']);
    expect(opener.opened, ['https://checkout.stripe.test/yearly']);
  });

  testWidgets('settings never sends a staff account to checkout',
      (tester) async {
    billing.value = const Billing(
      entitled: true,
      reason: 'staff',
      monthlyCents: 899,
      yearlyCents: 8000,
    );
    await pumpSettings(tester);

    expect(find.text(Strings.subscriptionStaff), findsOneWidget);
    await tester.tap(find.text(Strings.subscriptionRow));
    await tester.pumpAndSettle();

    expect(billing.checkouts, isEmpty);
    expect(opener.opened, isEmpty);
  });

  testWidgets('a lapsed subscriber can fix their card from the paywall',
      (tester) async {
    billing.value = const Billing(
      entitled: false,
      reason: 'expired',
      status: 'past_due',
      monthlyCents: 899,
      yearlyCents: 8000,
    );
    await pump(tester);
    final before = billing.statusCalls;
    // Not "your trial has ended": it's the card, and the copy says so.
    expect(find.text(Strings.paywallCardBody), findsOneWidget);
    expect(find.text(Strings.paywallBody), findsNothing);

    await tester.tap(find.widgetWithText(AppButton, Strings.paywallUpdatePayment).first);
    await tester.pumpAndSettle();

    expect(opener.opened, ['https://portal.stripe.test/s']);
    expect(billing.checkouts, isEmpty);
    // Polls like Subscribe does, so a fixed card lifts the paywall.
    expect(billing.statusCalls, greaterThan(before));
  });

  testWidgets('a doctor who never subscribed has no card to update',
      (tester) async {
    await pump(tester);

    expect(find.text(Strings.paywallUpdatePayment), findsNothing);
    expect(find.text(Strings.paywallBody), findsOneWidget);
  });

  testWidgets('already subscribed at checkout opens the portal instead',
      (tester) async {
    // The mirror hadn't caught up, but Stripe has a subscription: a second
    // checkout would be refused, and the portal is where it gets fixed.
    billing.checkoutError = ApiException('already_subscribed', status: 409);
    await pump(tester);

    await tester.tap(find.widgetWithText(AppButton, Strings.planSubscribe).first);
    await tester.pumpAndSettle();

    expect(opener.opened, ['https://portal.stripe.test/s']);
    expect(find.textContaining('already have a subscription'), findsNothing);
  });

  testWidgets('settings shows the plan for a doctor who paid during the trial',
      (tester) async {
    billing.value = Billing(
      entitled: true,
      reason: 'trial',
      status: 'active',
      plan: 'monthly',
      monthlyCents: 899,
      yearlyCents: 8000,
      trialEndsAt: DateTime.now().toUtc().add(const Duration(days: 5)),
    );
    await pumpSettings(tester);

    expect(find.text(Strings.planMonthly), findsOneWidget);
    expect(find.textContaining('Trial:'), findsNothing);
  });
}
