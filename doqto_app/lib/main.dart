import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/constants/app_constants.dart';
import 'core/constants/strings.dart';
import 'core/di/providers.dart';
import 'core/router/app_router.dart';
import 'core/theme.dart';
import 'data/local/box_key_storage.dart';
import 'data/services/chat_cache.dart';
import 'data/services/groups_cache.dart';
import 'data/services/network_cache.dart';
import 'data/services/outbox.dart';
import 'state/auth_state.dart';
import 'state/chat_state.dart';
import 'state/notification_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // M6: fail fast at launch — a release build must never talk cleartext.
  if (kReleaseMode &&
      (!AppConstants.apiBaseUrl.startsWith('https://') ||
          !AppConstants.wsBaseUrl.startsWith('wss://'))) {
    throw StateError(
      'Release builds require https:// API_BASE_URL and wss:// WS_BASE_URL.',
    );
  }
  // Remote push: config comes from GoogleService-Info.plist / google-services.json.
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_onBackgroundPush);
  await Hive.initFlutter();
  // H1: boxes hold PHI (message text, transcripts, cached history) — AES-256
  // encrypted with a key kept in the platform keychain/keystore.
  final cipher = HiveAesCipher(await BoxKeyStorage().getOrCreateKey());
  await _openEncryptedBox(Outbox.boxName, cipher); // durable unsent messages
  await _openEncryptedBox(ChatCache.boxName, cipher); // offline read cache
  await _openEncryptedBox(NetworkCache.boxName, cipher); // offline connections
  await _openEncryptedBox(GroupsCache.boxName, cipher); // offline my-groups
  runApp(const ProviderScope(child: DoqtoApp()));
}

/// Pushes carry a `notification` block, so the OS renders them while the app
/// is backgrounded/killed — nothing to do here. Must be a top-level function.
@pragma('vm:entry-point')
Future<void> _onBackgroundPush(RemoteMessage message) async {}

/// Opens [name] encrypted; a pre-encryption plaintext box (or a corrupt one)
/// fails to open, so delete it and start fresh — the cache refetches and a
/// one-time loss of queued outbox entries is accepted (see remediation plan).
Future<void> _openEncryptedBox(String name, HiveAesCipher cipher) async {
  try {
    await Hive.openBox<dynamic>(name, encryptionCipher: cipher);
  } catch (_) {
    await Hive.deleteBoxFromDisk(name);
    await Hive.openBox<dynamic>(name, encryptionCipher: cipher);
  }
}

class DoqtoApp extends ConsumerStatefulWidget {
  const DoqtoApp({super.key});

  @override
  ConsumerState<DoqtoApp> createState() => _DoqtoAppState();
}

class _DoqtoAppState extends ConsumerState<DoqtoApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Resume = instant reconnect (skipping any pending backoff). The
    // WsConnState.connected stream then drives conversation refresh, message
    // catch-up, and outbox drain. Nothing on pause — the server's idle
    // deadline reaps dead sockets, so brief app-switches survive.
    ref.read(websocketClientProvider).ensureConnected();
    // Stripe Checkout and the portal happen in the browser, so coming back is
    // the only reliable signal the subscription may have changed.
    unawaited(ref.read(authProvider.notifier).refreshBilling());
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    // Activate WS → banner notifications for incoming messages.
    ref.watch(notificationListenerProvider);
    // Resend queued messages on start + every reconnect.
    ref.watch(outboxDrainerProvider);
    return MaterialApp.router(
      title: Strings.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      routerConfig: router,
    );
  }
}
