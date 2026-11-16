// On-device check of message edit/delete against a live local backend.
// Signs in as the Firebase test number +1 650-555-0198 (OTP 654321), like
// the newer walks; any prep script that prints CONV_ID for that user's DM
// (e.g. scripts/compliance_device_prep.py) sets it up.
//
// Run (backend on :8010):
//   flutter test integration_test/message_edit_delete_test.dart -d <sim> \
//     --dart-define=FIREBASE_TEST_NUMBERS=true \
//     --dart-define=API_BASE_URL=http://localhost:8010 \
//     --dart-define=WS_BASE_URL=ws://localhost:8010 \
//     --dart-define=CONV_ID=<conversation uuid>
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/ui/widgets/message_bubble.dart';

const _conv = String.fromEnvironment('CONV_ID');

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Long-press → the batch-4 context sheet. The key appears while the sheet is
/// still sliding in, so settle before anything in it is tapped.
Future<void> _openMenu(WidgetTester t, Finder bubbleText) async {
  await t.longPress(bubbleText);
  await _settle(t, 800);
  expect(find.byKey(const ValueKey('message-context-menu')), findsOneWidget);
}

Future<void> _pick(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await _settle(t, 300);
  await t.tap(find.byKey(ValueKey(key)));
  await _settle(t, 800);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // A route pushed mid-press (the long-press sheet) makes Navigator cancel the
  // pointer as a *device* event; without this the live binding drops it and
  // the bubble's long-press recognizer never resets.
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('edit shows history, delete shows tombstone', (tester) async {
    expect(_conv, isNotEmpty, reason: 'pass --dart-define=CONV_ID');
    await app.main();
    await _settle(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final auth = container.read(authProvider.notifier);
    if (container.read(authProvider).stage != AuthStage.signedIn) {
      final challenge = await auth.startPhoneSignIn('+16505550198');
      await auth.confirmPhoneCode(challenge, '654321');
    }
    await _settle(tester);
    expect(container.read(authProvider).stage, AuthStage.signedIn);
    // The XCTest host leaves the app `inactive`; act like a foreground app.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester, 1000);

    container.read(routerProvider).go(AppRoutes.chat(_conv));
    await _settle(tester, 2500);

    final unique = 'sim ${DateTime.now().millisecondsSinceEpoch}';
    final composer = find.widgetWithText(TextField, Strings.chatMessageHint);
    expect(composer, findsOneWidget);
    await tester.enterText(composer, unique);
    await _settle(tester, 300);
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await _settle(tester, 2500);
    expect(find.text(unique), findsOneWidget);

    // Edit: long-press opens the context sheet (batch 4) → "Edit" row
    await _openMenu(tester, find.text(unique));
    expect(find.byKey(const ValueKey('ctx-edit')), findsOneWidget);
    await _pick(tester, 'ctx-edit');
    expect(find.text(Strings.chatEditingMessage), findsOneWidget);
    // Focus the composer by tapping it (as a user would) before typing; the
    // harness's implicit focus request can race the field's own refocus.
    await tester.tap(find.byType(TextField).first);
    await _settle(tester, 300);
    await tester.enterText(find.byType(TextField).first, '$unique edited');
    await _settle(tester, 300);
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await _settle(tester, 2500);
    expect(find.text('$unique edited'), findsOneWidget);
    // Scope to THIS bubble: earlier runs leave edited messages in the thread.
    final editedLabel = find.descendant(
      of: find.ancestor(
        of: find.text('$unique edited'),
        matching: find.byType(MessageBubble),
      ),
      matching: find.text(Strings.chatEdited),
    );
    expect(editedLabel, findsOneWidget);

    // History sheet lists the original
    await tester.tap(editedLabel);
    await _settle(tester, 2500);
    expect(find.text(Strings.chatEditHistory), findsOneWidget);
    expect(find.text(unique), findsOneWidget);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width / 2, 120)); // barrier → dismiss
    await _settle(tester, 2000);
    expect(find.text(Strings.chatEditHistory), findsNothing);

    // Delete for everyone (own, < 3 min) → tombstone
    await _openMenu(tester, find.text('$unique edited'));
    await _pick(tester, 'ctx-delete');
    expect(find.byKey(const ValueKey('delete-for-everyone')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-for-everyone')));
    await _settle(tester, 2500);
    expect(find.text(Strings.chatMessageDeleted), findsWidgets);
    expect(find.text('$unique edited'), findsNothing);

    // Delete for me on a tombstone + an old edited message (mixed/old →
    // no "everyone" option, no pencil); both vanish from MY view.
    final tombs = find.text(Strings.chatMessageDeleted);
    final tombCount = tester.widgetList(tombs).length;
    await _openMenu(tester, tombs.first);
    expect(find.byKey(const ValueKey('ctx-edit')), findsNothing);
    await _pick(tester, 'ctx-delete');
    expect(find.byKey(const ValueKey('delete-for-everyone')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('delete-for-me')));
    await _settle(tester, 2500);
    expect(tester.widgetList(tombs).length, tombCount - 1);
    await _settle(tester, 4000); // hold for a screenshot from the shell
  });
}
