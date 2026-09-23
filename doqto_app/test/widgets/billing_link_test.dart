import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/billing.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/repositories/billing_repository.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/network_state.dart';

// Stripe sends the browser back to `doqto:///billing`. There is no page
// there: the resume hook re-checks billing, and the link just lands in the app.

class _Stage extends AuthNotifier {
  _Stage(this.stage, {this.readOnly = false});
  final AuthStage stage;
  final bool readOnly;
  @override
  AuthState build() => AuthState(stage, null, readOnly: readOnly);
  void set(AuthState next) => state = next;
}

/// Empty lists, so the chats screen and the tab bar never touch IO.
class _FakeConvs extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _FakeInvites extends InvitationsNotifier {
  @override
  Future<List<Invitation>> build() async => const [];
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

Future<(ProviderContainer, GoRouter)> _open(
  WidgetTester tester,
  AuthStage stage, {
  String path = '/billing',
  bool readOnly = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(() => _Stage(stage, readOnly: readOnly)),
      billingRepositoryProvider.overrideWithValue(_Billing()),
      conversationsProvider.overrideWith(_FakeConvs.new),
      invitationsProvider.overrideWith(_FakeInvites.new),
    ],
  );
  addTearDown(container.dispose);
  final router = container.read(routerProvider);
  router.go(path);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pump();
  return (container, router);
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

/// Tear the landing screen down and let its entrance timers run out.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

Future<String> _land(WidgetTester tester, AuthStage stage,
    {String path = '/billing', bool readOnly = false}) async {
  final (_, router) = await _open(tester, stage, path: path, readOnly: readOnly);
  final landed = _path(router);
  await _close(tester);
  return landed;
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

  testWidgets('an unpaid doctor cannot reach chats without choosing to read',
      (tester) async {
    expect(
      await _land(tester, AuthStage.needsSubscription, path: AppRoutes.chats),
      AppRoutes.paywall,
    );
  });

  testWidgets('a read-only doctor can open chats and settings', (tester) async {
    for (final path in [AppRoutes.chats, AppRoutes.settings]) {
      expect(
        await _land(tester, AuthStage.needsSubscription,
            path: path, readOnly: true),
        path,
      );
    }
  });

  testWidgets('read-only never reopens onboarding', (tester) async {
    expect(
      await _land(tester, AuthStage.needsSubscription,
          path: AppRoutes.payments, readOnly: true),
      AppRoutes.paywall,
    );
  });

  testWidgets('"Read my messages" on the paywall opens chats', (tester) async {
    final (container, router) = await _open(tester, AuthStage.needsSubscription);
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.text(Strings.paywallReadMessages));
    await tester.pump();
    await tester.pump();

    expect(container.read(authProvider).readOnly, isTrue);
    expect(_path(router), AppRoutes.chats);
    await _close(tester);
  });

  testWidgets('a 402 while reading sends the doctor back to the paywall',
      (tester) async {
    final (container, router) = await _open(tester, AuthStage.needsSubscription,
        path: AppRoutes.chats, readOnly: true);
    expect(_path(router), AppRoutes.chats);

    // What onPaymentRequired does to the state.
    (container.read(authProvider.notifier) as _Stage)
        .set(const AuthState(AuthStage.needsSubscription, null));
    await tester.pump();
    await tester.pump();

    expect(_path(router), AppRoutes.paywall);
    await _close(tester);
  });
}
