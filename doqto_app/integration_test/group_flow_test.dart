// On-device walk of the whole group membership flow, both sides:
//   invitee: pending invite → Group info shows Accept/Decline and the member
//            count (never a 403) → accept → chat → "joined the group" banner
//   admin:   add a member from the sheet → they accept → banner live →
//            remove them → "removed by" banner → invite link → they join by
//            link → banner → they leave → "left the group" banner.
// The app signs in as +1 650-555-0198; the peer (+1 650-555-0199) acts over
// REST. Same prep as the groups walk:
//
//   cd doqto_backend && venv/bin/python scripts/groups_device_prep.py
//   flutter test integration_test/group_flow_test.dart -d <sim> \
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

import 'package:doqto_app/core/constants/api_routes.dart';
import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';

const _me = String.fromEnvironment('ME_ID');
const _peer = String.fromEnvironment('PEER_ID');
const _peerToken = String.fromEnvironment('PEER_TOKEN');
const _shotDir = String.fromEnvironment('SHOT_DIR');
const _liveTimeout = Duration(seconds: 15);
const _peerName = 'Demo Reviewer';
const _meName = 'Second Tester';

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/flow_$name.png').writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _until(WidgetTester t, String what, bool Function() ready) async {
  final start = DateTime.now();
  while (!ready()) {
    if (DateTime.now().difference(start) > _liveTimeout) {
      // Leave evidence: a screenshot plus every visible string.
      await _shot(t, 'FAIL_${what.replaceAll(' ', '_')}');
      final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '').where((s) => s.isNotEmpty).toSet();
      // ignore: avoid_print
      print('FAIL-TEXTS ${texts.join(' | ')}');
      fail('not within $_liveTimeout: $what');
    }
    await t.pump(const Duration(milliseconds: 100));
  }
  // ignore: avoid_print
  print('LIVE  ${DateTime.now().difference(start).inMilliseconds} ms  $what');
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

Future<void> _waitForComposer(WidgetTester t, String what) => _until(
    t,
    what,
    () =>
        _has(find.byKey(const ValueKey('composer-idle-empty'))) ||
        _has(find.byKey(const ValueKey('composer-idle'))));

