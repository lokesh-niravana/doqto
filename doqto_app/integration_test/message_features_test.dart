// On-device walk of batch 4 (message features): the peer writes two
// messages → the thread opens on the "2 unread messages" divider → reply
// (long-press menu, quote strip in the composer and the bubble) → star
// (bubble star, server) → pin 24 h (banner, server pinned_until) → copy
// (toast) → forward to the shared group (picker, "Forwarded" on the peer's
// side) → link preview card while composing and in the bubble → WhatsApp
// formatting renders → in-chat search with a hit counter → @mention
// autocomplete in the group composer (chip, wire token, server mentions) →
// the owner deletes my group message (admin delete) → report sheet → the
// Starred messages screen lists the star. The app signs in as
// +1 650-555-0198; the peer (+1 650-555-0199) acts over REST.
//
//   cd doqto_backend && venv/bin/python scripts/message_features_device_prep.py
//   flutter test integration_test/message_features_test.dart -d <sim> \
//     --dart-define=FIREBASE_TEST_NUMBERS=true \
//     --dart-define=API_BASE_URL=http://localhost:8010 \
//     --dart-define=WS_BASE_URL=ws://localhost:8010 \
//     --dart-define=ME_ID=… --dart-define=PEER_ID=… --dart-define=CONV_ID=… \
//     --dart-define=GROUP_CONV_ID=… --dart-define=PEER_TOKEN=… \
//     [--dart-define=SHOT_DIR=<folder on this Mac>]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';

const _me = String.fromEnvironment('ME_ID');
const _peer = String.fromEnvironment('PEER_ID');
const _conv = String.fromEnvironment('CONV_ID');
const _group = String.fromEnvironment('GROUP_CONV_ID');
const _peerToken = String.fromEnvironment('PEER_TOKEN');
const _shotDir = String.fromEnvironment('SHOT_DIR');
const _liveTimeout = Duration(seconds: 15);
const _previewUrl = 'https://en.wikipedia.org/wiki/Electrocardiography';

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/batch4_$name.png').writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<Duration> _until(WidgetTester t, String what, FutureOr<bool> Function() ready,
    {Duration timeout = _liveTimeout}) async {
  final start = DateTime.now();
  while (!await ready()) {
    if (DateTime.now().difference(start) > timeout) {
      fail('not within $timeout: $what');
    }
    await t.pump(const Duration(milliseconds: 100));
  }
  final took = DateTime.now().difference(start);
  // ignore: avoid_print
  print('LIVE  ${took.inMilliseconds} ms  $what');
  return took;
}

