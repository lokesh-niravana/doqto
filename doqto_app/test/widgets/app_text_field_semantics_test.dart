import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/ui/widgets/app_text_field.dart';

// VoiceOver must hear the field's name. The label is drawn above the field
// as separate text, so it has to be attached to the field itself.
void main() {
  testWidgets('the label names the text field for screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: AppTextField(label: 'First name')),
    ));

    final node = tester.getSemantics(find.byType(TextField));
    expect(node.label, 'First name');
    // Announced once: the visible label is not a second, separate node.
    expect(find.bySemanticsLabel('First name'), findsOneWidget);
    handle.dispose();
  });

  // A code box under a heading, a search field, a caption: no visible label,
  // so the name is given outright. The placeholder is drawn but not read —
  // as the name it would vanish at the first character.
  testWidgets('semanticLabel names a field that has no visible label', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppTextField(
          controller: controller,
          semanticLabel: 'Verification code',
          hint: '000000',
        ),
      ),
    ));

    expect(tester.getSemantics(find.byType(TextField)).label, 'Verification code');
    // Still on screen for sighted users.
    expect(find.text('000000'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('000000')), findsNothing);

    // The name survives typing.
    await tester.enterText(find.byType(TextField), '12');
    await tester.pump();
    expect(tester.getSemantics(find.byType(TextField)).label, 'Verification code');
    handle.dispose();
  });

  testWidgets('a visible label wins over semanticLabel, and its hint is still read', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AppTextField(
          label: 'Email',
          semanticLabel: 'ignored',
          hint: 'you@clinic.com',
        ),
      ),
    ));

    final node = tester.getSemantics(find.byType(TextField));
    expect(node.label, contains('Email'));
    expect(node.label, isNot(contains('ignored')));
    handle.dispose();
  });

  testWidgets('keyboard rule: a semanticLabel field still unfocuses on tap outside', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            AppTextField(semanticLabel: 'Caption', hint: 'Add a caption…'),
            SizedBox(height: 300, width: 300),
          ],
        ),
      ),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tapAt(const Offset(150, 400));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isFalse);
  });
}
