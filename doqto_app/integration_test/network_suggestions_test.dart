// On-device check of Network → Recommended for you, against a live local
// backend where the demo doctor (+1 650-555-0199, a Firebase test number) has
// a verified org, a connection, and other doctors to suggest.
//
//   flutter test integration_test/network_suggestions_test.dart -d <sim> \
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

  testWidgets('network tab shows recommended doctors with a reason',
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

    container.read(routerProvider).go(AppRoutes.network);
    await _settle(tester, 4000);
    expect(find.text('RECOMMENDED FOR YOU'), findsOneWidget);
    expect(find.text('In your organization'), findsOneWidget);
    expect(find.text('1 mutual connection'), findsOneWidget);
    await _settle(tester, _pause);
    await _shot(tester, 'network');

    await tester.ensureVisible(find.text('See all'));
    await tester.tap(find.text('See all'));
    await _settle(tester, 2500);
    expect(find.text('Recommended for you'), findsOneWidget);
    await _settle(tester, _pause);
    await _shot(tester, 'suggestions_all');
  });
}
