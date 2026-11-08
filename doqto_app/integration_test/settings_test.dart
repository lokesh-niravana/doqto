// On-device walk of batch 6 (settings): dark theme → thread screenshot →
// per-chat colour + wallpaper from Chat info → message tone (verified over
// REST as me) → app lock Immediately, inactive→resumed shows the gate →
// linked devices (this device + an "iPad" row; revoke others makes the
// iPad's token 401) → status preset → Spanish → Settings screenshot.
// The app signs in as +1 650-555-0198; ME_OTHER_TOKEN is the iPad session.
//
//   cd doqto_backend && DATABASE_URL=…doqto_b4 REDIS_URL=…/3 \
//     venv/bin/python scripts/settings_device_prep.py
//   flutter test integration_test/settings_test.dart -d <sim> --ignore-timeouts \
//     --dart-define=FIREBASE_TEST_NUMBERS=true --dart-define=FAKE_LOCAL_AUTH=true \
//     --dart-define=API_BASE_URL=http://localhost:8011 \
//     --dart-define=WS_BASE_URL=ws://localhost:8011 \
//     --dart-define=ME_ID=… --dart-define=PEER_ID=… --dart-define=CONV_ID=… \
//     --dart-define=PEER_TOKEN=… --dart-define=ME_OTHER_TOKEN=… \
//     [--dart-define=SHOT_DIR=<folder on this Mac>]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/app_lock_state.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/sessions_state.dart';
import 'package:doqto_app/state/settings_state.dart';

const _me = String.fromEnvironment('ME_ID');
const _peerToken = String.fromEnvironment('PEER_TOKEN');
const _conv = String.fromEnvironment('CONV_ID');
const _meOtherToken = String.fromEnvironment('ME_OTHER_TOKEN');
const _shotDir = String.fromEnvironment('SHOT_DIR');
const _liveTimeout = Duration(seconds: 15);

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/settings_$name.png').writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Pop one route at a time until [key] is on screen (or nothing is left to pop).
Future<void> _popUntil(WidgetTester t, GoRouter router, String what, String key) async {
  for (var i = 0; i < 6 && !_has(find.byKey(ValueKey(key))); i++) {
    if (!router.canPop()) break;
    router.pop();
    await _settle(t, 400);
  }
  await _until(t, what, () => _has(find.byKey(ValueKey(key))));
}

Future<void> _until(WidgetTester t, String what, FutureOr<bool> Function() ready) async {
  final start = DateTime.now();
  while (!await ready()) {
    if (DateTime.now().difference(start) > _liveTimeout) {
      fail('not within $_liveTimeout: $what');
    }
    await t.pump(const Duration(milliseconds: 100));
  }
  // ignore: avoid_print
  print('LIVE  ${DateTime.now().difference(start).inMilliseconds} ms  $what');
}

/// REST as my *other* device (the iPad session the prep script minted).
Future<(int, Object?)> _otherDevice(String method, String path,
        {Map<String, dynamic>? body}) =>
    _restAs(_meOtherToken, method, path, body: body);

Future<(int, Object?)> _restAs(String token, String method, String path,
    {Map<String, dynamic>? body}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('${AppConstants.apiBaseUrl}/api/v1$path'));
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  } finally {
    client.close();
  }
}

bool _has(Finder f) => f.evaluate().isNotEmpty;

