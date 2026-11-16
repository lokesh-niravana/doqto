// Simulator walk (2026-11-09): profile pictures and the pending-invites list.
//
// 1. Pictures: the peer and I each upload a profile photo. Opening our DM
//    must show the peer's picture in the thread header, in the chat list and
//    on Chat details, and a list refresh must not blink it back to initials.
//    Avatars now load from the stable, authenticated API URL (see
//    core/utils/avatar_urls.dart) instead of five-minute presigned links.
// 2. Invites: after Add members sends an invite, Group info lists it under
//    "Pending invites" with the person's name; it disappears live when they
//    accept, and Cancel invite revokes it.
// 3. Crop: the crop step the photo pickers now go through returns a file.
//
// Run with scripts/groups_device_prep.py's dart-defines (ME_ID, PEER_ID,
// PEER_TOKEN) plus SHOT_DIR (absolute Mac path).

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/groups_state.dart';
import 'package:doqto_app/ui/screens/media/image_crop_screen.dart';
import 'package:doqto_app/ui/widgets/doctor_avatar.dart';

const _me = String.fromEnvironment('ME_ID');
const _peer = String.fromEnvironment('PEER_ID');
const _peerToken = String.fromEnvironment('PEER_TOKEN');
const _shotDir = String.fromEnvironment('SHOT_DIR');
const _liveTimeout = Duration(seconds: 15);
const _peerName = 'Demo Reviewer';

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/av_$name.png').writeAsBytes(png!.buffer.asUint8List());
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

bool _has(Finder f) => f.evaluate().isNotEmpty;

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

/// A 256×256 PNG: solid disc on white with a letter, so a loaded picture is
/// obvious in screenshots and distinct from the initials fallback.
Future<List<int>> _png(Color color, String letter) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, 256, 256), Paint()..color = Colors.white);
  c.drawCircle(const Offset(128, 128), 120, Paint()..color = color);
  final tp = TextPainter(
    text: TextSpan(text: letter, style: const TextStyle(color: Colors.white, fontSize: 140, fontWeight: FontWeight.bold)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, Offset(128 - tp.width / 2, 128 - tp.height / 2));
  final img = await rec.endRecording().toImage(256, 256);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// multipart/form-data POST /users/me/avatar as the peer.
Future<void> _peerUploadsAvatar(List<int> png) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('${AppConstants.apiBaseUrl}/api/v1/users/me/avatar'));
    const boundary = 'doqtoWalkBoundary7f3a';
    req.headers.set('Authorization', 'Bearer $_peerToken');
    req.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
    final head = utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="peer.png"\r\nContent-Type: image/png\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    req.contentLength = head.length + png.length + tail.length;
    req.add(head);
    req.add(png);
    req.add(tail);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) fail('peer avatar upload → ${res.statusCode} $text');
  } finally {
    client.close();
  }
}

/// Every [DoctorAvatar] on screen that points at [userId]'s API picture and
/// is actually painting bitmap pixels (not the initials placeholder).
int _picturesShownFor(String userId) {
  var n = 0;
  for (final el in find.byType(DoctorAvatar).evaluate()) {
    final w = el.widget as DoctorAvatar;
    final url = w.imageUrl ?? '';
    if (!url.contains('/users/$userId/avatar')) continue;
    if (_has(find.descendant(of: find.byWidget(w), matching: find.byType(RawImage)))) n++;
  }
  return n;
}

