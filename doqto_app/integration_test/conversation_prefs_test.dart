// On-device walk of batch 3 (conversation preferences): the peer sends two
// messages → pin (More sheet) → mute 8h (duration sheet) → Unread filter →
// open + read, then Mark unread → archive (swipe) → Archived (1) row → the
// Archived view → unarchive → clear chat (confirm; the peer keeps the
// history) → a draft typed in the thread survives leaving it and shows as
// "Draft: …" on the row. The app signs in as +1 650-555-0198; the peer
// (+1 650-555-0199) acts over REST.
//
//   cd doqto_backend && venv/bin/python scripts/conversation_prefs_device_prep.py
//   flutter test integration_test/conversation_prefs_test.dart -d <sim> \
//     --dart-define=FIREBASE_TEST_NUMBERS=true \
//     --dart-define=API_BASE_URL=http://localhost:8010 \
//     --dart-define=WS_BASE_URL=ws://localhost:8010 \
//     --dart-define=ME_ID=… --dart-define=PEER_ID=… --dart-define=CONV_ID=… \
//     --dart-define=FILLER_CONV_ID=… --dart-define=PEER_TOKEN=… \
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
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';

const _me = String.fromEnvironment('ME_ID');
const _peer = String.fromEnvironment('PEER_ID');
const _conv = String.fromEnvironment('CONV_ID');
const _peerToken = String.fromEnvironment('PEER_TOKEN');
const _shotDir = String.fromEnvironment('SHOT_DIR');
const _liveTimeout = Duration(seconds: 15);

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/prefs_$name.png').writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<Duration> _until(WidgetTester t, String what, FutureOr<bool> Function() ready) async {
  final start = DateTime.now();
  while (!await ready()) {
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

Future<(int, Object?)> _restRaw(String method, String path, {Map<String, dynamic>? body}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('${AppConstants.apiBaseUrl}/api/v1$path'));
    req.headers.set('Authorization', 'Bearer $_peerToken');
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  } finally {
    client.close();
  }
}

Future<Object?> _rest(String method, String path, {Map<String, dynamic>? body}) async {
  final (status, json) = await _restRaw(method, path, body: body);
  if (status < 200 || status >= 300) fail('$method $path → $status $json');
  return json;
}

bool _has(Finder f) => f.evaluate().isNotEmpty;

Finder _row() => find.byKey(const ValueKey('chat-row-$_conv'));

/// My own server-side view of the conversation (through the app's repository).
Future<Conversation> _mine(ProviderContainer c) async {
  final list = await c.read(chatRepositoryProvider).listConversations();
  return list.firstWhere((x) => x.id == _conv);
}

/// Leave the thread and wait for the chat list (and its chip row) to be back.
Future<void> _back(WidgetTester t, GoRouter router) async {
  router.pop();
  await _until(t, 'back on the list', () => _has(find.byKey(const ValueKey('chat-filter-all'))));
  await _settle(t, 400);
}

Future<void> _resetPrefs(ProviderContainer c) async {
  await c.read(chatRepositoryProvider).updatePrefs(_conv, {
    'pinned': false,
    'archived': false,
    'muted_until': null,
    'marked_unread': false,
  });
  await c.read(conversationsProvider.notifier).refresh();
}

Future<void> _swipe(WidgetTester t, double dx) async {
  await t.drag(_row(), Offset(dx, 0));
  await _settle(t, 500);
}

