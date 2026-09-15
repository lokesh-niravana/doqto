import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/repositories/org_repository.dart';
import 'package:doqto_app/data/services/auth_broker.dart';
import 'package:doqto_app/state/auth_state.dart';

// Firebase brokers every sign-in — phone, Google, Facebook, Apple. Whichever
// button the user taps, the app ends up holding one Firebase ID token and
// exchanges it for a Doqto token pair. These tests pin that convergence: the
// notifier must not care which provider produced the token.

User _user({String fullName = 'Dr Test', String npi = '1851408082'}) =>
    User.fromJson({
      'id': 'u1',
      'phone': '+15555550100',
      'full_name': fullName,
      'npi_number': npi,
      'role': 'doctor',
      'created_at': DateTime.now().toIso8601String(),
    });

class _Auth extends AuthRepository {
  _Auth({this.registered = true}) : super(ApiClient(), TokenStorage());
  final bool registered;
  final List<String> exchanged = [];

  @override
  Future<TokenPair> signInWithFirebase(String idToken) async {
    exchanged.add(idToken);
    return TokenPair('access', 'refresh', registered);
  }

  @override
  Future<User> me() async =>
      registered ? _user() : _user(fullName: '', npi: 'PENDING01');
}

/// A registered user's stage depends on their orgs, which would otherwise hit
/// the real ApiClient (and secure storage, which has no binding in tests).
class _Orgs extends OrgRepository {
  _Orgs() : super(ApiClient());
  @override
  Future<List<Organization>> listMine() async => [];
}

void main() {
  test('a Google token is exchanged for a Doqto session', () async {
    final auth = _Auth(registered: true);
    final c = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      authBrokerProvider.overrideWithValue(FakeAuthBroker(idToken: 'google-tok')),
      orgRepositoryProvider.overrideWithValue(_Orgs()),
    ]);
    addTearDown(c.dispose);

    await c.read(authProvider.notifier).signInWith(SocialProvider.google);

    expect(auth.exchanged, ['google-tok']);
  });

  test('an unregistered user is sent to Your Details', () async {
    final c = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(_Auth(registered: false)),
      authBrokerProvider.overrideWithValue(FakeAuthBroker(idToken: 'tok')),
    ]);
    addTearDown(c.dispose);

    await c.read(authProvider.notifier).signInWith(SocialProvider.google);

    expect(c.read(authProvider).stage, AuthStage.needsRegistration);
  });

  test('a cancelled provider sheet is not an error and changes nothing',
      () async {
    final auth = _Auth();
    final c = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      authBrokerProvider.overrideWithValue(FakeAuthBroker(idToken: null)),
      orgRepositoryProvider.overrideWithValue(_Orgs()),
    ]);
    addTearDown(c.dispose);

    // Dismissing the Google sheet returns null. It must not throw, and it must
    // not leave the user half-signed-in.
    await c.read(authProvider.notifier).signInWith(SocialProvider.google);

    expect(auth.exchanged, isEmpty);
    expect(c.read(authProvider).stage, AuthStage.unknown);
  });

  test('phone sign-in exchanges the token the SMS code produced', () async {
    final auth = _Auth();
    final broker = FakeAuthBroker(idToken: 'phone-tok');
    final c = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      authBrokerProvider.overrideWithValue(broker),
      orgRepositoryProvider.overrideWithValue(_Orgs()),
    ]);
    addTearDown(c.dispose);

    final challenge = await c.read(authBrokerProvider).startPhoneSignIn('+15555550100');
    await c.read(authProvider.notifier).confirmPhoneCode(challenge, '123456');

    expect(broker.startedFor, ['+15555550100']);
    expect(auth.exchanged, ['phone-tok']);
  });
}
