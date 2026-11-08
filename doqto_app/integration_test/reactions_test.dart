// On-device walk of message reactions. The app signs in as the Firebase test
// number +1 650-555-0198 while the peer (+1 650-555-0199) acts over REST.
// Every check reads both sides: the screen AND the server.
//
//   cd doqto_backend && venv/bin/python scripts/reactions_device_prep.py
//   flutter test integration_test/reactions_test.dart -d <sim> \
//     --dart-define=FIREBASE_TEST_NUMBERS=true \
//     --dart-define=API_BASE_URL=http://localhost:8010 \
//     --dart-define=WS_BASE_URL=ws://localhost:8010 \
//     --dart-define=ME_ID=… --dart-define=PEER_ID=… --dart-define=PEER_TOKEN=… \
//     [--dart-define=SHOT_DIR=<folder on this Mac>]
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';

const _me = String.fromEnvironment('ME_ID');
const _peer = String.fromEnvironment('PEER_ID');
const _peerToken = String.fromEnvironment('PEER_TOKEN');
const _shotDir = String.fromEnvironment('SHOT_DIR');
const _liveTimeout = Duration(seconds: 10);

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/reactions_$name.png').writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<Duration> _until(WidgetTester t, String what, bool Function() ready) async {
  final start = DateTime.now();
  while (!ready()) {
    if (DateTime.now().difference(start) > _liveTimeout) {
      fail('not within $_liveTimeout: $what');
    }
    await t.pump(const Duration(milliseconds: 100));
  }
  final took = DateTime.now().difference(start);
  // ignore: avoid_print
  print('LIVE  ${took.inMilliseconds} ms  $what');
  return took;
}

Future<Object?> _rest(String method, String path, {Map<String, dynamic>? body, int? status}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('${AppConstants.apiBaseUrl}/api/v1$path'));
    req.headers.set('Authorization', 'Bearer $_peerToken');
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (status != null) {
      if (status != res.statusCode) fail('$method $path → ${res.statusCode} (wanted $status) $text');
    } else if (res.statusCode < 200 || res.statusCode >= 300) {
      fail('$method $path → ${res.statusCode} $text');
    }
    return text.isEmpty ? null : jsonDecode(text);
  } finally {
    client.close();
  }
}

