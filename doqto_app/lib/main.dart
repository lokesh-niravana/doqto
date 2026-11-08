import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
import 'data/services/settings_store.dart';
import 'l10n/app_localizations.dart';
import 'state/chat_state.dart';
import 'state/notification_state.dart';
import 'state/auth_state.dart';
import 'state/presence_state.dart';
import 'state/realtime_state.dart';
import 'state/settings_services.dart';
import 'state/settings_state.dart';
import 'ui/widgets/app_lock_gate.dart';
import 'ui/widgets/force_update_gate.dart';

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
  // Emulators and sideloaded APKs fail Play Integrity, so local builds can opt
  // out of app verification. With it on, ONLY Firebase's fictional test
  // numbers (e.g. the demo login) work; real numbers fail with "missing a valid
  // app identifier". Release builds ignore it.
  if (!kReleaseMode &&
      const bool.fromEnvironment('FIREBASE_TEST_NUMBERS')) {
    await FirebaseAuth.instance
        .setSettings(appVerificationDisabledForTesting: true);
  }
  // Real numbers on an emulator: skip Play Integrity (it never vouches for a
  // sideloaded APK) and go straight to the reCAPTCHA check.
  if (!kReleaseMode && const bool.fromEnvironment('FIREBASE_FORCE_RECAPTCHA')) {
    await FirebaseAuth.instance.setSettings(forceRecaptchaFlow: true);
  }
  FirebaseMessaging.onBackgroundMessage(_onBackgroundPush);
  await Hive.initFlutter();
  // H1: boxes hold PHI (message text, transcripts, cached history) — AES-256
  // encrypted with a key kept in the platform keychain/keystore.
  final cipher = HiveAesCipher(await BoxKeyStorage().getOrCreateKey());
  await _openEncryptedBox(Outbox.boxName, cipher); // durable unsent messages
  await _openEncryptedBox(ChatCache.boxName, cipher); // offline read cache
  await _openEncryptedBox(NetworkCache.boxName, cipher); // offline connections
  await _openEncryptedBox(GroupsCache.boxName, cipher); // offline my-groups
  // Device-local settings (theme, app lock, language…) — encrypted like the
  // rest, but NOT wiped on sign-out (settings_store.dart).
  await _openEncryptedBox(SettingsStore.boxName, cipher);
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

  /// Theme = System follows the OS; the OS does not rebuild us on its own.
  @override
  void didChangePlatformBrightness() => setState(() {});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Resume = prove the socket is alive or redial now (skipping any pending
    // backoff). The WsConnState.connected stream then drives conversation
    // refresh, message catch-up, and outbox drain. Nothing on pause — the
    // server's idle deadline reaps dead sockets, so brief app-switches survive.
    ref.read(websocketClientProvider).onAppResumed();
    // A phone that missed push registration heals on the next resume.
    ref.read(authProvider.notifier).onAppResumed();
    // Presence frames missed while locked: refetch everyone on screen.
    ref.read(presenceProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    // Open the realtime socket for any signed-in doctor (org or not); close
    // it on sign-out.
    ref.watch(realtimeSessionProvider);
    // Activate WS → banner notifications for incoming messages.
    ref.watch(notificationListenerProvider);
    // Resend queued messages on start + every reconnect.
    ref.watch(outboxDrainerProvider);
    // App-icon badge follows the unread total; cleared on sign-out.
    ref.watch(appBadgeSyncProvider);
    // Batch 6 root listeners (screenshot audit, channels, FLAG_SECURE…).
    ref.watch(settingsServicesProvider);

    // Appearance (batch 6): swap the static token palette FIRST so every
    // AppColors.x read during this build agrees with the ThemeData below.
    final settings = ref.watch(appSettingsProvider);
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    applyPalette(settings, platformBrightness);
    final light = AppTheme.light();
    final dark = AppTheme.dark();
    // Building both ThemeDatas restores the previous palette; set ours again.
    applyPalette(settings, platformBrightness);

    return MaterialApp.router(
      title: Strings.appName,
      debugShowCheckedModeBanner: false,
      theme: light,
      darkTheme: dark,
      themeMode: settings.themeMode,
      locale: settings.locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
      builder: (context, child) {
        // Font size S/M/L multiplies the platform's Dynamic Type scale rather
        // than replacing it.
        final mq = MediaQuery.of(context);
        final systemScale = mq.textScaler.scale(1.0);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(systemScale * settings.fontSize.factor),
          ),
          child: ForceUpdateGate(
            child: AppLockGate(child: child ?? const SizedBox.shrink()),
          ),
        );
      },
    );
  }
}
