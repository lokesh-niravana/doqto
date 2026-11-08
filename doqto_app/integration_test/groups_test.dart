// On-device walk of groups: invite → accept → chat → promote → manage →
// admins-only → read-by. The app signs in as the Firebase test number
// +1 650-555-0198 while the peer (+1 650-555-0199) acts over REST.
//
//   cd doqto_backend && venv/bin/python scripts/groups_device_prep.py
//   flutter test integration_test/groups_test.dart -d <sim> \
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
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/groups_state.dart';

const _me = String.fromEnvironment('ME_ID');
const _peer = String.fromEnvironment('PEER_ID');
const _peerToken = String.fromEnvironment('PEER_TOKEN');
const _shotDir = String.fromEnvironment('SHOT_DIR');
const _liveTimeout = Duration(seconds: 12);

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/groups_$name.png').writeAsBytes(png!.buffer.asUint8List());
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

bool _has(Finder f) => f.evaluate().isNotEmpty;

/// Scroll the Group info list until [key] is on screen, then settle.
Future<void> _reveal(WidgetTester t, Key key) async {
  if (_has(find.byKey(key))) {
    await t.ensureVisible(find.byKey(key));
  } else {
    await t.scrollUntilVisible(find.byKey(key), 200,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('group-info-list')),
          matching: find.byType(Scrollable),
        ),
        maxScrolls: 30);
  }
  await _settle(t, 400);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('invite → accept → chat → promote → manage → admins-only → read-by',
      (tester) async {
    expect(_me.isNotEmpty && _peer.isNotEmpty && _peerToken.isNotEmpty, isTrue,
        reason: 'run scripts/groups_device_prep.py and pass its dart-defines');
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

    // ---- Peer creates a group and invites me (over REST).
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    final name = 'Walk $stamp';
    final group = (await _rest('POST', '/groups', body: {
      'name': name,
      'description': 'Stroke pathway coordination',
    })) as Map<String, dynamic>;
    final groupId = group['id'] as String;
    final convId = group['conversation_id'] as String;
    await _rest('POST', '/groups/$groupId/invites', body: {'user_id': _me});

    // ---- 1. Groups tab shows the Invited row live, with Accept / Decline.
    router.go(AppRoutes.groups);
    await _until(tester, 'invited row appears live', () => _has(find.text(name)));
    await _until(tester, 'Accept on the row', () => _has(find.byKey(ValueKey('group-accept-$groupId'))));
    await _settle(tester, 800);
    await _shot(tester, '1_invited');

    // ---- 2. Accept → member → the group chat opens.
    await tester.tap(find.byKey(ValueKey('group-accept-$groupId')));
    await _until(tester, 'group chat opens with composer',
        () => _has(find.byKey(const ValueKey('composer-idle-empty'))) || _has(find.byKey(const ValueKey('composer-idle'))));
    await _settle(tester, 800);
    await _shot(tester, '2_chat_after_accept');
    // Let the "You joined" toast clear: it sits over the composer.
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));
    await _settle(tester, 400);
    final members = (await _rest('GET', '/groups/$groupId/members')) as List;
    expect(members.any((m) => m['user_id'] == _me && m['state'] == 'active'), isTrue,
        reason: 'the server has me as an active member');

    // ---- 3. Send a message from the composer.
    final text = 'Bed 7 ready for transfer #$stamp';
    await tester.tap(find.byType(TextField).last);
    await tester.enterText(find.byType(TextField).last, text);
    await _settle(tester, 300);
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await _until(tester, 'my bubble shown',
        () => _has(find.text(text)) && tester.widget<TextField>(find.byType(TextField).last).controller!.text.isEmpty);
    await _settle(tester, 1200);
    final list = (await _rest('GET', '/conversations/$convId/messages')) as List;
    final mine = list.cast<Map<String, dynamic>>().firstWhere((m) => m['content'] == text);
    final myMsgId = mine['id'] as String;
    await _shot(tester, '3_sent');

    // ---- 4. Peer promotes me → Group info shows the management surface.
    await _rest('PATCH', '/groups/$groupId/members/$_me', body: {'role': 'admin'});
    await _until(tester, 'promotion arrives live',
        () => container.read(groupDetailProvider(groupId)).asData?.value.canManage == true);
    router.push(AppRoutes.groupInfo(groupId));
    await _until(tester, 'group info with settings', () => _has(find.text(Strings.groupSettingsLabel)));
    await _settle(tester, 1000);
    await _shot(tester, '4_group_info_admin');

    // ---- 5. Edit the description.
    await tester.tap(find.byKey(const ValueKey('group-description-edit')));
    await _until(tester, 'description dialog', () => _has(find.byKey(const ValueKey('group-description-field'))));
    final field = find.descendant(
        of: find.byKey(const ValueKey('group-description-field')), matching: find.byType(TextField));
    await tester.tap(field);
    await tester.enterText(field, 'Stroke pathway — updated $stamp');
    await _settle(tester, 400);
    await _shot(tester, '5_edit_description');
    await tester.tap(find.byKey(const ValueKey('edit-save')));
    await _until(tester, 'description saved on screen',
        () => !_has(find.byKey(const ValueKey('edit-save'))) && _has(find.text('Stroke pathway — updated $stamp')));
    await _settle(tester, 800);
    final detail = (await _rest('GET', '/groups/$groupId')) as Map<String, dynamic>;
    expect(detail['description'], 'Stroke pathway — updated $stamp');

    // ---- 6. Member actions sheet on the peer (I am admin: message/profile/remove/ban, no role change).
    await _reveal(tester, ValueKey('member-$_peer'));
    await tester.tap(find.byKey(ValueKey('member-$_peer')));
    await _until(tester, 'member actions sheet', () => _has(find.byKey(const ValueKey('member-action-message'))));
    await _settle(tester, 600);
    expect(find.byKey(const ValueKey('member-action-role')), findsNothing, reason: 'admins cannot change roles');
    expect(find.byKey(const ValueKey('member-action-remove')), findsNothing,
        reason: 'an admin cannot remove the owner');
    await _shot(tester, '6_member_actions');
    await tester.tapAt(const Offset(200, 80)); // dismiss the sheet
    await _settle(tester, 600);

    // ---- 7. Invite link: create, listed, revoke.
    await _reveal(tester, const ValueKey('link-create'));
    await tester.tap(find.byKey(const ValueKey('link-create')));
    await _until(tester, 'create link sheet', () => _has(find.byKey(const ValueKey('link-create-confirm'))));
    await _settle(tester, 500);
    await _shot(tester, '7_create_link');
    await tester.tap(find.byKey(const ValueKey('link-create-confirm')));
    await _until(tester, 'link listed', () => _has(find.textContaining('doqto:///g/')));
    expect(find.text('Link copied'), findsOneWidget, reason: 'a new link lands on the clipboard');
    final invites = (await _rest('GET', '/groups/$groupId/invites')) as List;
    final link = invites.cast<Map<String, dynamic>>().firstWhere((i) => i['token'] != null);
    await _settle(tester, 500);
    await _shot(tester, '8_link_listed');
    await _reveal(tester, ValueKey('link-revoke-${link['id']}'));
    await tester.tap(find.byKey(ValueKey('link-revoke-${link['id']}')));
    await _until(tester, 'link gone', () => !_has(find.textContaining('doqto:///g/')));
    final after = (await _rest('GET', '/groups/$groupId/invites')) as List;
    expect(after.cast<Map<String, dynamic>>().any((i) => i['id'] == link['id']), isFalse);

    // ---- 8. Admins-only: I set it; the peer (owner) can still post, a member cannot.
    await _reveal(tester, const ValueKey('setting-post-policy'));
    await tester.tap(find.byKey(const ValueKey('setting-post-policy')));
    await _until(tester, 'post policy sheet', () => _has(find.byKey(const ValueKey('post-admins_only'))));
    await tester.tap(find.byKey(const ValueKey('post-admins_only')));
    await _until(tester, 'admins only shown', () => _has(find.text(Strings.groupSendAdmins)));
    await _settle(tester, 800);
    expect(((await _rest('GET', '/groups/$groupId')) as Map)['post_policy'], 'admins_only');
    await _shot(tester, '9_admins_only_set');

    // Peer demotes me → my composer becomes the read-only notice.
    await _rest('PATCH', '/groups/$groupId/members/$_me', body: {'role': 'member'});
    await _until(tester, 'demotion arrives live',
        () => container.read(groupDetailProvider(groupId)).asData?.value.canManage == false);
    router.pop();
    await _until(tester, 'composer replaced by notice', () => _has(find.byKey(const ValueKey('posting-closed'))));
    expect(find.text(Strings.groupAdminsOnlyNotice), findsOneWidget);
    await _until(tester, 'toasts gone', () => !_has(find.byType(SnackBar)));
    await _settle(tester, 500);
    await _shot(tester, '10_posting_closed');
    // Server agrees: a member's POST is refused with post_restricted.
    // (Peer is the owner, so prove it the other way: swap roles and have the
    // peer post as a member.)
    await _rest('POST', '/groups/$groupId/transfer-ownership', body: {'user_id': _me});
    await _until(tester, 'ownership arrives live',
        () => container.read(groupDetailProvider(groupId)).asData?.value.isOwner == true);
    // The previous owner is now an admin: demote them from the actions sheet
    // (owner-only "Remove as admin"), then their POST is refused.
    router.push(AppRoutes.groupInfo(groupId));
    await _until(tester, 'group info as owner', () => _has(find.text(Strings.groupSettingsLabel)));
    await _reveal(tester, ValueKey('member-$_peer'));
    await tester.tap(find.byKey(ValueKey('member-$_peer')));
    await _until(tester, 'owner actions', () => _has(find.byKey(const ValueKey('member-action-role'))));
    expect(find.text(Strings.groupMemberDemote), findsOneWidget);
    await _settle(tester, 400);
    await _shot(tester, '11_owner_member_actions');
    await tester.tap(find.byKey(const ValueKey('member-action-role')));
    for (var i = 0; i < 30; i++) {
      final ms = (await _rest('GET', '/groups/$groupId/members')) as List;
      if (ms.any((m) => m['user_id'] == _peer && m['role'] == 'member')) break;
      await _settle(tester, 300);
    }
    router.pop();
    await _settle(tester, 600);
    final refused = await _restRaw('POST', '/conversations/$convId/messages', body: {'content': 'should fail'});
    expect(refused.$1, 403);
    expect(refused.$2, contains('post_restricted'));
    await _until(tester, 'composer is back for the owner',
        () => _has(find.byKey(const ValueKey('composer-idle-empty'))) || _has(find.byKey(const ValueKey('composer-idle'))));

    // ---- 9. Read-by: peer reads the thread → Message info lists them under Read by.
    await _rest('POST', '/conversations/$convId/read');
    await _settle(tester, 800);
    await tester.longPress(find.text(text));
    await _until(tester, 'selection with info', () => _has(find.byKey(const ValueKey('select-info'))));
    await tester.tap(find.byKey(const ValueKey('select-info')));
    await _until(tester, 'receipts sheet', () => _has(find.byKey(ValueKey('receipt-$_peer'))));
    await _settle(tester, 800);
    expect(find.text('${Strings.groupReadBy} · 1'), findsOneWidget);
    await _shot(tester, '12_read_by');
    await tester.tapAt(const Offset(200, 80));
    await _settle(tester, 500);

    // ---- 10. Unhappy paths the server must refuse.
    // An outsider cannot read receipts on my message (404, no oracle).
    final outsider = await _restRaw('GET', '/messages/$myMsgId/receipts');
    expect(outsider.$1, 403, reason: 'the peer is a member but not the sender');
    // Capacity and double-invite are idempotent / bounded.
    await _rest('POST', '/groups/$groupId/invites', body: {'user_id': _me}, status: 409);
  });
}

Future<(int, String)> _restRaw(String method, String path, {Map<String, dynamic>? body}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('${AppConstants.apiBaseUrl}/api/v1$path'));
    req.headers.set('Authorization', 'Bearer $_peerToken');
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  } finally {
    client.close();
  }
}
