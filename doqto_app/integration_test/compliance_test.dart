// On-device walk of batch 7 (compliance) as an org admin, against the local
// API: My Org shows the admin tools → Policies screen → Copy is on the
// long-press menu of an org chat → admin turns allow_copy off → Copy is gone
// (the peer reads the same policy as a member over REST) → legal hold on
// (confirm dialog) → delete-for-everyone of my message → an access request
// filed from the picker → the peer (second admin) approves over REST → the
// card flips live → the audited view shows the held message's content and
// the REST read returns it → the peer files a report → Reports screen,
// status change → a scheduled message is listed from the thread menu and
// cancelled. The app signs in as +1 650-555-0198; the peer acts over REST.
//
//   cd doqto_backend && venv/bin/python scripts/compliance_device_prep.py
//   flutter test integration_test/compliance_test.dart -d <sim> --ignore-timeouts \
//     --dart-define=FIREBASE_TEST_NUMBERS=true \
//     --dart-define=API_BASE_URL=http://localhost:8010 \
//     --dart-define=WS_BASE_URL=ws://localhost:8010 \
//     --dart-define=ME_ID=… --dart-define=PEER_ID=… --dart-define=ORG_ID=… \
//     --dart-define=CONV_ID=… --dart-define=ORG_CONV_ID=… --dart-define=PEER_TOKEN=… \
//     [--dart-define=SHOT_DIR=<folder on this Mac>]
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
import 'package:doqto_app/data/models/compliance.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/compliance_state.dart';

