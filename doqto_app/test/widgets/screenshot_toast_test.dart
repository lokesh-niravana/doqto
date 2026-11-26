import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/state/screen_security_state.dart';

// The screenshot notice is a raw overlay entry, not a SnackBar: nothing tells
// a screen reader it appeared unless the toast says so itself.
void main() {
  testWidgets('the screenshot toast is announced and is a live region',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final announced = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
      SystemChannels.accessibility,
      (message) async {
        final m = (message as Map).cast<String, dynamic>();
        if (m['type'] == 'announce') {
          announced.add((m['data'] as Map)['message'] as String);
        }
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility, null));

    await tester.pumpWidget(MaterialApp(
      navigatorKey: rootNavigatorKey,
      home: const Scaffold(body: Text('chat')),
    ));
    showScreenshotToast(duration: const Duration(seconds: 1));
    await tester.pump();

    expect(announced, [screenshotToastText]);
    expect(find.text(screenshotToastText), findsOneWidget);
    final node = tester.getSemantics(find.text(screenshotToastText));
    expect(node.label, screenshotToastText);
    expect(node.flagsCollection.isLiveRegion, isTrue);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text(screenshotToastText), findsNothing);
    semantics.dispose();
  });
}
