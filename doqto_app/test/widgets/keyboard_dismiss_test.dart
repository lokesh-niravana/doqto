import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/utils/validators.dart';
import 'package:doqto_app/ui/widgets/app_text_field.dart';

// Guards the rule in CLAUDE.md: every text input dismisses its keyboard on a
// tap outside, and fixed-length inputs dismiss once they are complete.
void main() {
  Future<void> pump(WidgetTester tester, Widget field) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(children: [
              field,
              const SizedBox(height: 200, width: 200, child: Text('outside')),
            ]),
          ),
        ),
      );

  testWidgets('AppTextField: tap outside dismisses the keyboard', (tester) async {
    await pump(tester, AppTextField(controller: TextEditingController()));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('outside'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('AppTextField: multi-line (group description) still dismisses on tap outside',
      (tester) async {
    await pump(tester, AppTextField(controller: TextEditingController(), maxLines: 4));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.text('outside'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('AppTextField: dismissOnValid drops the keypad when complete',
      (tester) async {
    await pump(
      tester,
      AppTextField(
        controller: TextEditingController(),
        validator: Validators.otp(6),
        dismissOnValid: true,
      ),
    );
    final field = find.byType(TextField);

    await tester.tap(field);
    await tester.pumpAndSettle();

    await tester.enterText(field, '12345'); // short — keypad stays
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.enterText(field, '123456'); // complete — keypad goes
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('AppTextField: free text keeps the keyboard while typing',
      (tester) async {
    await pump(
      tester,
      AppTextField(
        controller: TextEditingController(),
        validator: Validators.required('Name'),
      ),
    );
    final field = find.byType(TextField);

    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'Lokesh');
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
  });
}
