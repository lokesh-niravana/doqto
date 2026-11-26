import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/utils/validators.dart';
import 'package:doqto_app/ui/screens/org/join_org_screen.dart';

/// Keyboard rule: an invite code is exactly nine characters, so a complete
/// one puts the keyboard away by itself.
void main() {
  testWidgets('a complete invite code dismisses the keyboard; a partial one does not',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: JoinOrgScreen())),
    );
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.enterText(field, 'APOL·48');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.enterText(field, 'APOL·4827');
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  // The middle dot cannot be typed on a phone keyboard: the field inserts it.
  testWidgets('typing apol4827 formats to APOL·4827, validates and dismisses the keyboard',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: JoinOrgScreen())),
    );
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.enterText(field, 'apol48');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'APOL·48');
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.enterText(field, 'apol4827');
    await tester.pumpAndSettle();
    final text = tester.widget<TextField>(field).controller!.text;
    expect(text, 'APOL·4827');
    expect(Validators.inviteCode()(text), isNull);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  test('separators the user can type are all accepted', () {
    for (final typed in ['APOL.4827', 'apol-4827', 'APOL 4827', 'APOL4827', 'APOL·4827']) {
      expect(Validators.normalizeInviteCode(typed), 'APOL·4827');
      expect(Validators.inviteCode()(typed), isNull);
    }
    expect(Validators.inviteCode()('1234·ABCD'), isNotNull);
    expect(Validators.inviteCode()('APOL·48'), isNotNull);
  });
}
