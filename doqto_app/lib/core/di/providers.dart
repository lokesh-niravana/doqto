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
import '../../data/services/app_badge.dart';
import '../../data/services/app_clipboard.dart';
import '../../data/services/chat_cache.dart';
import '../../data/services/chat_document_store.dart';
import '../../data/services/chat_media_cache.dart';
import '../../data/services/document_viewer.dart';
import '../../data/services/groups_cache.dart';
import '../../data/services/network_cache.dart';
import '../../data/services/npi_lookup.dart';
import '../../data/services/outbox.dart';
import '../../data/services/push_token_provider.dart';
import '../../data/services/url_opener.dart';

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(tokens: ref.watch(tokenStorageProvider)),
);

/// Firebase sign-in, behind an interface so tests never need a Firebase
/// binding. Overridden with [FakeAuthBroker] in widget tests.
final authBrokerProvider = Provider<AuthBroker>((ref) => FirebaseAuthBroker());

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    ref.watch(apiClientProvider),
    ref.watch(tokenStorageProvider),
  ),
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

final outboxMediaStoreProvider = Provider<OutboxMediaStore>(
  (ref) => OutboxMediaStore(),
);

final pushTokenProviderProvider = Provider<PushTokenProvider>(
  (ref) => FirebasePushTokenProvider(),
);

final chatCacheProvider = Provider<ChatCache>((ref) => ChatCache());

/// App-icon badge (batch 3). Overridden in tests.
final appBadgeProvider = Provider<AppBadge>((ref) => AppBadge());

/// Chat images on the phone, keyed by message id: downloaded once, wiped on
/// sign-out. Overridden with a temp-dir backend in tests.
final chatDocumentStoreProvider = Provider<ChatDocumentStore>(
  (ref) => ChatDocumentStore(),
);

final documentViewerProvider = Provider<DocumentViewer>(
  (ref) => const NativeDocumentViewer(),
);

final chatMediaCacheProvider = Provider<ChatMediaCache>(
  (ref) => ChatMediaCache(CacheManagerMediaBackend()),
);

/// Public CMS registry prefill. Overridden with a fake in widget tests.
final npiLookupProvider = Provider<NpiLookup>((ref) => NpiLookup());

final networkCacheProvider = Provider<NetworkCache>((ref) => NetworkCache());

final groupsCacheProvider = Provider<GroupsCache>((ref) => GroupsCache());

/// Copy-to-clipboard (batch 4): local-only pasteboard on iOS. Faked in tests.
final clipboardProvider = Provider<AppClipboard>((ref) => const SystemClipboard());

final urlOpenerProvider = Provider<UrlOpener>(
  (ref) => const ExternalUrlOpener(),
);