Future<void> _waitForComposer(WidgetTester t, String what) => _until(
    t,
    what,
    () =>
        _has(find.byKey(const ValueKey('composer-idle-empty'))) ||
        _has(find.byKey(const ValueKey('composer-idle'))));

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('profile pictures survive refresh; pending invites are listed; crop returns a file',
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
    final tmp = await getTemporaryDirectory();

    // =====================================================================
    // 1. Profile pictures.
    // =====================================================================
    await _peerUploadsAvatar(await _png(const Color(0xFFE0633A), 'D'));
    final myFile = File('${tmp.path}/me_$stamp.png')..writeAsBytesSync(await _png(const Color(0xFF1D6FD1), 'S'));
    final updatedMe = await container.read(userRepositoryProvider).uploadAvatar(myFile);
    auth.setUser(updatedMe);
    expect(updatedMe.avatarUrl, isNotNull);

    // The DM with the peer (created if this device never had one).
    final conv = await container.read(chatRepositoryProvider).createConversation(
          type: ConversationType.direct,
          memberIds: [_peer],
        );
    await container.read(conversationsProvider.notifier).refresh();
    await _settle(tester, 800);

    router.push(AppRoutes.chat(conv.id));
    await _waitForComposer(tester, 'thread open');
    final header = find.byType(DoctorAvatar).first;
    expect((tester.widget<DoctorAvatar>(header)).imageUrl, contains('/users/$_peer/avatar'),
        reason: 'the header asks the API, not a presigned link');
    await _until(tester, 'peer picture painted in the thread header', () => _picturesShownFor(_peer) >= 1);
    await _settle(tester, 600);
    await _shot(tester, '01_thread_header_picture');

    // Chat details: the big avatar.
    router.push(AppRoutes.chatDetails(conv.id));
    await _until(tester, 'peer picture on chat details', () => _picturesShownFor(_peer) >= 1);
    await _settle(tester, 600);
    await _shot(tester, '02_chat_details_picture');
    router.pop();
    await _settle(tester, 300);
    router.pop();
    await _settle(tester, 800);

    // Chat list row, then a refresh: the picture must never blink out.
    await _until(tester, 'peer picture in the chat list', () => _picturesShownFor(_peer) >= 1);
    await _shot(tester, '03_chat_list_picture');
    final refreshing = container.read(conversationsProvider.notifier).refresh();
    var dropped = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (_picturesShownFor(_peer) == 0) dropped = true;
    }
    await refreshing;
    expect(dropped, isFalse, reason: 'a refresh re-presigns nothing now; the cached picture stays');
    expect(_picturesShownFor(_peer), greaterThanOrEqualTo(1));

    // My own picture in Settings.
    router.push(AppRoutes.settings);
    await _until(tester, 'my picture in settings', () => _picturesShownFor(_me) >= 1);
    await _settle(tester, 600);
    await _shot(tester, '04_settings_my_picture');
    router.pop();
    await _settle(tester, 400);

    // =====================================================================
    // 2. Pending invites in Group info.
    // =====================================================================
    final repo = container.read(groupsRepositoryProvider);
    final g = await repo.createGroup(name: 'Picture round $stamp', description: 'Pending invites');
    router.push(AppRoutes.groupInfo(g.id));
    await _until(tester, 'owner group info', () => _has(find.text('Picture round $stamp')));
    await _settle(tester, 600);
    expect(find.textContaining(Strings.groupPendingInvitesLabel), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('members-add')), 200,
        scrollable: find.descendant(of: find.byKey(const ValueKey('group-info-list')), matching: find.byType(Scrollable)),
        maxScrolls: 30);
    await _settle(tester, 400);
    await tester.tap(find.byKey(const ValueKey('members-add')));
    await _until(tester, 'add members sheet', () => _has(find.byKey(const ValueKey('add-members-search'))));
    await _until(tester, 'peer offered', () => _has(find.byKey(ValueKey('add-$_peer'))));
    await tester.tap(find.byKey(ValueKey('add-$_peer')));
    await _settle(tester, 400);
    await tester.tap(find.byKey(const ValueKey('add-members-invite')));
    await _until(tester, 'sheet closed', () => !_has(find.byKey(const ValueKey('add-members-search'))));

    // The invite shows at once, with the person's name and a Cancel control.
    await _until(tester, 'pending invite listed', () => _has(find.text('${Strings.groupPendingInvitesLabel} (1)')));
    final invites = await repo.listInvites(g.id);
    final direct = invites.where((i) => i.isDirect).toList();
    expect(direct, hasLength(1));
    expect(direct.single.inviteeName, _peerName, reason: 'the server names the invitee');
    await tester.scrollUntilVisible(find.byKey(ValueKey('invite-cancel-${direct.single.id}')), 200,
        scrollable: find.descendant(of: find.byKey(const ValueKey('group-info-list')), matching: find.byType(Scrollable)),
        maxScrolls: 30);
    await _settle(tester, 500);
    expect(find.descendant(of: find.byKey(ValueKey('invite-${direct.single.id}')), matching: find.text(_peerName)), findsOneWidget);
    await _shot(tester, '05_pending_invite_listed');

    // The peer accepts → the row leaves the pending list and joins the members, live.
    await _rest('POST', '/groups/${g.id}/invites/${direct.single.id}/accept');
    await _until(tester, 'pending list gone after accept',
        () => !_has(find.textContaining(Strings.groupPendingInvitesLabel)));
    await _until(tester, 'peer in the member list live', () => _has(find.byKey(ValueKey('member-$_peer'))));
    await _settle(tester, 600);
    await _shot(tester, '06_accepted_moves_to_members');
    router.pop();
    await _settle(tester, 400);

    // Cancel invite: a second group, invite, cancel → the peer can no longer see it.
    final g2 = await repo.createGroup(name: 'Cancel round $stamp', description: 'Cancel invite');
    await container.read(groupDetailProvider(g2.id).notifier).invite(_peer);
    router.push(AppRoutes.groupInfo(g2.id));
    await _until(tester, 'second group info', () => _has(find.text('Cancel round $stamp')));
    await _until(tester, 'pending invite listed (2nd)', () => _has(find.text('${Strings.groupPendingInvitesLabel} (1)')));
    await _rest('GET', '/groups/${g2.id}', status: 200); // invitee sees the card
    final i2 = (await repo.listInvites(g2.id)).firstWhere((i) => i.isDirect);
    await tester.scrollUntilVisible(find.byKey(ValueKey('invite-cancel-${i2.id}')), 200,
        scrollable: find.descendant(of: find.byKey(const ValueKey('group-info-list')), matching: find.byType(Scrollable)),
        maxScrolls: 30);
    await _settle(tester, 500);
    await tester.tap(find.byKey(ValueKey('invite-cancel-${i2.id}')));
    await _until(tester, 'cancelled invite gone', () => !_has(find.byKey(ValueKey('invite-${i2.id}'))));
    await _until(tester, 'cancel toast', () => _has(find.text(Strings.groupInviteCancelled)));
    await _settle(tester, 600);
    await _rest('GET', '/groups/${g2.id}', status: 404); // undiscoverable again
    await _shot(tester, '07_invite_cancelled');
    router.pop();
    await _settle(tester, 400);

    // =====================================================================
    // 3. Crop step.
    // =====================================================================
    final src = File('${tmp.path}/crop_$stamp.png')..writeAsBytesSync(await _png(const Color(0xFF2F7D4F), 'C'));
    final ctx = router.routerDelegate.navigatorKey.currentContext!;
    // ignore: use_build_context_synchronously
    final cropping = showImageCrop(ctx, src, circle: true, title: 'Adjust photo');
    await _until(tester, 'crop screen', () => _has(find.byKey(const ValueKey('crop-done'))));
    await _settle(tester, 1200);
    await _shot(tester, '08_crop_screen');
    await tester.tap(find.byKey(const ValueKey('crop-done')));
    File? cropped;
    cropping.then((f) => cropped = f);
    await _until(tester, 'crop result', () => cropped != null);
    expect(cropped!.existsSync(), isTrue);
    expect(cropped!.lengthSync(), greaterThan(0));
    await _settle(tester, 600);
  });
}