/// Like [_until] but gives up quietly (network-dependent steps).
Future<bool> _maybe(WidgetTester t, String what, bool Function() ready, {Duration timeout = _liveTimeout}) async {
  final start = DateTime.now();
  while (!ready()) {
    if (DateTime.now().difference(start) > timeout) {
      // ignore: avoid_print
      print('SKIP  $what did not happen within $timeout');
      return false;
    }
    await t.pump(const Duration(milliseconds: 100));
  }
  return true;
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

/// The peer's view of a message, or null when it is not in the first page.
Future<Map<String, dynamic>?> _peerSees(String convId, bool Function(Map<String, dynamic>) where) async {
  final list = (await _rest('GET', '/conversations/$convId/messages')) as List;
  for (final m in list.cast<Map<String, dynamic>>()) {
    if (where(m)) return m;
  }
  return null;
}

bool _has(Finder f) => f.evaluate().isNotEmpty;
Finder _key(String k) => find.byKey(ValueKey(k));

/// The bubble body showing [text] — not a quote strip or the pinned banner
/// that repeats the same words.
Finder _body(String text) {
  final all = find.text(text, findRichText: true);
  return find.byElementPredicate((e) {
    if (!all.evaluate().contains(e)) return false;
    var repeated = false;
    e.visitAncestorElements((a) {
      final k = a.widget.key;
      if (k == const ValueKey('quote-strip') || k == const ValueKey('pinned-banner')) {
        repeated = true;
        return false;
      }
      return true;
    });
    return !repeated;
  }, description: 'bubble body "$text"');
}

Future<void> _openMenu(WidgetTester t, String text) async {
  await t.longPress(_body(text).first);
  await _until(t, 'context menu for "$text"', () => _has(_key('message-context-menu')));
  await _settle(t, 400);
}

Future<void> _pick(WidgetTester t, String action) async {
  await t.tap(_key('ctx-$action'));
  await _until(t, 'menu closed ($action)', () => !_has(_key('message-context-menu')));
}

Future<void> _type(WidgetTester t, String text) async {
  final field = find.descendant(of: _key('composer-input'), matching: find.byType(EditableText));
  await t.tap(field);
  await _settle(t, 300);
  await t.enterText(field, text);
  await _settle(t, 300);
}

Future<void> _send(WidgetTester t, String expectBubble) async {
  await t.tap(_key('composer-send'));
  await _until(t, 'bubble "$expectBubble"', () => _has(find.text(expectBubble, findRichText: true)));
  await _settle(t, 800);
}

Future<void> _toastGone(WidgetTester t) async {
  await _until(t, 'toast gone', () => !_has(find.byType(SnackBar)));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // A sheet pushed mid-press otherwise swallows later long-presses (harness quirk).
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets(
      'unread divider → reply → star → pin → copy → forward → link preview → formatting → search → mention → admin delete → report → starred screen',
      (tester) async {
    expect(_me.isNotEmpty && _peer.isNotEmpty && _conv.isNotEmpty && _group.isNotEmpty && _peerToken.isNotEmpty, isTrue,
        reason: 'run scripts/message_features_device_prep.py and pass its dart-defines');
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
    await container.read(draftsProvider.notifier).clear(_conv);
    await container.read(draftsProvider.notifier).clear(_group);

    final repo = container.read(chatRepositoryProvider);
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    Message onScreen(String convId, bool Function(Message) where) =>
        container.read(messagesProvider(convId)).value!.firstWhere(where);

    // ---- 0. Two unread from the peer → the thread opens on the divider.
    final a = 'Walk $stamp: CT for bed 4 is up' ;
    final b = 'Walk $stamp: troponin pending, call +1 650-555-0100';
    final msgA = (await _rest('POST', '/conversations/$_conv/messages', body: {'content': a})) as Map<String, dynamic>;
    await _rest('POST', '/conversations/$_conv/messages', body: {'content': b});
    router.go(AppRoutes.chats);
    await _until(tester, 'list shows 2 unread', () {
      final c = container.read(conversationsProvider.notifier).conversation(_conv);
      return c != null && c.unreadCount >= 2;
    });
    router.push(AppRoutes.chat(_conv));
    await _until(tester, 'both peer bubbles', () => _has(find.text(a)) && _has(find.text(b, findRichText: true)));
    await _until(tester, 'unread divider', () => _has(_key('unread-divider')));
    expect(find.text(Strings.chatUnreadDivider(2)), findsOneWidget);
    await _settle(tester, 800);
    await _shot(tester, '01_unread_divider');

    // ---- 1. Reply via the long-press menu.
    await _openMenu(tester, a);
    await _shot(tester, '02_context_menu');
    expect(_has(_key('reaction-tray')), isTrue, reason: 'tray rides on top of the menu');
    for (final k in ['ctx-reply', 'ctx-forward', 'ctx-copy', 'ctx-star', 'ctx-pin', 'ctx-report', 'ctx-select']) {
      expect(_has(_key(k)), isTrue, reason: '$k on a peer text message');
    }
    expect(_has(_key('ctx-edit')), isFalse, reason: 'not mine');
    await _pick(tester, 'reply');
    await _until(tester, 'reply strip in composer', () => _has(_key('composer-reply')));
    final reply = 'Walk $stamp: seen, will call';
    await _type(tester, reply);
    await _shot(tester, '03_reply_composer');
    await _send(tester, reply);
    expect(_has(_key('composer-reply')), isFalse, reason: 'strip cleared after send');
    await _until(tester, 'server has reply_to', () async {
      final m = await _peerSees(_conv, (m) => m['content'] == reply);
      return m != null && m['reply_to_id'] == msgA['id'] && m['reply_to']?['preview'] == a;
    });
    final mine = onScreen(_conv, (m) => m.content == reply);
    expect(mine.replyTo?.id, msgA['id']);
    expect(find.byKey(const ValueKey('quote-strip')), findsWidgets, reason: 'quote shown in the bubble');
    await _shot(tester, '04_reply_bubble');

    // ---- 2. Star my reply → star glyph, private to me.
    await _openMenu(tester, reply);
    await _pick(tester, 'star');
    await _until(tester, 'bubble star', () => _has(_key('bubble-star')));
    await _until(tester, 'server starred', () async {
      final page = await repo.starred();
      return page.data.any((s) => s.message.id == mine.id);
    });
    final peerCopy = await _peerSees(_conv, (m) => m['id'] == mine.id);
    expect(peerCopy!['starred'], isFalse, reason: 'stars never leak to the other side');
    await _toastGone(tester);
    await _shot(tester, '05_starred_bubble');

    // ---- 3. Pin the peer's message for 24 h.
    await _openMenu(tester, a);
    await _pick(tester, 'pin');
    await _until(tester, 'pin duration sheet', () => _has(_key('pin-opt-duration-86400')));
    await _settle(tester, 400);
    await _shot(tester, '06_pin_sheet');
    await tester.tap(_key('pin-opt-duration-86400'));
    await _until(tester, 'pinned banner', () => _has(_key('pinned-banner')));
    expect(tester.widget<Text>(_key('pinned-banner-text')).data, a);
    await _until(tester, 'server pinned', () async {
      final list = (await _rest('GET', '/conversations')) as List;
      final c = list.cast<Map<String, dynamic>>().firstWhere((c) => c['id'] == _conv);
      if (c['pinned_message_id'] != msgA['id'] || c['pinned_until'] == null) return false;
      final left = DateTime.parse(c['pinned_until'] as String).difference(DateTime.now().toUtc());
      return left.inMinutes >= 1430 && left.inMinutes <= 1441;
    });
    await _toastGone(tester);
    await _shot(tester, '07_pinned_banner');

    // ---- 4. Copy → toast; the pasteboard holds the text.
    await _openMenu(tester, b);
    await _pick(tester, 'copy');
    await _until(tester, 'copied toast', () => _has(find.text(Strings.chatCopied)));
    await _shot(tester, '08_copied');
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clip?.text, b);
    await _toastGone(tester);

    // ---- 5. Forward the peer's message to the shared group.
    await _openMenu(tester, a);
    await _pick(tester, 'forward');
    await _until(tester, 'forward picker', () => _has(_key('forward-picker')));
    await _until(tester, 'group row in picker', () => _has(_key('forward-target-$_group')));
    await tester.tap(_key('forward-target-$_group'));
    await _until(tester, 'count 1/5', () => _has(find.text('1/5')));
    await _settle(tester, 400);
    await _shot(tester, '09_forward_picker');
    await tester.tap(_key('forward-confirm'));
    await _until(tester, 'forwarded toast', () => _has(find.text(Strings.chatForwardedToast)));
    await _until(tester, 'peer sees the forward in the group', () async {
      final m = await _peerSees(_group, (m) => m['content'] == a && m['sender_id'] == _me);
      return m != null && m['forwarded'] == true && m['forward_depth'] == 1;
    });
    await _toastGone(tester);

    // ---- 6. Link preview: card while composing, card in the bubble.
    final linkText = 'Walk $stamp: protocol $_previewUrl';
    await _type(tester, linkText);
    final previewShown = await _maybe(tester, 'composer link preview', () => _has(_key('composer-link-preview')),
        timeout: const Duration(seconds: 20));
    await _settle(tester, 400);
    await _shot(tester, '10_composer_preview');
    await _send(tester, linkText);
    if (previewShown) {
      await _until(tester, 'bubble link preview', () => _has(_key('link-preview')));
    }
    await _settle(tester, 600);
    await _shot(tester, '11_link_bubble');

    // ---- 7. WhatsApp formatting renders without the markers.
    final fmt = 'Walk $stamp: *bold* _italic_ ~strike~ `mono`';
    await _type(tester, fmt);
    await _send(tester, 'Walk $stamp: bold italic strike mono');
    expect(find.text(fmt, findRichText: true), findsNothing, reason: 'markers hidden');
    final fmtMsg = await _peerSees(_conv, (m) => m['content'] == fmt);
    expect(fmtMsg, isNotNull, reason: 'raw markers go on the wire');
    await _shot(tester, '12_formatting');

    // ---- 8. In-chat search: hit counter, highlight.
    await tester.tap(_key('thread-search'));
    await _until(tester, 'search bar', () => _has(_key('thread-search-field')));
    final searchField = find.descendant(of: _key('thread-search-field'), matching: find.byType(EditableText));
    await tester.tap(searchField);
    // Earlier walks left their own "troponin" lines; the stamp keeps it to one hit.
    await tester.enterText(searchField, '$stamp: troponin');
    await _until(tester, 'hit counter', () => _has(_key('search-counter')) && _has(find.text('1/1')));
    await _settle(tester, 600);
    await _shot(tester, '13_search');
    await tester.enterText(searchField, 'Walk $stamp');
    await _until(tester, 'several hits', () {
      final t = _key('search-counter');
      if (!_has(t)) return false;
      final s = (tester.widget<Text>(t).data ?? '');
      return s.endsWith('/5') || s.endsWith('/6');
    });
    await tester.tap(_key('search-older'));
    await _settle(tester, 600);
    await _shot(tester, '14_search_step');
    await tester.tap(_key('search-close'));
    await _until(tester, 'search closed', () => !_has(_key('thread-search-field')));

    // ---- 9. @mention in the group composer → chip → wire token → server mentions.
    router.pop();
    await _settle(tester, 800);
    router.push(AppRoutes.chat(_group));
    await _until(tester, 'group composer', () => _has(_key('composer-input')));
    await _settle(tester, 800);
    await _type(tester, 'Walk $stamp: @Demo');
    await _until(tester, 'mention autocomplete', () => _has(_key('mention-$_peer')));
    await _shot(tester, '15_mention_autocomplete');
    await tester.tap(_key('mention-$_peer'));
    await _settle(tester, 400);
    expect(_has(find.textContaining('@Demo Reviewer')), isTrue, reason: 'chip shows the name');
    expect(_has(_key('mention-autocomplete')), isFalse, reason: 'closes after the pick');
    await _shot(tester, '16_mention_chip');
    await tester.tap(_key('composer-send'));
    await _until(tester, 'server has the mention', () async {
      final m = await _peerSees(_group, (m) => (m['content'] as String? ?? '').startsWith('Walk $stamp: @['));
      return m != null && (m['mentions'] as List).contains(_peer);
    });
    // The chip span carries a semantics label, so compare the visible text.
    await _until(tester, 'chip in the bubble', () => _has(find.byWidgetPredicate((w) =>
        w is RichText && w.text.toPlainText(includeSemanticsLabels: false) == 'Walk $stamp: @Demo Reviewer')));
    await _settle(tester, 600);
    await _shot(tester, '17_mention_bubble');

    // ---- 10. The owner deletes my group message (admin delete) → tombstone here.
    final mentionMsg = onScreen(_group, (m) => m.senderId == _me && (m.content ?? '').startsWith('Walk $stamp: @['));
    await _rest('DELETE', '/messages/${mentionMsg.id}');
    await _until(tester, 'tombstone after admin delete',
        () => onScreen(_group, (m) => m.id == mentionMsg.id).isDeleted);
    await _settle(tester, 600);
    await _shot(tester, '18_admin_deleted');

    // ---- 11. Report the forwarded message? No — report the peer's own note.
    final peerNote = 'Walk $stamp: group note from the owner';
    await _rest('POST', '/conversations/$_group/messages', body: {'content': peerNote});
    await _until(tester, 'peer group note', () => _has(find.text(peerNote)));
    await _settle(tester, 400);
    await _openMenu(tester, peerNote);
    expect(_has(_key('ctx-pin')), isFalse, reason: 'plain members cannot pin in a group');
    await _pick(tester, 'report');
    await _until(tester, 'report sheet', () => _has(_key('report-sheet')));
    await tester.tap(_key('report-reason-spam'));
    final details = find.descendant(of: _key('report-details'), matching: find.byType(EditableText));
    await tester.tap(details);
    await tester.enterText(details, 'Device walk report #$stamp');
    await _settle(tester, 400);
    await _shot(tester, '19_report_sheet');
    // Keyboard rule: a tap on the title drops the keypad.
    await tester.tap(find.text(Strings.chatReportTitle));
    await _settle(tester, 400);
    await tester.tap(_key('report-submit'));
    await _until(tester, 'reported toast', () => _has(find.text(Strings.chatReportedToast)));
    await _toastGone(tester);

    // ---- 12. Starred messages screen lists the star, tap jumps to it.
    router.push(AppRoutes.starred);
    await _until(tester, 'starred row', () => _has(_key('starred-row-${mine.id}')));
    await _settle(tester, 600);
    await _shot(tester, '20_starred_screen');
    await tester.tap(_key('starred-row-${mine.id}'));
    await _until(tester, 'thread at the starred message', () => _has(find.text(reply, findRichText: true)));
    await _settle(tester, 800);
    await _shot(tester, '21_jump_from_starred');

    // ---- 13. Unstar from the menu → glyph gone; unpin from the banner → banner gone.
    await _openMenu(tester, reply);
    expect(_has(_key('ctx-unstar')), isTrue);
    await _pick(tester, 'unstar');
    await _until(tester, 'star glyph gone', () => !_has(_key('bubble-star')));
    await _until(tester, 'server unstarred', () async => !(await repo.starred()).data.any((s) => s.message.id == mine.id));
    await _toastGone(tester);
    await tester.tap(_key('pinned-banner-unpin'));
    await _until(tester, 'banner gone', () => !_has(_key('pinned-banner')));
    await _toastGone(tester);
    await _shot(tester, '22_unpinned');
  });
}
