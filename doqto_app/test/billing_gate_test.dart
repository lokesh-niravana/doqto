import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/models/billing.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/repositories/billing_repository.dart';
import 'package:doqto_app/data/repositories/org_repository.dart';
import 'package:doqto_app/data/services/auth_broker.dart';
import 'package:doqto_app/data/services/push_token_provider.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/billing_state.dart';

// The subscription gate. The server decides; the app only follows — and when
// the server can't be reached, the app lets the doctor in (sending still 402s).

User _user() => User.fromJson({
      'id': 'u1',
      'phone': '+15555550100',
      'full_name': 'Dr Test',
      'npi_number': '1851408082',
      'role': 'doctor',
      'created_at': DateTime.now().toIso8601String(),
    });

class _Auth extends AuthRepository {
  _Auth() : super(ApiClient(), TokenStorage());

  @override
  Future<TokenPair> signInWithFirebase(String idToken) async =>
      TokenPair('access', 'refresh', true);

  @override
  Future<User> me() async => _user();

  @override
  Future<void> logout() async {}
}

class _Orgs extends OrgRepository {
  _Orgs() : super(ApiClient());
  @override
  Future<List<Organization>> listMine() async => [];
}

const _entitled = Billing(
  entitled: true,
  reason: 'trial',
  monthlyCents: 899,
  yearlyCents: 8000,
);
const _expired = Billing(
  entitled: false,
  reason: 'expired',
  monthlyCents: 899,
  yearlyCents: 8000,
);

class _Billing extends BillingRepository {
  _Billing(this.value) : super(ApiClient());
  Billing value;
  Object? error;
  int calls = 0;
  /// When set, the next `status()` waits on it (one-shot).
  Completer<Billing>? hold;

  @override
  Future<Billing> status() async {
    calls++;
    if (hold case final h?) {
      hold = null;
      return h.future;
    }
    if (error != null) throw error!;
    return value;
  }
}

void main() {
  late _Billing billing;

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(_Auth()),
      authBrokerProvider.overrideWithValue(FakeAuthBroker(idToken: 'tok')),
      orgRepositoryProvider.overrideWithValue(_Orgs()),
      billingRepositoryProvider.overrideWithValue(billing),
      pushTokenProviderProvider.overrideWithValue(StubPushTokenProvider()),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> signIn(ProviderContainer c) =>
      c.read(authProvider.notifier).signInWith(SocialProvider.google);

  test('an expired doctor is sent to the paywall', () async {
    billing = _Billing(_expired);
    final c = container();

    await signIn(c);

    expect(c.read(authProvider).stage, AuthStage.needsSubscription);
  });

  test('a failed billing check lets the doctor in', () async {
    billing = _Billing(_entitled)..error = ApiException('boom', status: 500);
    final c = container();

    await signIn(c);

    expect(c.read(authProvider).stage, AuthStage.signedIn);
  });

  test('a lapse noticed later (resume or 402) moves to the paywall', () async {
    billing = _Billing(_entitled);
    final c = container();
    await signIn(c);
    expect(c.read(authProvider).stage, AuthStage.signedIn);

    billing.value = _expired;
    await c.read(authProvider.notifier).refreshBilling();

    expect(c.read(authProvider).stage, AuthStage.needsSubscription);
  });

  test('paying in the browser takes the doctor off the paywall on resume',
      () async {
    billing = _Billing(_expired);
    final c = container();
    await signIn(c);

    billing.value = _entitled;
    await c.read(authProvider.notifier).refreshBilling();

    expect(c.read(authProvider).stage, AuthStage.signedIn);
  });

  test('a 402 from any request moves the doctor to the paywall', () async {
    billing = _Billing(_entitled);
    final c = container();
    await signIn(c);

    billing.value = _expired;
    // What ApiClient does when a request comes back 402.
    c.read(apiClientProvider).onPaymentRequired!();
    await pumpEventQueue();

    expect(c.read(authProvider).stage, AuthStage.needsSubscription);
  });

  test('refreshBilling does nothing before sign-in', () async {
    billing = _Billing(_expired);
    final c = container();

    await c.read(authProvider.notifier).refreshBilling();

    expect(c.read(authProvider).stage, AuthStage.unknown);
  });

  test('signing out forgets the previous doctor\'s billing', () async {
    billing = _Billing(_expired);
    final c = container();
    await signIn(c);
    expect(c.read(billingProvider).value?.entitled, false);

    await c.read(authProvider.notifier).signOut();

    expect(c.read(billingProvider).value, isNull);
  });

  test('signing out during a billing re-check keeps the doctor signed out',
      () async {
    billing = _Billing(_entitled);
    final c = container();
    await signIn(c);

    // A resume re-check is in flight when the doctor taps Sign out.
    final held = Completer<Billing>();
    billing.hold = held;
    final inFlight = c.read(authProvider.notifier).refreshBilling();
    await c.read(authProvider.notifier).signOut();
    held.complete(_expired);
    await inFlight;
    await pumpEventQueue();

    expect(c.read(authProvider).stage, AuthStage.signedOut);
    expect(c.read(authProvider).user, isNull);
    expect(c.read(billingProvider).value, isNull);
  });

  test('a burst of 402s triggers one billing re-check', () async {
    billing = _Billing(_entitled);
    final c = container();
    await signIn(c);
    final before = billing.calls;

    final api = c.read(apiClientProvider);
    for (var i = 0; i < 5; i++) {
      api.onPaymentRequired!();
    }
    await pumpEventQueue();

    expect(billing.calls, before + 1);
  });

  test('reading past the paywall lasts until the next 402', () async {
    billing = _Billing(_expired);
    final c = container();
    await signIn(c);

    c.read(authProvider.notifier).enterReadOnly();
    expect(c.read(authProvider).readOnly, isTrue);

    // A send while read-only: the server says pay first.
    c.read(apiClientProvider).onPaymentRequired!();
    await pumpEventQueue();

    expect(c.read(authProvider).readOnly, isFalse);
    expect(c.read(authProvider).stage, AuthStage.needsSubscription);
  });

  test('read-only is only offered on the paywall', () async {
    billing = _Billing(_entitled);
    final c = container();
    await signIn(c);

    c.read(authProvider.notifier).enterReadOnly();

    expect(c.read(authProvider).readOnly, isFalse);
  });

  test('signing out during "I have already paid" keeps the doctor signed out',
      () async {
    billing = _Billing(_expired);
    final c = container();
    await signIn(c);

    final held = Completer<Billing>();
    billing.hold = held;
    final inFlight = c.read(authProvider.notifier).recheckSubscription();
    await c.read(authProvider.notifier).signOut();
    held.complete(_entitled);
    await inFlight;
    await pumpEventQueue();

    expect(c.read(authProvider).stage, AuthStage.signedOut);
    expect(c.read(authProvider).user, isNull);
  });
}