/// The server's view of reactions on [messageId], as emoji → user ids.
Future<Map<String, List<String>>> _serverReactions(String convId, String messageId) async {
  final list = (await _rest('GET', '/conversations/$convId/messages')) as List;
  final m = list.cast<Map<String, dynamic>>().firstWhere((m) => m['id'] == messageId);
  return {
    for (final r in (m['reactions'] as List).cast<Map<String, dynamic>>())
      r['emoji'] as String: (r['user_ids'] as List).cast<String>(),
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // A sheet pushed mid-press otherwise swallows later long-presses (harness quirk).
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('react, replace, remove, pick custom, live both ways, catch up', (tester) async {
    expect(_me.isNotEmpty && _peer.isNotEmpty && _peerToken.isNotEmpty, isTrue,
        reason: 'run scripts/reactions_device_prep.py and pass its dart-defines');
    await app.main();
    await _settle(tester, 3000);

    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    final auth = container.read(authProvider.notifier);
    final router = container.read(routerProvider);

    if (container.read(authProvider).stage != AuthStage.signedIn) {
      final challenge = await auth.startPhoneSignIn('+16505550198');
      await auth.confirmPhoneCode(challenge, '654321');
    }
    await _until(tester, 'signed in', () => container.read(authProvider).stage == AuthStage.signedIn);

    // ---- Peer opens (or reuses) the DM and sends a fresh message.
    final conv = (await _rest('POST', '/conversations', body: {'type': 'direct', 'member_ids': [_me]}))
        as Map<String, dynamic>;
    final convId = conv['id'] as String;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final text = 'Can you see the CT from bed 4? #$stamp';
    final sent = (await _rest('POST', '/conversations/$convId/messages', body: {'content': text}))
        as Map<String, dynamic>;
    final msgId = sent['id'] as String;

    router.go(AppRoutes.chats);
    await _settle(tester, 1500);
    router.push(AppRoutes.chat(convId));
    await _until(tester, 'peer message bubble shown', () => find.text(text).evaluate().isNotEmpty);
    await _settle(tester, 1000);

    final messages = messagesProvider(convId);
    List<String> onScreen() => [
          for (final r in container.read(messages).value!.firstWhere((m) => m.id == msgId).reactions) r.emoji,
        ];
    List<String> mineOnScreen() => [
          for (final r in container.read(messages).value!.firstWhere((m) => m.id == msgId).reactions)
            if (r.userIds.contains(_me)) r.emoji,
        ];

    // ---- 1. Long-press → tray; tap 👍.
    await tester.longPress(find.text(text));
    await _until(tester, 'reaction tray appears', () => find.byKey(const ValueKey('reaction-tray')).evaluate().isNotEmpty);
    await _settle(tester, 500);
    await _shot(tester, '1_tray');
    await tester.tap(find.byKey(const ValueKey('reaction-pick-👍')));
    await _until(tester, 'my 👍 applied and tray closed', () =>
        mineOnScreen().contains('👍') && find.byKey(const ValueKey('reaction-tray')).evaluate().isEmpty);
    expect(find.byKey(const ValueKey('reaction-pills')), findsWidgets);
    await _settle(tester, 800);
    expect((await _serverReactions(convId, msgId))['👍'], [_me]);
    await _shot(tester, '2_thumbs_up');

    // ---- 2. Peer reacts ❤️ over REST → arrives live.
    await _rest('PUT', '/messages/$msgId/reaction', body: {'emoji': '❤️'});
    await _until(tester, 'peer ❤️ arrives live (no refresh)',
        () => find.byKey(const ValueKey('reaction-total')).evaluate().isNotEmpty);
    expect(find.text('2'), findsWidgets);
    await _settle(tester, 500);
    await _shot(tester, '3_live_from_peer');

    // ---- 3. Tap my 👍 again → removed (toggle).
    await tester.longPress(find.text(text));
    await _until(tester, 'tray again', () => find.byKey(const ValueKey('reaction-tray')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('reaction-pick-👍')));
    await _until(tester, 'my 👍 removed', () => mineOnScreen().isEmpty);
    await _settle(tester, 800);
    expect((await _serverReactions(convId, msgId)).containsKey('👍'), isFalse);

    // ---- 4. "+" → picker → search → 🔥.
    await tester.longPress(find.text(text));
    await _until(tester, 'tray for picker', () => find.byKey(const ValueKey('reaction-more')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('reaction-more')));
    await _until(tester, 'picker open', () => find.byKey(const ValueKey('emoji-search')).evaluate().isNotEmpty);
    await _settle(tester, 800);
    await _shot(tester, '4_picker');
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('emoji-search')), matching: find.byType(TextField)));
    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('emoji-search')), matching: find.byType(TextField)), 'fire');
    await _settle(tester, 800);
    await _shot(tester, '5_picker_search');
    await tester.tap(find.byKey(const ValueKey('emoji-🔥')).first);
    await _until(tester, 'custom 🔥 applied', () => mineOnScreen().contains('🔥'));
    await _settle(tester, 800);
    expect((await _serverReactions(convId, msgId))['🔥'], [_me]);
    await _shot(tester, '6_custom');

    // ---- 5. Tray shows my custom reaction selected.
    await tester.longPress(find.text(text));
    await _until(tester, 'tray shows 🔥 slot', () => find.byKey(const ValueKey('reaction-pick-🔥')).evaluate().isNotEmpty);
    // The tray lives in the long-press sheet since batch 4: dismiss via the barrier.
    await tester.tapAt(const Offset(20, 80));
    await _until(tester, 'sheet closed', () => find.byKey(const ValueKey('message-context-menu')).evaluate().isEmpty);
    await _settle(tester, 500);

    // ---- 6. Who reacted → my row first → tap to remove.
    await tester.tap(find.byKey(const ValueKey('reaction-pills')).first);
    await _until(tester, 'who-reacted sheet', () => find.text('Tap to remove').evaluate().isNotEmpty);
    await _settle(tester, 600);
    await _shot(tester, '7_who_reacted');
    await tester.tap(find.text('Tap to remove').first);
    await _until(tester, 'removed from sheet', () => mineOnScreen().isEmpty);
    await _settle(tester, 800);
    expect((await _serverReactions(convId, msgId)).keys, ['❤️']);

    // ---- 7. Offline catch-up: socket down, peer changes, socket up.
    final ws = container.read(websocketClientProvider);
    await ws.close();
    await _settle(tester, 500);
    await _rest('PUT', '/messages/$msgId/reaction', body: {'emoji': '😮'});
    await _settle(tester, 2000);
    expect(onScreen().contains('😮'), isFalse, reason: 'socket is down, nothing pushed');
    await ws.connect(tokenProvider: container.read(apiClientProvider).freshAccessToken);
    await _until(tester, 'missed reaction caught up after reconnect', () => onScreen().contains('😮'));
    expect(find.text('😮'), findsWidgets, reason: 'the peer replaced ❤️ with 😮; the pill shows it');
    expect(onScreen(), ['😮']);
    await _shot(tester, '8_caught_up');

    // ---- 8. Unhappy paths the UI must survive.
    // Peer deletes the message → my pill and tray are gone with it.
    final mine = (await _rest('POST', '/conversations/$convId/messages', body: {'content': 'delete me $stamp'}))
        as Map<String, dynamic>;
    await _until(tester, 'second bubble', () => find.text('delete me $stamp').evaluate().isNotEmpty);
    await _rest('PUT', '/messages/${mine['id']}/reaction', body: {'emoji': '👍'});
    await _rest('DELETE', '/messages/${mine['id']}');
    await _until(tester, 'tombstone replaces the bubble', () => find.text('delete me $stamp').evaluate().isEmpty);
    expect(
      container.read(messages).value!.firstWhere((m) => m.id == mine['id']).reactions,
      isEmpty,
    );
    // Reacting to a deleted message over REST is refused; invalid emoji too.
    await _rest('PUT', '/messages/${mine['id']}/reaction', body: {'emoji': '👍'}, status: 409);
    await _rest('PUT', '/messages/$msgId/reaction', body: {'emoji': 'ok'}, status: 422);
    await _settle(tester, 500);
    await _shot(tester, '9_after_delete');
  });
}
