// On-device check of Settings → Invite a colleague against a live local
// backend (which asks the real NPI Registry). Same flags as
// network_suggestions_test.dart, plus SHOT_DIR for screenshots.
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

  testWidgets('settings → invite a colleague → NPI results; empty people search',
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
    final router = container.read(routerProvider);

    router.push(AppRoutes.settings);
    await _settle(tester, 2500);
    expect(find.text('Invite a colleague'), findsOneWidget);
    await _shot(tester, 'invite_settings');

    await tester.tap(find.text('Invite a colleague'));
    await _settle(tester, 2000);
    await _shot(tester, 'invite_empty');

    // Live NPI Registry through the local API, in the doctor's own state.
    await tester.enterText(find.byType(TextField), 'Patel');
    await _settle(tester, 6000);
    expect(find.textContaining('in the NPI Registry'), findsOneWidget);
    expect(find.text('Invite'), findsWidgets);
    await _shot(tester, 'invite_results');

    router.pop();
    await _settle(tester, 800);
    router.pop();
    await _settle(tester, 800);
    router.push(AppRoutes.peopleSearch);
    await _settle(tester, 2500);
    await tester.enterText(find.byType(TextField), 'Zyxwq');
    await _settle(tester, 3000);
    expect(find.text('Invite "Zyxwq"'), findsOneWidget);
    await _shot(tester, 'invite_people_empty');
  });
}
