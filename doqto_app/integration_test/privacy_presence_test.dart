// On-device walk of batch 2: privacy screen → read receipts off/on (verified
// through the peer's REST view of receipts) → last seen hidden (peer's
// presence view goes null) → presence dot + "online" header when the peer
// opens a socket → "last seen …" when it closes → block → blocked list →
// unblock. The app signs in as +1 650-555-0198; the peer (+1 650-555-0199)
// acts over REST and a raw /ws socket.
//
//   cd doqto_backend && venv/bin/python scripts/privacy_device_prep.py
//   flutter test integration_test/privacy_presence_test.dart -d <sim> \
//     --dart-define=FIREBASE_TEST_NUMBERS=true \
//     --dart-define=API_BASE_URL=http://localhost:8010 \
//     --dart-define=WS_BASE_URL=ws://localhost:8010 \
//     --dart-define=ME_ID=… --dart-define=PEER_ID=… --dart-define=CONV_ID=… \
//     --dart-define=PEER_TOKEN=… [--dart-define=SHOT_DIR=<folder on this Mac>]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/core/tokens/colors.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/state/privacy_state.dart';
import 'package:doqto_app/ui/widgets/doctor_avatar.dart';

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
  await File('$_shotDir/privacy_$name.png').writeAsBytes(png!.buffer.asUint8List());
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

/// The peer's view of my presence.
Future<Map<String, dynamic>> _peerSeesMe() async {
  final rows = (await _rest('GET', '/users/presence?ids=$_me')) as List;
  return rows.cast<Map<String, dynamic>>().firstWhere((r) => r['user_id'] == _me);
}

/// The peer's own /ws socket (scripts/ws_e2e.py pattern): auth frame first,
/// then keep listening so the socket stays open.
class _PeerSocket {
  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;

  Future<void> open() async {
    final ws = await WebSocket.connect('${AppConstants.wsBaseUrl}/ws');
    final connected = Completer<void>();
    _sub = ws.listen((raw) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (frame['type'] == 'connected' && !connected.isCompleted) connected.complete();
    });
    ws.add(jsonEncode({'type': 'auth', 'token': _peerToken}));
    await connected.future.timeout(const Duration(seconds: 5));
    _ws = ws;
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _ws?.close();
    _ws = null;
  }
}

bool _has(Finder f) => f.evaluate().isNotEmpty;

Finder _peerRowDot() => find.descendant(
      of: find.widgetWithText(ListTile, 'Demo Reviewer').first,
      matching: find.byType(PresenceStatusDot),
    );

String? _threadSubtitle(WidgetTester t) {
  final f = find.byKey(const ValueKey('thread-subtitle'));
  if (!_has(f)) return null;
  return t.widget<Text>(f).data;
}

