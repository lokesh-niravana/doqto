import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/api/token_storage.dart';
import '../../data/api/websocket_client.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/services/auth_broker.dart';
import '../../data/services/firebase_auth_broker.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/repositories/groups_repository.dart';
import '../../data/repositories/network_repository.dart';
import '../../data/repositories/org_repository.dart';
import '../../data/repositories/user_repository.dart';
import '../../data/services/chat_cache.dart';
import '../../data/services/groups_cache.dart';
import '../../data/services/network_cache.dart';
import '../../data/services/npi_lookup.dart';
import '../../data/services/outbox.dart';
import '../../data/services/push_token_provider.dart';

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(tokens: ref.watch(tokenStorageProvider)),
);

/// Firebase sign-in, behind an interface so tests never need a Firebase
/// binding. Overridden with [FakeAuthBroker] in widget tests.
final authBrokerProvider = Provider<AuthBroker>((ref) => FirebaseAuthBroker());

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(apiClientProvider), ref.watch(tokenStorageProvider)),
);

final orgRepositoryProvider = Provider<OrgRepository>(
  (ref) => OrgRepository(ref.watch(apiClientProvider)),
);

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => ChatRepository(ref.watch(apiClientProvider)),
);

final userRepositoryProvider = Provider<UserRepository>(
  (ref) => UserRepository(ref.watch(apiClientProvider)),
);

final groupsRepositoryProvider = Provider<GroupsRepository>(
  (ref) => GroupsRepository(ref.watch(apiClientProvider)),
);

final networkRepositoryProvider = Provider<NetworkRepository>(
  (ref) => NetworkRepository(ref.watch(apiClientProvider)),
);

final websocketClientProvider = Provider<WebsocketClient>((ref) {
  final ws = WebsocketClient();
  ref.onDispose(ws.dispose);
  return ws;
});

/// Socket lifecycle as a watchable value — drives the "Connecting…" banner.
final wsConnStateProvider = StreamProvider<WsConnState>(
  (ref) => ref.watch(websocketClientProvider).states,
);

final outboxProvider = Provider<Outbox>((ref) => Outbox());

final outboxMediaStoreProvider =
    Provider<OutboxMediaStore>((ref) => OutboxMediaStore());

final pushTokenProviderProvider =
    Provider<PushTokenProvider>((ref) => FirebasePushTokenProvider());

final chatCacheProvider = Provider<ChatCache>((ref) => ChatCache());

/// Public CMS registry prefill. Overridden with a fake in widget tests.
final npiLookupProvider = Provider<NpiLookup>((ref) => NpiLookup());

final networkCacheProvider = Provider<NetworkCache>((ref) => NetworkCache());

final groupsCacheProvider = Provider<GroupsCache>((ref) => GroupsCache());
