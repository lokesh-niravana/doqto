import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/ui/widgets/app_pressable.dart';

// VoiceOver must meet one node per control: a button, with its name and a
// tap action. Two nodes (a nameless button, then loose text) is the failure
// this guards against.
void main() {
  testWidgets('text inside becomes the name of a single button node', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AppPressable(onTap: () => taps++, child: const Text('Continue')),
        ),
      ),
    ));

    final node = tester.getSemantics(find.byType(AppPressable));
    expect(
      node,
      containsSemantics(label: 'Continue', isButton: true, hasTapAction: true),
    );
    expect(find.bySemanticsLabel('Continue'), findsOneWidget);

    tester.semantics.tap(find.semantics.byLabel('Continue'));
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('semanticLabel names an icon-only control', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AppPressable(
            onTap: () {},
            semanticLabel: 'Send',
            selected: true,
            child: const Icon(Icons.send),
          ),
        ),
      ),
    ));

    final node = tester.getSemantics(find.byType(AppPressable));
    expect(node, containsSemantics(label: 'Send', isButton: true, isSelected: true));
    handle.dispose();
  });
}
