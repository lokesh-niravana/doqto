import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/repositories/user_repository.dart';
import 'package:doqto_app/data/services/auth_broker.dart';
import 'package:doqto_app/data/services/chat_media_cache.dart';
import 'package:doqto_app/data/services/push_token_provider.dart';
import 'package:doqto_app/state/auth_state.dart';

import 'support/fake_media_backend.dart';

// App Store 5.1.1(v): deleting an account that uses Sign in with Apple must
// revoke its Apple tokens. Revoking needs Apple to confirm once more, so the
// order is fixed: revoke first (nothing is lost if the person backs out),
// then delete the Doqto account, then the sign-in identity, then sign out.

class _Auth extends AuthRepository {
  _Auth() : super(ApiClient(), TokenStorage());
  @override
  Future<void> logout() async {}
}

class _Users implements UserRepository {
  _Users(this.log, {this.fail = false});
  final List<String> log;
  final bool fail;

  @override
  Future<void> deleteAccount() async {
    if (fail) throw StateError('server refused');
    log.add('delete-account');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not stubbed');
}

class _Broker extends FakeAuthBroker {
  _Broker(this.log);
  final List<String> log;

  @override
  Future<bool> revokeAppleAccess() async {
    log.add('revoke-apple');
    return super.revokeAppleAccess();
  }

  @override
  Future<void> deleteIdentity() async {
    log.add('delete-identity');
    return super.deleteIdentity();
  }

  @override
  Future<void> signOut() async {
    log.add('sign-out');
    return super.signOut();
  }
}

ProviderContainer _container(_Broker broker, _Users users) {
  final c = ProviderContainer(overrides: [
    authRepositoryProvider.overrideWithValue(_Auth()),
    authBrokerProvider.overrideWithValue(broker),
    userRepositoryProvider.overrideWithValue(users),
    pushTokenProviderProvider.overrideWithValue(StubPushTokenProvider()),
    chatMediaCacheProvider.overrideWithValue(ChatMediaCache(FakeMediaBackend())),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('revokes Apple access, deletes the account, then the identity', () async {
    final log = <String>[];
    final c = _container(_Broker(log), _Users(log));

    final deleted = await c.read(authProvider.notifier).deleteAccount();

    expect(deleted, isTrue);
    expect(log, ['revoke-apple', 'delete-account', 'delete-identity', 'sign-out']);
    expect(c.read(authProvider).stage, AuthStage.signedOut);
  });

  test('backing out of the Apple confirmation deletes nothing', () async {
    final log = <String>[];
    final broker = _Broker(log)..appleRevokeResult = false;
    final c = _container(broker, _Users(log));

    final deleted = await c.read(authProvider.notifier).deleteAccount();

    expect(deleted, isFalse);
    expect(log, ['revoke-apple']);
    expect(c.read(authProvider).stage, isNot(AuthStage.signedOut));
  });

  test('a failed deletion keeps the session so the person can retry', () async {
    final log = <String>[];
    final c = _container(_Broker(log), _Users(log, fail: true));

    await expectLater(
      c.read(authProvider.notifier).deleteAccount(),
      throwsStateError,
    );
    expect(log, ['revoke-apple']);
    expect(c.read(authProvider).stage, isNot(AuthStage.signedOut));
  });
}