Future<void> _revealPrivacy(WidgetTester t, Key key) async {
  if (!_has(find.byKey(key))) {
    await t.scrollUntilVisible(find.byKey(key), 150,
        scrollable: find.descendant(
            of: find.byKey(const ValueKey('privacy-list')),
            matching: find.byType(Scrollable)),
        maxScrolls: 20);
  } else {
    await t.ensureVisible(find.byKey(key));
  }
  await _settle(t, 400);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('privacy → read receipts → last seen → presence → block / unblock',
      (tester) async {
    expect(_me.isNotEmpty && _peer.isNotEmpty && _conv.isNotEmpty && _peerToken.isNotEmpty, isTrue,
        reason: 'run scripts/privacy_device_prep.py and pass its dart-defines');
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
    // The XCTest host leaves the app `inactive`; the thread only flips read
    // ticks while resumed (a person is looking), so act like a foreground app.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester, 1500);

    // ---- 1. Settings → Privacy.
    router.push(AppRoutes.settings);
    await _until(tester, 'settings', () => _has(find.byKey(const ValueKey('settings-privacy'))));
    await tester.tap(find.byKey(const ValueKey('settings-privacy')));
    await _until(tester, 'privacy screen', () => _has(find.byKey(const ValueKey('privacy-list'))));
    await _until(tester, 'privacy loaded', () => container.read(privacyProvider).hasValue);
    await _settle(tester, 1000);
    await _shot(tester, '1_privacy');

    // ---- 2. Read receipts OFF → the peer's receipts view stays "delivered".
    await _revealPrivacy(tester, const ValueKey('privacy-switch-read_receipts'));
    await tester.tap(find.byKey(const ValueKey('privacy-switch-read_receipts')));
    await _until(tester, 'read receipts off on the server', () async {
      final me = await _rest('GET', '/users/$_me/profile'); // peer can see me
      expect((me as Map)['id'], _me);
      return container.read(privacyProvider).value?.readReceipts == false;
    });
    await _settle(tester, 600);
    await _shot(tester, '2_read_receipts_off');
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    final sent = (await _rest('POST', '/conversations/$_conv/messages',
        body: {'content': 'Receipt check #$stamp'})) as Map<String, dynamic>;
    final msgId = sent['id'] as String;
    router.push(AppRoutes.chat(_conv));
    await _until(tester, 'thread shows the message', () => _has(find.text('Receipt check #$stamp')));
    await _settle(tester, 1500); // the thread marks read on open
    var receipts = (await _rest('GET', '/messages/$msgId/receipts')) as List;
    var mine = receipts.cast<Map<String, dynamic>>().firstWhere((r) => r['user_id'] == _me);
    expect(mine['delivered'], isTrue, reason: 'delivered ticks still flow');
    expect(mine['read'], isFalse, reason: 'read receipts are off for the pair');
    var msgs = (await _rest('GET', '/conversations/$_conv/messages')) as List;
    expect(msgs.cast<Map<String, dynamic>>().firstWhere((m) => m['id'] == msgId)['read'], isFalse);

    // Back on Privacy: ON again → the stored receipt surfaces at once.
    router.pop();
    await _until(tester, 'back on privacy', () => _has(find.byKey(const ValueKey('privacy-list'))));
    await _revealPrivacy(tester, const ValueKey('privacy-switch-read_receipts'));
    await tester.tap(find.byKey(const ValueKey('privacy-switch-read_receipts')));
    await _until(tester, 'read receipts on on the server',
        () => container.read(privacyProvider).value?.readReceipts == true);
    await _settle(tester, 600);
    receipts = (await _rest('GET', '/messages/$msgId/receipts')) as List;
    mine = receipts.cast<Map<String, dynamic>>().firstWhere((r) => r['user_id'] == _me);
    expect(mine['read'], isTrue, reason: 'the receipt was stored all along');

    // ---- 3. Last seen → Nobody: the peer's view of me goes dark.
    var seen = await _peerSeesMe();
    expect(seen['status'], 'online', reason: 'my app holds a socket and we are connected');
    expect(seen['last_seen_at'], isNotNull);
    await _revealPrivacy(tester, const ValueKey('privacy-row-last_seen_visibility'));
    await tester.tap(find.byKey(const ValueKey('privacy-row-last_seen_visibility')));
    await _until(tester, 'last seen sheet',
        () => _has(find.byKey(const ValueKey('privacy-opt-last_seen_visibility-nobody'))));
    await _settle(tester, 500);
    await _shot(tester, '3_last_seen_sheet');
    await tester.tap(find.byKey(const ValueKey('privacy-opt-last_seen_visibility-nobody')));
    await _until(tester, 'nobody saved', () async {
      final s = await _peerSeesMe();
      return s['status'] == 'offline' && s['last_seen_at'] == null;
    });
    await _settle(tester, 500);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('privacy-value-last_seen_visibility'))).data,
      Strings.privacyLastSeenNobody,
    );
    await _shot(tester, '4_last_seen_nobody');
    // And back to connections so the presence walk below can see the peer
    // (reciprocal rule: hiding mine hides theirs from me).
    await _revealPrivacy(tester, const ValueKey('privacy-row-last_seen_visibility'));
    await tester.tap(find.byKey(const ValueKey('privacy-row-last_seen_visibility')));
    await _until(tester, 'sheet again',
        () => _has(find.byKey(const ValueKey('privacy-opt-last_seen_visibility-connections'))));
    await tester.tap(find.byKey(const ValueKey('privacy-opt-last_seen_visibility-connections')));
    await _until(tester, 'connections saved', () async => (await _peerSeesMe())['status'] == 'online');

    // ---- 4. Presence: the peer opens a socket → green dot in the chat list,
    // "online" in the thread header; closes it → "last seen today at …".
    router.go(AppRoutes.chats);
    await _until(tester, 'chat list with the peer row',
        () => _has(find.widgetWithText(ListTile, 'Demo Reviewer')));
    final peerSocket = _PeerSocket();
    await peerSocket.open();
    await _until(tester, 'peer dot turns green', () {
      final f = _peerRowDot();
      return _has(f) && tester.widget<PresenceStatusDot>(f.first).color == AppColors.presenceOnline;
    });
    await _settle(tester, 800);
    await _shot(tester, '5_chat_list_online');
    await tester.tap(find.widgetWithText(ListTile, 'Demo Reviewer').first);
    await _until(tester, 'header says online', () => _threadSubtitle(tester) == Strings.presenceOnline);
    await _settle(tester, 800);
    await _shot(tester, '6_thread_online');
    await peerSocket.close();
    await _until(tester, 'header says last seen',
        () => (_threadSubtitle(tester) ?? '').startsWith('last seen today at'));
    await _settle(tester, 800);
    await _shot(tester, '7_thread_last_seen');
    router.pop();
    await _settle(tester, 600);

    // ---- 5. Block from the profile → banner + Unblock; the peer loses me.
    router.push(AppRoutes.person(_peer));
    await _until(tester, 'peer profile', () => _has(find.byIcon(Icons.more_horiz)));
    await _settle(tester, 800);
    await tester.tap(find.byIcon(Icons.more_horiz));
    await _until(tester, 'block in menu', () => _has(find.byKey(const ValueKey('profile-block'))));
    await tester.tap(find.byKey(const ValueKey('profile-block')));
    await _until(tester, 'block confirm', () => _has(find.widgetWithText(TextButton, Strings.netBlock)));
    await tester.tap(find.widgetWithText(TextButton, Strings.netBlock));
    await _until(tester, 'blocked banner', () => _has(find.byKey(const ValueKey('profile-blocked-banner'))));
    await _until(tester, 'peer gets 404 on my profile',
        () async => (await _restRaw('GET', '/users/$_me/profile')).$1 == 404);
    await _settle(tester, 800);
    await _shot(tester, '8_profile_blocked');
    router.pop();
    await _settle(tester, 400);

    // ---- 6. Blocked contacts → Unblock (confirm) → row goes, peer sees me again.
    router.push(AppRoutes.privacyBlocked);
    await _until(tester, 'blocked list row', () => _has(find.byKey(ValueKey('unblock-$_peer'))));
    await _settle(tester, 800);
    await _shot(tester, '9_blocked_list');
    await tester.tap(find.byKey(ValueKey('unblock-$_peer')));
    await _until(tester, 'unblock confirm', () => _has(find.byKey(const ValueKey('unblock-confirm'))));
    await _settle(tester, 400);
    await _shot(tester, '10_unblock_confirm');
    await tester.tap(find.byKey(const ValueKey('unblock-confirm')));
    await _until(tester, 'row gone', () => !_has(find.byKey(ValueKey('unblock-$_peer'))));
    await _until(tester, 'peer can see me again',
        () async => (await _restRaw('GET', '/users/$_me/profile')).$1 == 200);
    expect(container.read(blockedProvider).value, isEmpty);
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));
    await _settle(tester, 600);
    await _shot(tester, '11_blocked_list_empty');

    // Server agrees: nothing left in my block list (via the peer-independent
    // app repository, since only the peer's token is in the test).
    final page = await container.read(networkRepositoryProvider).listBlocks();
    expect(page.data, isEmpty);
  });
}