/// Scroll [key] into view inside the list keyed [listKey] (or the first
/// scrollable when the list has no key) and tap it.
Future<void> _tapIn(WidgetTester t, String? listKey, String key) async {
  final target = find.byKey(ValueKey(key));
  if (!_has(target)) {
    // Let a route transition finish so the list's Scrollable is mounted.
    await _settle(t, 400);
    final scrollable = listKey == null
        ? find.byType(Scrollable).first
        : find
            .descendant(
                of: find.byKey(ValueKey(listKey)),
                matching: find.byType(Scrollable),
                matchRoot: true)
            .first;
    // Lists keep their offset across pops, so the row may be above or below.
    try {
      await t.scrollUntilVisible(target, 120, scrollable: scrollable, maxScrolls: 30);
    } on StateError {
      await t.scrollUntilVisible(target, -120, scrollable: scrollable, maxScrolls: 30);
    }
  } else {
    await t.ensureVisible(target);
  }
  await _settle(t, 300);
  await t.tap(target);
  await _settle(t, 400);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('settings: dark → chat theme → tone → app lock → devices → status → español',
      (tester) async {
    expect(_me.isNotEmpty && _conv.isNotEmpty && _meOtherToken.isNotEmpty, isTrue,
        reason: 'run scripts/settings_device_prep.py and pass its dart-defines');
    await app.main();
    await _settle(tester, 3000);

    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    final auth = container.read(authProvider.notifier);
    final router = container.read(routerProvider);
    final settings = container.read(appSettingsProvider.notifier);
    final fakeAuth = container.read(localAuthenticatorProvider) as FakeLocalAuthenticator;

    // A clean baseline on this install: light/system, English, lock off.
    await settings.setThemeMode(ThemeMode.system);
    await settings.setLocale(null);
    await settings.setAppLock(false);
    await settings.setChatTheme(null);
    await settings.setWallpaper(null);
    container.read(appLockProvider.notifier).clearLock();

    // The prep script wipes the sessions table. Cached tokens for a dead
    // session 401 with `session_revoked` on the first call and the client
    // signs itself out; a live session is kept (its row is `current`).
    // signOut() itself is not awaited here: FCM token lookups can hang on a
    // simulator and the test would never time out.
    if (container.read(authProvider).stage == AuthStage.signedIn) {
      var stale = false;
      try {
        final rows = await container
            .read(settingsRepositoryProvider)
            .listSessions()
            .timeout(const Duration(seconds: 10));
        // Tokens minted before the sessions table are tolerated by the
        // server (build-44 users stay signed in), so a wiped row does not
        // 401: start over so this run owns a `current` session.
        stale = !rows.any((r) => r.current);
      } catch (e) {
        // ignore: avoid_print
        print('LIVE  sessions lookup failed: $e');
        stale = true;
      }
      if (stale) {
        if (container.read(authProvider).stage == AuthStage.signedIn) {
          unawaited(auth.signOut());
        }
        await _until(tester, 'stale session cleared',
            () => container.read(authProvider).stage != AuthStage.signedIn);
      }
    }
    if (container.read(authProvider).stage != AuthStage.signedIn) {
      final challenge = await auth.startPhoneSignIn('+16505550198');
      await auth.confirmPhoneCode(challenge, '654321');
    }
    await _until(tester, 'signed in', () => container.read(authProvider).stage == AuthStage.signedIn);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester, 1500);

    // A couple of bubbles so the theme walk has something to colour: one
    // from the peer, one from my other device.
    expect((await _restAs(_peerToken, 'POST', '/conversations/$_conv/messages',
            body: {'content': 'Rounds moved to 8:30 — can you cover the 7 am consult?'})).$1,
        anyOf(200, 201));
    expect((await _otherDevice('POST', '/conversations/$_conv/messages',
            body: {'content': 'Yes, I have it. Send the chart when you can.'})).$1,
        anyOf(200, 201));

    // ---- 1. Appearance → Dark; the thread in the dark palette.
    router.push(AppRoutes.settings);
    await _until(tester, 'settings', () => _has(find.byKey(const ValueKey('settings-list'))));
    await _settle(tester, 800);
    await _shot(tester, '01_settings');
    await _tapIn(tester, 'settings-list', 'settings-appearance');
    await _until(tester, 'appearance', () => _has(find.byKey(const ValueKey('appearance-list'))));
    await _tapIn(tester, 'appearance-list', 'appearance-row-theme');
    await _until(tester, 'theme sheet',
        () => _has(find.byKey(const ValueKey('appearance-opt-theme-dark'))));
    await tester.tap(find.byKey(const ValueKey('appearance-opt-theme-dark')));
    await _until(tester, 'dark applied', () => container.read(isDarkProvider));
    await _settle(tester, 800);
    await _shot(tester, '02_appearance_dark');
    router.push(AppRoutes.chat(_conv));
    await _until(tester, 'thread', () => _has(find.byKey(const ValueKey('thread-subtitle'))));
    await _settle(tester, 1500);
    await _shot(tester, '03_thread_dark');

    // ---- 2. Chat info → colour (ocean) and wallpaper (waves) for this chat.
    final chats = container.read(conversationsProvider.notifier);
    router.push(AppRoutes.chatDetails(_conv));
    await _until(tester, 'chat info', () => _has(find.byKey(const ValueKey('details-starred'))));
    await _tapIn(tester, null, 'details-chat-theme');
    await _until(tester, 'theme grid', () => _has(find.byKey(const ValueKey('chat-theme-grid'))));
    await _settle(tester, 600);
    await _shot(tester, '04_chat_theme_picker');
    await _tapIn(tester, null, 'chat-theme-ocean');
    await _until(tester, 'ocean saved on the conversation',
        () => chats.conversation(_conv)?.prefs.theme == 'ocean');
    router.pop();
    await _until(tester, 'chat info again', () => _has(find.byKey(const ValueKey('details-wallpaper'))));
    await _tapIn(tester, null, 'details-wallpaper');
    await _until(tester, 'wallpaper list', () => _has(find.byKey(const ValueKey('wallpaper-list'))));
    await _tapIn(tester, 'wallpaper-list', 'wallpaper-pattern-waves');
    await _until(tester, 'waves saved on the conversation',
        () => chats.conversation(_conv)?.prefs.wallpaper == 'pattern:waves');
    await _settle(tester, 600);
    await _shot(tester, '05_wallpaper_picker');
    router.pop();
    await _settle(tester, 300);
    router.pop();
    await _until(tester, 'thread with theme', () => _has(find.byKey(const ValueKey('thread-subtitle'))));
    await _settle(tester, 1200);
    await _shot(tester, '06_thread_ocean_waves');
    // The server has both (my other device reads the same prefs).
    final (pc, pj) = await _otherDevice('GET', '/conversations');
    expect(pc, 200);
    final rows = (pj is Map ? pj['data'] ?? pj['items'] ?? pj['conversations'] : pj) as List;
    final mine = rows.cast<Map<String, dynamic>>().firstWhere((c) => c['id'] == _conv);
    final prefs = (mine['prefs'] as Map?) ?? const {};
    expect(prefs['theme'], 'ocean');
    expect(prefs['wallpaper'], 'pattern:waves');
    // The thread was pushed on top of Appearance; pop until Settings shows.
    await _popUntil(tester, router, 'back on settings', 'settings-list');

    // ---- 3. Notifications → Messages tone → chime; GET as me agrees.
    await _tapIn(tester, 'settings-list', 'settings-notifications');
    await _until(tester, 'notifications', () => _has(find.byKey(const ValueKey('notif-list'))));
    await _until(tester, 'tone row', () => _has(find.byKey(const ValueKey('notif-row-messages_tone'))));
    await _settle(tester, 600);
    await _shot(tester, '07_notifications');
    await _tapIn(tester, 'notif-list', 'notif-row-messages_tone');
    await _until(tester, 'tone picker', () => _has(find.byKey(const ValueKey('tone-list'))));
    await _tapIn(tester, 'tone-list', 'tone-chime');
    await _until(tester, 'chime on the server', () async {
      final (c, j) = await _otherDevice('GET', '/users/me/notifications');
      return c == 200 && (j as Map)['messages_tone'] == 'chime';
    });
    await _settle(tester, 500);
    await _shot(tester, '08_tone_picker');
    router.pop();
    await _settle(tester, 300);
    router.pop();
    await _until(tester, 'settings again', () => _has(find.byKey(const ValueKey('settings-list'))));

    // ---- 4. App lock → on (scripted Face ID), Immediately; background and
    // back → the gate covers the app; a failed prompt keeps it, a good one
    // clears it.
    await _tapIn(tester, 'settings-list', 'settings-app-lock');
    await _until(tester, 'app lock', () => _has(find.byKey(const ValueKey('app-lock-list'))));
    fakeAuth
      ..available = true
      ..result = true;
    await tester.tap(find.byKey(const ValueKey('app-lock-switch-enabled')));
    await _until(tester, 'lock on', () => container.read(appSettingsProvider).appLock);
    await _tapIn(tester, 'app-lock-list', 'app-lock-row-timeout');
    await _until(tester, 'timeout sheet',
        () => _has(find.byKey(const ValueKey('app-lock-opt-timeout-0'))));
    await tester.tap(find.byKey(const ValueKey('app-lock-opt-timeout-0')));
    await _until(tester, 'immediately',
        () => container.read(appSettingsProvider).appLockTimeout == AppLockTimeout.immediately);
    await _settle(tester, 500);
    await _shot(tester, '09_app_lock_settings');
    fakeAuth.result = false; // the person cancels the prompt
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _settle(tester, 300);
    expect(_has(find.byKey(const ValueKey('app-lock-cover'))), isTrue, reason: 'privacy cover');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _until(tester, 'locked', () => _has(find.byKey(const ValueKey('app-lock-screen'))));
    await _settle(tester, 800);
    await _shot(tester, '10_app_locked');
    fakeAuth.result = true;
    await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
    await _until(tester, 'unlocked', () => !_has(find.byKey(const ValueKey('app-lock-screen'))));
    expect(container.read(appLockProvider).locked, isFalse);
    // Off again so the next launch of this install is not gated.
    await tester.tap(find.byKey(const ValueKey('app-lock-switch-enabled')));
    await _until(tester, 'lock off', () => !container.read(appSettingsProvider).appLock);
    router.pop();
    await _until(tester, 'settings once more', () => _has(find.byKey(const ValueKey('settings-list'))));

    // ---- 5. Linked devices: this device + the iPad; revoke others.
    await _tapIn(tester, 'settings-list', 'settings-devices');
    await _until(tester, 'devices list', () => _has(find.byKey(const ValueKey('devices-list'))));
    await _until(tester, 'sessions loaded', () => container.read(sessionsProvider).hasValue);
    final sessions = container.read(sessionsProvider).value!;
    final current = sessions.where((s) => s.current).toList();
    expect(current, hasLength(1), reason: 'the fresh sign-in is the current session');
    final ipad = sessions.where((s) => (s.deviceName ?? '').startsWith('iPad')).toList();
    expect(ipad, hasLength(1), reason: 'the prep script minted an iPad session');
    await _until(tester, 'this device row',
        () => _has(find.byKey(ValueKey('devices-row-${current.single.id}'))));
    expect(_has(find.byKey(ValueKey('devices-row-${ipad.single.id}'))), isTrue);
    expect((await _otherDevice('GET', '/users/me')).$1, 200, reason: 'iPad still signed in');
    await _settle(tester, 600);
    await _shot(tester, '11_linked_devices');
    await _tapIn(tester, 'devices-list', 'devices-revoke-others');
    await _until(tester, 'revoke confirm', () => _has(find.byKey(const ValueKey('devices-confirm'))));
    await tester.tap(find.byKey(const ValueKey('devices-confirm')));
    await _until(tester, 'iPad row gone',
        () => !_has(find.byKey(ValueKey('devices-row-${ipad.single.id}'))));
    await _until(tester, 'iPad token is dead',
        () async => (await _otherDevice('GET', '/users/me')).$1 == 401);
    expect(container.read(authProvider).stage, AuthStage.signedIn, reason: 'this device stays');
    await _settle(tester, 600);
    await _shot(tester, '12_devices_after_revoke');
    router.pop();
    await _until(tester, 'settings after devices', () => _has(find.byKey(const ValueKey('settings-list'))));

    // ---- 6. Status preset: On call shows under my name.
    router.push(AppRoutes.profileStatus);
    await _until(tester, 'status screen', () => _has(find.byKey(const ValueKey('status-list'))));
    await _tapIn(tester, 'status-list', 'status-preset-on_call');
    await _tapIn(tester, 'status-list', 'status-save');
    await _until(tester, 'status saved',
        () => container.read(authProvider).user?.statusPreset == StatusPreset.onCall);
    await _until(tester, 'back on settings with status', () => _has(find.text('On call')));
    await _settle(tester, 600);
    await _shot(tester, '13_status_on_call');

    // ---- 7. Language → Español; Settings in Spanish.
    await _tapIn(tester, 'settings-list', 'settings-language');
    await _until(tester, 'language', () => _has(find.byKey(const ValueKey('language-list'))));
    await tester.tap(find.byKey(const ValueKey('language-opt-es')));
    await _until(tester, 'locale es', () => container.read(appSettingsProvider).locale?.languageCode == 'es');
    await _settle(tester, 500);
    router.pop();
    await _until(tester, 'Ajustes', () => _has(find.text('Ajustes')));
    await _settle(tester, 800);
    await _shot(tester, '14_settings_es');

    // Leave the install as we found it.
    await settings.setLocale(null);
    await settings.setThemeMode(ThemeMode.system);
    await _settle(tester, 500);
  });
}