Future<void> _openMore(WidgetTester t) async {
  await _swipe(t, 160);
  await _until(t, 'More revealed', () => _has(find.byKey(const ValueKey('chat-swipe-more-$_conv'))));
  await t.tap(find.byKey(const ValueKey('chat-swipe-more-$_conv')));
  await _until(t, 'More sheet', () => _has(find.byKey(const ValueKey('chat-action-pin'))));
  await _settle(t, 400);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('pin → mute → unread filter → mark unread → archive → clear → draft',
      (tester) async {
    expect(_me.isNotEmpty && _peer.isNotEmpty && _conv.isNotEmpty && _peerToken.isNotEmpty, isTrue,
        reason: 'run scripts/conversation_prefs_device_prep.py and pass its dart-defines');
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
    // The XCTest host leaves the app `inactive`; act like a foreground app.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester, 1500);
    // Start flat whatever an earlier run left: no pin/mute/archive/dot, no draft.
    await container.read(draftsProvider.notifier).clear(_conv);
    await _resetPrefs(container);

    // ---- 0. The peer writes twice → the row shows "2" and leads the list.
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    await _rest('POST', '/conversations/$_conv/messages', body: {'content': 'Prefs walk #$stamp a'});
    await _rest('POST', '/conversations/$_conv/messages', body: {'content': 'Prefs walk #$stamp b'});
    router.go(AppRoutes.chats);
    await _until(tester, 'row with 2 unread', () {
      final c = container.read(conversationsProvider.notifier).conversation(_conv);
      return _has(_row()) && c != null && c.unreadCount >= 2;
    });
    await _settle(tester, 800);
    await _shot(tester, '1_list_unread');

    // ---- 1. Pin from the More sheet → pin icon, server pinned_at set.
    await _openMore(tester);
    await _shot(tester, '2_more_sheet');
    await tester.tap(find.byKey(const ValueKey('chat-action-pin')));
    await _until(tester, 'pin icon', () => _has(find.byKey(const ValueKey('chat-pinned-$_conv'))));
    await _until(tester, 'server pinned', () async => (await _mine(container)).prefs.isPinned);
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));
    await _shot(tester, '3_pinned');

    // ---- 2. Mute 8 hours → mute icon, server muted_until ≈ now + 8h.
    await _openMore(tester);
    await tester.tap(find.byKey(const ValueKey('chat-action-mute')));
    await _until(tester, 'mute sheet', () => _has(find.byKey(const ValueKey('chat-opt-mute-8h'))));
    await _settle(tester, 400);
    await _shot(tester, '4_mute_sheet');
    await tester.tap(find.byKey(const ValueKey('chat-opt-mute-8h')));
    await _until(tester, 'mute icon', () => _has(find.byKey(const ValueKey('chat-muted-$_conv'))));
    final muted = await _mine(container);
    expect(muted.prefs.isMuted(), isTrue);
    expect(muted.prefs.mutedUntil!.difference(DateTime.now().toUtc()).inMinutes,
        inInclusiveRange(470, 481));
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));
    await _shot(tester, '5_muted');

    // ---- 3. Unread filter: only this chat (the filler chat has nothing new).
    await tester.tap(find.byKey(const ValueKey('chat-filter-unread')));
    await _until(tester, 'unread view: filler gone, this chat stays',
        () => _has(_row()) && !_has(find.text('Dr Prefs Filler')));
    await _settle(tester, 600);
    await _shot(tester, '6_filter_unread');

    // ---- 4. Open the thread (reads it) → back → it leaves Unread; Mark
    // unread brings it back with a dot, no number.
    await tester.tap(_row());
    await _until(tester, 'thread shows the message', () => _has(find.text('Prefs walk #$stamp b')));
    await _settle(tester, 1200); // the thread marks read on open
    await _back(tester, router);
    await _until(tester, 'row left Unread', () async {
      final c = await _mine(container);
      return c.unreadCount == 0 && !_has(_row());
    });
    await tester.tap(find.byKey(const ValueKey('chat-filter-all')));
    await _until(tester, 'row back in All', () => _has(_row()));
    await _openMore(tester);
    await tester.tap(find.byKey(const ValueKey('chat-action-unread')));
    await _until(tester, 'unread dot', () => _has(find.byKey(const ValueKey('chat-unread-dot-$_conv'))));
    await _until(tester, 'server marked', () async => (await _mine(container)).prefs.markedUnread);
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));
    await _shot(tester, '7_marked_unread');
    // The badge number ignores this chat while it is muted; unmuting counts
    // the hand-set dot as one.
    expect(container.read(unreadTotalProvider), 0);
    await container.read(conversationsProvider.notifier).mute(_conv, null);
    await _until(tester, 'badge counts the dot', () => container.read(unreadTotalProvider) == 1);
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));

    // ---- 5. Swipe left → Archive. Row goes; "Archived (1)" opens the view.
    await _swipe(tester, -160);
    await _until(tester, 'Archive revealed',
        () => _has(find.byKey(const ValueKey('chat-swipe-archive-$_conv'))));
    await _shot(tester, '8_swipe_archive');
    await tester.tap(find.byKey(const ValueKey('chat-swipe-archive-$_conv')));
    await _until(tester, 'archived row', () => _has(find.byKey(const ValueKey('chat-archived-row'))));
    expect(_has(_row()), isFalse);
    await _until(tester, 'server archived', () async => (await _mine(container)).prefs.archived);
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));
    await _shot(tester, '9_archived_row');
    await tester.tap(find.byKey(const ValueKey('chat-archived-row')));
    await _until(tester, 'archived view', () => _has(_row()));
    await _settle(tester, 600);
    await _shot(tester, '10_archived_view');
    // Unarchive (swipe left again: the button now reads Unarchive).
    await _swipe(tester, -160);
    await tester.tap(find.byKey(const ValueKey('chat-swipe-archive-$_conv')));
    await _until(tester, 'server unarchived', () async => !(await _mine(container)).prefs.archived);
    await tester.tap(find.byKey(const ValueKey('chat-filter-all')));
    await _until(tester, 'row back', () => _has(_row()));
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));

    // ---- 6. Clear chat: confirm → thread opens empty; the peer still has it.
    await _openMore(tester);
    await tester.tap(find.byKey(const ValueKey('chat-action-clear')));
    await _until(tester, 'clear confirm', () => _has(find.byKey(const ValueKey('chat-confirm-clear'))));
    await _settle(tester, 400);
    await _shot(tester, '11_clear_confirm');
    await tester.tap(find.byKey(const ValueKey('chat-confirm-clear')));
    await _until(tester, 'server cleared',
        () async => (await _mine(container)).prefs.clearedBeforeSeq != null);
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));
    final mineMsgs = await container.read(chatRepositoryProvider).listMessages(_conv);
    expect(mineMsgs, isEmpty, reason: 'cleared for me');
    final peerMsgs = (await _rest('GET', '/conversations/$_conv/messages')) as List;
    expect(peerMsgs.any((m) => (m as Map)['content'] == 'Prefs walk #$stamp b'), isTrue,
        reason: 'the peer keeps the history');
    await tester.tap(_row());
    await _until(tester, 'thread open', () => _has(find.byType(TextField)));
    await _settle(tester, 1200);
    expect(find.text('Prefs walk #$stamp b'), findsNothing);
    await _shot(tester, '12_cleared_thread');

    // ---- 7. Draft: type, leave, see "Draft: …" in red, reopen → restored.
    final draft = 'Unsent thought #$stamp';
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), draft);
    await _settle(tester, 800); // the debounced save
    await _back(tester, router);
    await _until(tester, 'draft on the row', () => _has(find.byKey(const ValueKey('chat-draft-$_conv'))));
    await _settle(tester, 600);
    await _shot(tester, '13_draft_row');
    expect(container.read(draftsProvider)[_conv], draft);
    expect(container.read(chatCacheProvider).draft(_conv), draft, reason: 'persisted in the encrypted box');
    await tester.tap(_row());
    await _until(tester, 'thread open', () => _has(find.byType(TextField)));
    await _settle(tester, 600);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, draft);
    expect(find.byKey(const ValueKey('composer-send')), findsOneWidget, reason: 'send button armed');
    await _shot(tester, '14_draft_restored');
    // Leave it clean for the next run.
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '');
    await _settle(tester, 800);
    await _back(tester, router);
    await _until(tester, 'draft gone', () => !_has(find.byKey(const ValueKey('chat-draft-$_conv'))));

    // ---- 8. Tidy: unpin + unmute + read so the next run starts flat.
    await _resetPrefs(container);
    final end = await _mine(container);
    expect(end.prefs.isPinned || end.prefs.isMuted() || end.prefs.markedUnread, isFalse);
    expect(Strings.chatDraftPrefix, 'Draft: ');
  });
}
