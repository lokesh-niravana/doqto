// On-device proof that the app is socket-driven: nothing below pulls to
// refresh or taps "Check now". The app signs in as the Firebase test number
// +1 650-555-0198 (org under review), while an admin and a second doctor act over
// REST with pre-minted tokens; every screen must update on its own.
//
//   flutter test integration_test/realtime_test.dart -d <sim> \
//     --dart-define=FIREBASE_TEST_NUMBERS=true \
//     --dart-define=API_BASE_URL=http://localhost:8010 \
//     --dart-define=WS_BASE_URL=ws://localhost:8010 \
//     --dart-define=ME_ID=… --dart-define=PEER_ID=… --dart-define=ORG_ID=… \
//     --dart-define=PEER_TOKEN=… --dart-define=STAFF_TOKEN=… \
//     [--dart-define=SHOT_DIR=<folder on this Mac>]
//
// The ids/tokens come from a prep script that resets the two users (org back
// to pending, not connected, no pending invitations) and mints the tokens.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/state/org_state.dart';

const _me = String.fromEnvironment('ME_ID');
const _peer = String.fromEnvironment('PEER_ID');
const _org = String.fromEnvironment('ORG_ID');
const _peerToken = String.fromEnvironment('PEER_TOKEN');
const _staffToken = String.fromEnvironment('STAFF_TOKEN');
const _shotDir = String.fromEnvironment('SHOT_DIR');

/// How long a live update may take to reach the screen. The socket round
/// trip is milliseconds; this is generous so a slow debug build never fakes
/// a failure.
const _liveTimeout = Duration(seconds: 10);

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/shot_$name.png').writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Pump until [ready] holds, or fail with [what] after [_liveTimeout].
/// Returns how long it took, so the log shows the real latency.
Future<Duration> _until(WidgetTester t, String what, bool Function() ready) async {
  final start = DateTime.now();
  while (!ready()) {
    if (DateTime.now().difference(start) > _liveTimeout) {
      fail('not live within $_liveTimeout: $what');
    }
    await t.pump(const Duration(milliseconds: 100));
  }
  final took = DateTime.now().difference(start);
  // ignore: avoid_print
  print('LIVE  ${took.inMilliseconds} ms  $what');
  return took;
}

Future<Map<String, dynamic>?> _rest(
  String method,
  String path, {
  required String token,
  Map<String, dynamic>? body,
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(
        method, Uri.parse('${AppConstants.apiBaseUrl}/api/v1$path'));
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      fail('$method $path → ${res.statusCode} $text');
    }
    return text.isEmpty ? null : jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every cross-user change arrives without a refresh',
      (tester) async {
    expect(_me.isNotEmpty && _peer.isNotEmpty && _org.isNotEmpty, isTrue,
        reason: 'run the prep script and pass its dart-defines');
    await app.main();
    await _settle(tester, 3000);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final auth = container.read(authProvider.notifier);
    final router = container.read(routerProvider);

    // ---- 1. Sign in. The org is still under review: My Org says pending.
    if (container.read(authProvider).stage == AuthStage.signedOut ||
        container.read(authProvider).stage == AuthStage.unknown) {
      final challenge = await auth.startPhoneSignIn('+16505550198');
      await auth.confirmPhoneCode(challenge, '654321');
    }
    await _until(tester, 'signed in',
        () => container.read(authProvider).stage == AuthStage.signedIn);
    expect(container.read(orgProvider).current?.status, OrgStatus.pending);
    router.push(AppRoutes.myOrg);
    await _settle(tester, 2500);
    await _shot(tester, '1_org_pending');

    // ---- 2. An admin verifies the org over REST → status flips by itself.
    await _rest('PATCH', '/admin/orgs/$_org/verify', token: _staffToken);
    await _until(tester, 'org verified → active (no poll, no Check now)',
        () => container.read(orgProvider).current?.status == OrgStatus.active);
    await _settle(tester, 2500);
    await _shot(tester, '2_org_verified_live');

    // ---- 3. The other doctor invites me → Network tab shows the card.
    router.go(AppRoutes.network);
    await _settle(tester, 2500);
    expect(find.text('Accept'), findsNothing);
    await _rest('POST', '/network/invitations',
        token: _peerToken, body: {'recipient_id': _me});
    await _until(tester, 'invitation card appears on the Network tab',
        () => find.text('Accept').evaluate().isNotEmpty);
    await _settle(tester, 1000);
    expect(find.text('Demo Reviewer'), findsWidgets);
    await _shot(tester, '3_invitation_live');

    // ---- 4. I accept in the UI → every list I can see agrees at once.
    await tester.tap(find.text('Accept').first);
    await _until(tester, 'accept fans out: inbox empty, connection listed', () {
      final inbox = container.read(invitationsProvider).value;
      final conns = container.read(connectionsProvider).value;
      return inbox != null &&
          inbox.every((i) => i.sender?.id != _peer) &&
          conns != null &&
          conns.any((p) => p.id == _peer);
    });
    await _settle(tester, 1500);
    expect(find.text('Accept'), findsNothing);
    await _shot(tester, '4_accepted');

    // ---- 5. They message me → chat list updates without a pull.
    final conv = await _rest('POST', '/conversations',
        token: _peerToken,
        body: {'type': 'direct', 'member_ids': [_me]});
    final convId = conv!['id'] as String;
    router.go(AppRoutes.chats);
    await _settle(tester, 2500);
    const first = 'Realtime hello from the other phone';
    await _rest('POST', '/conversations/$convId/messages',
        token: _peerToken, body: {'content': first});
    await _until(tester, 'new message preview appears in the chat list',
        () => find.textContaining(first).evaluate().isNotEmpty);
    await _settle(tester, 1000);
    await _shot(tester, '5_chat_list_live');

    // ---- 6. With the thread open, the next message lands as a bubble.
    router.push(AppRoutes.chat(convId));
    await _settle(tester, 2500);
    const second = 'And a second one while the thread is open';
    await _rest('POST', '/conversations/$convId/messages',
        token: _peerToken, body: {'content': second});
    await _until(tester, 'bubble appears in the open thread',
        () => find.text(second).evaluate().isNotEmpty);
    await _settle(tester, 1000);
    await _shot(tester, '6_thread_live');

    // ---- 7. They remove the connection → my connections list drops them.
    await _rest('DELETE', '/network/connections/$_me', token: _peerToken);
    await _until(tester, 'connection removal reaches my connections list', () {
      final conns = container.read(connectionsProvider).value;
      return conns != null && conns.every((p) => p.id != _peer);
    });
  });
}
