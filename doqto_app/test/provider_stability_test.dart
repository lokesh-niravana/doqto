import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/services/network_usage.dart';

class _Tokens extends TokenStorage {
  @override
  Future<String?> get accessToken async => 'a1';
  @override
  Future<String?> get refreshToken async => 'r1';
  @override
  Future<void> clear() async {}
  @override
  Future<void> saveTokens({required String access, required String refresh}) async {}
}

/// The network-usage counter notifies on every byte. The API client (and so
/// every repository, the outbox drainer and the socket session) must NOT be
/// rebuilt by those ticks — a rebuilt drainer re-sent in-flight outbox
/// entries, which the server saw as duplicate client_ids.
void main() {
  test('network usage ticks do not rebuild the API client or repositories', () {
    final usage = NetworkUsage();
    final container = ProviderContainer(overrides: [
      tokenStorageProvider.overrideWithValue(_Tokens()),
      networkUsageProvider.overrideWith((_) => usage),
    ]);
    addTearDown(container.dispose);

    final api = container.read(apiClientProvider);
    final chat = container.read(chatRepositoryProvider);
    final settings = container.read(settingsRepositoryProvider);

    usage.addSent(10);
    usage.addReceived(20);

    expect(identical(container.read(apiClientProvider), api), isTrue);
    expect(identical(container.read(chatRepositoryProvider), chat), isTrue);
    expect(identical(container.read(settingsRepositoryProvider), settings), isTrue);
  });
}
