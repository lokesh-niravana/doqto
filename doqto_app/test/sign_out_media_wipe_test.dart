import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/services/auth_broker.dart';
import 'package:doqto_app/data/services/chat_media_cache.dart';
import 'package:doqto_app/data/services/push_token_provider.dart';
import 'package:doqto_app/state/auth_state.dart';

import 'support/fake_media_backend.dart';

// H2: no cached PHI survives the end of a session. Photos kept on the phone
// are PHI, so sign-out (and account deletion, which signs out) must wipe them.

class _Auth extends AuthRepository {
  _Auth() : super(ApiClient(), TokenStorage());
  @override
  Future<void> logout() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('signing out deletes every photo cached on the phone', () async {
    final backend = FakeMediaBackend();
    final cache = ChatMediaCache(backend);
    final c = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(_Auth()),
      authBrokerProvider.overrideWithValue(FakeAuthBroker()),
      pushTokenProviderProvider.overrideWithValue(StubPushTokenProvider()),
      chatMediaCacheProvider.overrideWithValue(cache),
    ]);
    addTearDown(c.dispose);

    final photo = await cache.image('m1', () async => 'https://s3.example/m1');
    expect(photo.existsSync(), isTrue);

    await c.read(authProvider.notifier).signOut();

    expect(backend.clears, 1);
    expect(photo.existsSync(), isFalse);
    expect(cache.peek('m1'), isNull);
    expect(c.read(authProvider).stage, AuthStage.signedOut);
  });
}
