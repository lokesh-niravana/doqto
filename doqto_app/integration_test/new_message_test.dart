// On-device check of Start a conversation → New message → chat, against a
// live local backend where the demo doctor (+1 650-555-0199, a Firebase test
// number) has a verified org and one connection ("Second Tester").
//
//   flutter test integration_test/new_message_test.dart -d <sim> \
//     --dart-define=FIREBASE_TEST_NUMBERS=true \
//     --dart-define=API_BASE_URL=http://localhost:8010 \
//     --dart-define=WS_BASE_URL=ws://localhost:8010
//
// With --dart-define=SHOT_DIR=<folder on this Mac> each screen is saved there
// as shot_<name>.png, drawn from the app's own layers so the iOS notification
// prompt doesn't cover it (simulator apps can write to the Mac's disk).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';

const _pause = int.fromEnvironment('PAUSE_MS', defaultValue: 1000);

const _shotDir = String.fromEnvironment('SHOT_DIR');

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  // The root layer is in physical pixels.
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/shot_$name.png')
      .writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('start a conversation opens the picker, then the chat',
      (tester) async {
    await app.main();
    await _settle(tester, 3000);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final auth = container.read(authProvider.notifier);
    if (container.read(authProvider).stage != AuthStage.signedIn) {
      final challenge = await auth.startPhoneSignIn('+16505550199');
      await auth.confirmPhoneCode(challenge, '123456');
      await _settle(tester, 4000);
    }
    expect(container.read(authProvider).stage, AuthStage.signedIn);

    container.read(routerProvider).go(AppRoutes.chats);
    await _settle(tester, _pause);

    await tester.tap(find.byTooltip('New message'));
    await _settle(tester, 3000);
    expect(find.text('New message'), findsWidgets);
    expect(find.text('CONNECTIONS'), findsOneWidget);
    expect(find.text('Second Tester'), findsOneWidget);
    expect(find.text('New group'), findsOneWidget);
    await _settle(tester, _pause);
    await _shot(tester, 'picker');

    await tester.enterText(find.byType(TextField), 'second');
    await _settle(tester, 1500);
    expect(find.text('Second Tester'), findsOneWidget);
    await _settle(tester, _pause);
    await _shot(tester, 'search');

    await tester.tap(find.text('Second Tester'));
    await _settle(tester, 4000);
    expect(find.text('Second Tester'), findsWidgets);
    expect(find.text('CONNECTIONS'), findsNothing);
    await _settle(tester, _pause);
    await _shot(tester, 'thread');
  });
}