/// Server-side list of system banners in a conversation, oldest first.
Future<List<String>> _banners(String convId) async {
  final list = (await _rest('GET', '/conversations/$convId/messages')) as List;
  return [
    for (final m in list.cast<Map<String, dynamic>>())
      if (m['type'] == 'system') (m['content'] as String? ?? ''),
  ];
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('group flow: invitee view → accept → add → remove → link join → leave',
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
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester, 1500);
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;

    // =====================================================================
    // A. I am the invitee (the doctor's side of the reported bug).
    // =====================================================================
    final g1 = (await _rest('POST', '/groups', body: {
      'name': 'Ward round $stamp',
      'description': 'Morning handover',
    })) as Map<String, dynamic>;
    final g1Id = g1['id'] as String;
    final g1Conv = g1['conversation_id'] as String;
    await _rest('POST', '/groups/$g1Id/invites', body: {'user_id': _me});

    // Opening Group info straight from the invite (push tap) must show the
    // invite banner and the member count — never "You don't have permission".
    router.push(AppRoutes.groupInfo(g1Id));
    await _until(tester, 'invitee sees Accept', () => _has(find.byKey(const ValueKey('invite-accept'))));
    await _until(tester, 'member count instead of the list',
        () => _has(find.byKey(const ValueKey('members-join-hint'))));
    await _settle(tester, 800);
    expect(find.textContaining('permission'), findsNothing,
        reason: 'an invitee must not see a 403 on Group info');
    expect(find.text('1 member'), findsWidgets); // header + members section
    await _shot(tester, '01_invitee_group_info');

    // Accept → the chat opens for me; everyone sees "<me> joined the group".
    await tester.tap(find.byKey(const ValueKey('invite-accept')));
    await _waitForComposer(tester, 'chat opens after accepting');
    await _until(tester, 'my join banner in the thread',
        () => _has(find.text('$_meName joined the group')));
    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));
    await _settle(tester, 800);
    await _shot(tester, '02_joined_banner_me');
    expect(await _banners(g1Conv), contains('$_meName joined the group'),
        reason: 'the peer (owner) reads the same banner from the server');
    final g1Members = (await _rest('GET', '/groups/$g1Id/members')) as List;
    expect(g1Members.any((m) => m['user_id'] == _me && m['state'] == 'active'), isTrue);

    // Back on Group info as a member the full list shows, me included.
    router.push(AppRoutes.groupInfo(g1Id));
    await _until(tester, 'member list as a member', () => _has(find.byKey(ValueKey('member-$_me'))));
    expect(find.byKey(const ValueKey('members-join-hint')), findsNothing);
    await _settle(tester, 600);
    await _shot(tester, '03_member_sees_list');
    router.pop();
    await _settle(tester, 400);
    router.pop();
    await _settle(tester, 400);

    // =====================================================================
    // B. I am the admin: add → accept → remove → link join → leave.
    // =====================================================================
    final repo = container.read(groupsRepositoryProvider);
    final g2 = await repo.createGroup(name: 'Doqto Test $stamp', description: 'Invite flow');
    final g2Id = g2.id;
    final g2Conv = g2.conversationId;

    router.push(AppRoutes.groupInfo(g2Id));
    // The members section sits below the fold of a lazy list: wait for the
    // header, then scroll the Add button into view.
    await _until(tester, 'owner group info', () => _has(find.text('Doqto Test $stamp')));
    await _settle(tester, 600);
    await _reveal(tester, const ValueKey('members-add'));
    await tester.tap(find.byKey(const ValueKey('members-add')));
    await _until(tester, 'add members sheet', () => _has(find.byKey(const ValueKey('add-members-search'))));
    await _until(tester, 'peer listed', () => _has(find.byKey(ValueKey('add-$_peer'))));
    await tester.tap(find.byKey(ValueKey('add-$_peer')));
    await _settle(tester, 400);
    await _shot(tester, '04_add_members_sheet');
    await tester.tap(find.byKey(const ValueKey('add-members-invite')));
    await _until(tester, 'sheet closed', () => !_has(find.byKey(const ValueKey('add-members-search'))));

    // The peer has a pending invite (their Group info shows it) and accepts.
    final peerView = (await _rest('GET', '/groups/$g2Id')) as Map<String, dynamic>;
    final inviteId = peerView['invite_id'] as String?;
    expect(inviteId, isNotNull, reason: 'the add sheet sends a direct invite');
    await _rest('GET', '/groups/$g2Id/members', status: 403); // invitee: no list yet
    await _rest('POST', '/groups/$g2Id/invites/$inviteId/accept');
    await _settle(tester, 600);
    await _reveal(tester, const ValueKey('members-add'));
    await _until(tester, 'peer appears in the member list live',
        () => _has(find.byKey(ValueKey('member-$_peer'))));
    await _settle(tester, 600);
    await _shot(tester, '05_peer_added_live');

    // The chat shows "<peer> joined the group".
    router.pushReplacement(AppRoutes.group(g2Id));
    await _waitForComposer(tester, 'owner chat');
    await _until(tester, 'peer join banner live', () => _has(find.text('$_peerName joined the group')));
    await _settle(tester, 800);
    await _shot(tester, '06_peer_joined_banner');

    // Remove the peer from the member actions sheet → "removed by" banner.
    router.push(AppRoutes.groupInfo(g2Id));
    await _until(tester, 'group info again', () => _has(find.byKey(const ValueKey('group-info-list'))));
    await _settle(tester, 600);
    await _reveal(tester, ValueKey('member-$_peer'));
    await tester.tap(find.byKey(ValueKey('member-$_peer')));
    await _until(tester, 'member actions', () => _has(find.byKey(const ValueKey('member-action-remove'))));
    await _settle(tester, 500);
    await tester.tap(find.byKey(const ValueKey('member-action-remove')));
    await _until(tester, 'remove confirm', () => _has(find.byKey(const ValueKey('confirm-action'))));
    await _settle(tester, 400);
    await tester.tap(find.byKey(const ValueKey('confirm-action')));
    await _until(tester, 'peer gone from the list', () => !_has(find.byKey(ValueKey('member-$_peer'))));
    await _rest('GET', '/groups/$g2Id', status: 404); // removed: undiscoverable again
    router.pop();
    await _until(tester, 'removed banner live',
        () => _has(find.text('$_peerName was removed by $_meName')));
    await _settle(tester, 800);
    await _shot(tester, '07_removed_banner');

    // Invite link → the peer joins by link → "joined the group" again.
    router.push(AppRoutes.groupInfo(g2Id));
    await _until(tester, 'group info for links', () => _has(find.byKey(const ValueKey('group-info-list'))));
    await _settle(tester, 600);
    await _reveal(tester, const ValueKey('link-create'));
    await tester.tap(find.byKey(const ValueKey('link-create')));
    await _until(tester, 'create link sheet', () => _has(find.byKey(const ValueKey('link-create-confirm'))));
    await _settle(tester, 500); // let the sheet finish sliding up
    await tester.tap(find.byKey(const ValueKey('link-create-confirm')));
    await _until(tester, 'link listed', () => _has(find.textContaining('doqto:///g/')));
    final invites = (await repo.listInvites(g2Id));
    final token = invites.firstWhere((i) => i.token != null).token!;
    final joined = (await _rest('POST', '/group-invites/$token/accept')) as Map<String, dynamic>;
    expect(joined['result'], 'joined');
    await _until(tester, 'peer back in the list via link', () => _has(find.byKey(ValueKey('member-$_peer'))));
    await _settle(tester, 600);
    await _shot(tester, '08_link_joined_live');
    router.pop();
    await _until(tester, 'second join banner live',
        () => find.text('$_peerName joined the group').evaluate().length >= 2);

    // The peer leaves → "left the group".
    await _rest('DELETE', '/groups/$g2Id/members/$_peer');
    await _until(tester, 'left banner live', () => _has(find.text('$_peerName left the group')));
    await _settle(tester, 800);
    await _shot(tester, '09_left_banner');

    final banners = await _bannersAsMe(container, g2Conv);
    expect(banners, containsAllInOrder([
      '$_peerName joined the group',
      '$_peerName was removed by $_meName',
      '$_peerName joined the group',
      '$_peerName left the group',
    ]));
    // ignore: avoid_print
    print('LIVE  0 ms  done (${banners.length} banners)');
  });
}

/// The owner's own view of the banners (the peer is no longer a member).
Future<List<String>> _bannersAsMe(ProviderContainer c, String convId) async {
  final api = c.read(apiClientProvider);
  final j = await api.getList(ApiRoutes.conversationMessages(convId));
  // The page comes newest first; return oldest first like the thread.
  return [
    for (final m in j.cast<Map<String, dynamic>>().reversed)
      if (m['type'] == 'system') (m['content'] as String? ?? ''),
  ];
}