const _me = String.fromEnvironment('ME_ID');
const _peer = String.fromEnvironment('PEER_ID');
const _org = String.fromEnvironment('ORG_ID');
const _conv = String.fromEnvironment('CONV_ID');
const _orgConv = String.fromEnvironment('ORG_CONV_ID');
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
  await File('$_shotDir/batch7_$name.png').writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _until(WidgetTester t, String what, FutureOr<bool> Function() ready,
    {Duration timeout = _liveTimeout}) async {
  final start = DateTime.now();
  while (!await ready()) {
    if (DateTime.now().difference(start) > timeout) fail('not within $timeout: $what');
    await t.pump(const Duration(milliseconds: 100));
  }
  // ignore: avoid_print
  print('LIVE  ${DateTime.now().difference(start).inMilliseconds} ms  $what');
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

/// The peer's REST call; fails the test on a non-2xx.
Future<Object?> _rest(String method, String path, {Map<String, dynamic>? body}) async {
  final (status, json) = await _restRaw(method, path, body: body);
  if (status < 200 || status >= 300) fail('$method $path → $status $json');
  return json;
}

bool _has(Finder f) => f.evaluate().isNotEmpty;
Finder _key(String k) => find.byKey(ValueKey(k));

Future<void> _openMenu(WidgetTester t, String text) async {
  await t.longPress(find.text(text, findRichText: true).first);
  await _until(t, 'context menu for "$text"', () => _has(_key('message-context-menu')));
  await _settle(t, 400);
}

Future<void> _type(WidgetTester t, String text) async {
  final field = find.descendant(of: _key('composer-input'), matching: find.byType(EditableText));
  await t.tap(field);
  await _settle(t, 300);
  await t.enterText(field, text);
  await _settle(t, 300);
}

Future<void> _scrollTo(WidgetTester t, String listKey, Finder target) async {
  await t.scrollUntilVisible(target, 120,
      scrollable: find.descendant(of: _key(listKey), matching: find.byType(Scrollable)));
  await _settle(t, 400);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets(
      'admin tools → policies → allow_copy hides Copy → legal hold → break-glass → reports → scheduled',
      (tester) async {
    expect(
        _me.isNotEmpty && _peer.isNotEmpty && _org.isNotEmpty && _conv.isNotEmpty &&
            _orgConv.isNotEmpty && _peerToken.isNotEmpty,
        isTrue,
        reason: 'run scripts/compliance_device_prep.py and pass its dart-defines');
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
    await container.read(draftsProvider.notifier).clear(_orgConv);
    final compliance = container.read(complianceRepositoryProvider);
    final chat = container.read(chatRepositoryProvider);
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;

    // Flat start for the policies this walk flips (the prep also resets them).
    await compliance.patchPolicies(_org, {'allow_copy': true, 'legal_hold': false});

    // ---- 1. My Org shows the admin tools; Policies opens.
    router.go(AppRoutes.myOrg);
    await _until(tester, 'admin tools on My Org', () => _has(_key('my-org-policies')));
    expect(_has(_key('my-org-access-requests')), isTrue);
    expect(_has(_key('my-org-reports')), isTrue);
    expect(container.read(isOrgAdminProvider), isTrue);
    await _settle(tester, 600);
    await _shot(tester, '01_my_org_admin');
    await tester.tap(_key('my-org-policies'));
    await _until(tester, 'policies screen', () => _has(_key('policy-switch-allow_copy')));
    expect(tester.widget<SwitchListTile>(_key('policy-switch-allow_copy')).value, isTrue);
    await _settle(tester, 600);
    await _shot(tester, '02_policies');
    router.pop();
    await _settle(tester, 500);

    // ---- 2. Copy is offered in an org chat while allow_copy is on.
    final note = 'Walk $stamp: handover note';
    await _rest('POST', '/conversations/$_orgConv/messages', body: {'content': note});
    router.push(AppRoutes.chat(_orgConv));
    await _until(tester, 'peer note in the org chat', () => _has(find.text(note, findRichText: true)));
    await _settle(tester, 600);
    await _openMenu(tester, note);
    expect(_has(_key('ctx-copy')), isTrue, reason: 'allow_copy=true');
    await _shot(tester, '03_copy_allowed');
    router.pop(); // the menu
    await _until(tester, 'menu closed', () => !_has(_key('message-context-menu')));
    router.pop(); // the thread
    await _settle(tester, 500);

    // ---- 3. Admin turns allow_copy off → Copy disappears; the peer reads
    //         the same policy as a member would.
    router.push(AppRoutes.myOrgPolicies);
    await _until(tester, 'policies screen', () => _has(_key('policy-switch-allow_copy')));
    await tester.tap(_key('policy-switch-allow_copy'));
    await _until(tester, 'server has allow_copy=false', () async {
      final p = (await _rest('GET', '/orgs/$_org/policies')) as Map<String, dynamic>;
      return p['allow_copy'] == false;
    });
    expect(container.read(currentOrgPoliciesProvider).allowCopy, isFalse);
    await _settle(tester, 400);
    await _shot(tester, '04_allow_copy_off');
    router.pop();
    await _settle(tester, 400);
    router.push(AppRoutes.chat(_orgConv));
    await _until(tester, 'org chat again', () => _has(find.text(note, findRichText: true)));
    await _settle(tester, 600);
    await _openMenu(tester, note);
    expect(_has(_key('ctx-copy')), isFalse, reason: 'allow_copy=false hides Copy');
    expect(_has(_key('ctx-reply')), isTrue);
    await _shot(tester, '05_copy_hidden');
    router.pop();
    await _until(tester, 'menu closed', () => !_has(_key('message-context-menu')));

    // ---- 4. My message, then legal hold on (confirm dialog), then
    //         delete-for-everyone: members see a bare tombstone.
    final held = 'Walk $stamp: keep this under hold';
    await _type(tester, held);
    await tester.tap(_key('composer-send'));
    await _until(tester, 'my bubble', () => _has(find.text(held, findRichText: true)));
    Message mine() => container.read(messagesProvider(_orgConv)).value!.firstWhere((m) => m.content == held);
    await _until(tester, 'server ack', () => mine().seq != null);
    final heldId = mine().id;
    router.pop();
    await _settle(tester, 400);

    router.push(AppRoutes.myOrgPolicies);
    await _until(tester, 'policies screen', () => _has(_key('policies-list')));
    await _scrollTo(tester, 'policies-list', _key('policy-switch-legal_hold'));
    await tester.tap(_key('policy-switch-legal_hold'));
    await _until(tester, 'legal hold confirm', () => _has(find.text(Strings.orgPolicyLegalHoldOnTitle)));
    await _settle(tester, 400);
    await _shot(tester, '06_legal_hold_confirm');
    await tester.tap(_key('policy-confirm-ok'));
    await _until(tester, 'server has legal_hold=true', () async {
      final p = (await _rest('GET', '/orgs/$_org/policies')) as Map<String, dynamic>;
      return p['legal_hold'] == true;
    });
    await _until(tester, 'hold note', () => _has(_key('policy-legal-hold-note')));
    await _settle(tester, 400);
    await _shot(tester, '07_legal_hold_on');
    router.pop();
    await _settle(tester, 400);

    await chat.deleteMessage(heldId);
    await _until(tester, 'peer sees a tombstone without content', () async {
      final list = (await _rest('GET', '/conversations/$_orgConv/messages')) as List;
      final m = list.cast<Map<String, dynamic>>().where((m) => m['id'] == heldId).firstOrNull;
      return m != null && m['deleted_at'] != null && (m['content'] == null || m['content'] == '');
    });

    // ---- 5. Break-glass: file from the picker, the peer approves over
    //         REST, the card flips live, the audited view shows the held text.
    router.push(AppRoutes.myOrgAccessRequests);
    await _until(tester, 'access requests screen', () => _has(_key('access-request-new')));
    await _settle(tester, 400);
    await tester.tap(_key('access-request-new'));
    await _until(tester, 'create sheet', () => _has(_key('access-request-sheet')));
    await tester.tap(_key('access-request-pick'));
    await _until(tester, 'picker', () => _has(_key('access-request-picker')));
    await _until(tester, 'org chat in picker', () => _has(_key('access-request-pick-$_orgConv')));
    await tester.tap(_key('access-request-pick-$_orgConv'));
    await _until(tester, 'picked', () => _has(_key('access-request-picked')));
    final reasonField = find.descendant(of: _key('access-request-reason'), matching: find.byType(EditableText));
    await tester.tap(reasonField);
    await _settle(tester, 300);
    await tester.enterText(reasonField, 'Device walk $stamp: complaint review');
    await _settle(tester, 300);
    // Keyboard rule: tapping the sheet title drops the keypad.
    await tester.tap(find.descendant(of: _key('access-request-sheet'), matching: find.text(Strings.accessRequestNew)));
    await _settle(tester, 400);
    await _shot(tester, '08_access_request_sheet');
    await tester.tap(_key('access-request-submit'));
    await _until(tester, 'sheet closed', () => !_has(_key('access-request-sheet')));
    AccessRequest? request() => container
        .read(accessRequestsProvider(_org))
        .asData
        ?.value
        .where((r) => r.conversationId == _orgConv && r.status == AccessRequestStatus.pending)
        .firstOrNull;
    await _until(tester, 'pending card', () => request() != null && _has(_key('access-request-card-${request()!.id}')));
    final requestId = request()!.id;
    expect(_has(find.text(Strings.accessRequestAwaitingOther)), isTrue);
    expect(_has(_key('access-request-approve-$requestId')), isFalse, reason: 'cannot approve my own');
    await _settle(tester, 600);
    await _shot(tester, '09_access_request_pending');

    await _rest('POST', '/orgs/$_org/access-requests/$requestId/approve');
    await _until(tester, 'card flips to approved (WS access_request_updated)',
        () => _has(_key('access-request-open-$requestId')));
    await _settle(tester, 600);
    await _shot(tester, '10_access_request_approved');

    await _until(tester, 'toast gone', () => !_has(find.byType(SnackBar)));
    await tester.tap(_key('access-request-open-$requestId'));
    await _until(tester, 'audited view', () => _has(_key('break-glass-banner')));
    await _until(tester, 'held message in the audited view', () => _has(_key('break-glass-row-$heldId')));
    expect(_has(_key('break-glass-deleted-$heldId')), isTrue, reason: 'marked as a held tombstone');
    expect(_has(find.text(held)), isTrue, reason: 'content kept under legal hold');
    await _settle(tester, 600);
    await _shot(tester, '11_break_glass_view');
    // The REST read behind the view returns the content the members no longer get.
    final page = await compliance.accessRequestMessages(_org, requestId);
    final heldRow = page.data.firstWhere((m) => m.id == heldId);
    expect(heldRow.isDeleted, isTrue);
    expect(heldRow.content, held);
    await _until(tester, 'members were told', () async {
      final list = (await _rest('GET', '/conversations/$_orgConv/messages')) as List;
      return list.cast<Map<String, dynamic>>().any((m) =>
          m['type'] == 'system' && (m['content'] as String? ?? '').contains('administrator accessed'));
    });
    router.pop();
    await _settle(tester, 400);
    router.pop();
    await _settle(tester, 400);

    // ---- 6. Reports: the peer reports me; the admin moves it to Reviewing.
    final reportDetails = 'Device walk $stamp: org report';
    await _rest('POST', '/network/reports', body: {
      'subject_type': 'user',
      'subject_id': _me,
      'reason': 'harassment',
      'details': reportDetails,
    });
    // POST answers {ok}; the org queue (peer is an admin too) has the id.
    final open = (await _rest('GET', '/orgs/$_org/reports?status=open')) as List;
    final reportId =
        open.cast<Map<String, dynamic>>().firstWhere((r) => r['details'] == reportDetails)['id'] as String;
    router.push(AppRoutes.myOrgReports);
    await _until(tester, 'report card', () => _has(_key('report-$reportId')));
    await _settle(tester, 600);
    await _shot(tester, '12_reports');
    await tester.tap(_key('report-$reportId'));
    await _until(tester, 'status sheet', () => _has(_key('report-opt-status-reviewing')));
    await _settle(tester, 400);
    await _shot(tester, '13_report_status_sheet');
    await tester.tap(_key('report-opt-status-reviewing'));
    await _until(tester, 'server has reviewing', () async {
      final list = (await _rest('GET', '/orgs/$_org/reports?status=reviewing')) as List;
      return list.cast<Map<String, dynamic>>().any((r) => r['id'] == reportId);
    });
    await tester.tap(_key('reports-filter-reviewing'));
    await _until(tester, 'filtered to reviewing', () => _has(_key('report-$reportId')));
    await _settle(tester, 600);
    await _shot(tester, '14_report_reviewing');
    router.pop();
    await _settle(tester, 400);

    // ---- 7. Scheduled messages: listed from the thread menu, cancelled.
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final wall = '${tomorrow.year.toString().padLeft(4, '0')}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}T09:00:00';
    await chat.scheduleText(_conv, 'Walk $stamp: scheduled', scheduledLocal: wall, timezone: 'UTC');
    final scheduledBefore = await compliance.scheduled(_conv);
    expect(scheduledBefore, isNotEmpty);
    final scheduledId = scheduledBefore.first.id;
    router.push(AppRoutes.chat(_conv));
    await _until(tester, 'dm composer', () => _has(_key('composer-input')));
    await _settle(tester, 600);
    await tester.tap(_key('thread-more'));
    await _until(tester, 'thread menu', () => _has(_key('thread-menu-scheduled')));
    await _settle(tester, 300);
    await _shot(tester, '15_thread_menu');
    await tester.tap(_key('thread-menu-scheduled'));
    await _until(tester, 'scheduled row', () => _has(_key('scheduled-row-$scheduledId')));
    await _settle(tester, 600);
    await _shot(tester, '16_scheduled_sheet');
    await tester.tap(_key('scheduled-cancel-$scheduledId'));
    await _until(tester, 'row gone', () => !_has(_key('scheduled-row-$scheduledId')));
    await _until(tester, 'server has no pending row', () async => (await compliance.scheduled(_conv)).isEmpty);
    await _until(tester, 'empty state', () => _has(_key('scheduled-empty')));
    await _settle(tester, 600);
    await _shot(tester, '17_scheduled_cancelled');
    router.pop(); // sheet
    await _settle(tester, 400);
    router.pop(); // thread
    await _settle(tester, 400);

    // ---- 8. The member's read of the policies (peer over REST) matches what
    //         the admin set; then restore so the next walk starts flat.
    final peerView = (await _rest('GET', '/orgs/$_org/policies')) as Map<String, dynamic>;
    expect(peerView['allow_copy'], isFalse);
    expect(peerView['legal_hold'], isTrue);
    await compliance.patchPolicies(_org, {'allow_copy': true, 'legal_hold': false});
    await _settle(tester, 800);
  });
}
