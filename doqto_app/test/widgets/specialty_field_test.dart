import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/specialties.dart';
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/ui/widgets/specialty_field.dart';

void main() {
  late TextEditingController controller;

  setUp(() => controller = TextEditingController());
  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // A Column, like the real form — a lone child would let the field
            // stretch to fill the screen and push its options off the bottom.
            body: Column(
              children: [
                SpecialtyField(controller: controller, label: 'Specialty'),
              ],
            ),
          ),
        ),
      );

  test('the list is deduplicated and Other comes last', () {
    expect(Specialties.all.toSet().length, Specialties.all.length);
    expect(Specialties.all, isNot(contains(Specialties.other)));
    expect(Specialties.matching('').last, Specialties.other);
    expect(Specialties.matching('zzz'), [Specialties.other]);
  });

  testWidgets('typing filters the list and picking fills the field',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'cardio');
    await tester.pumpAndSettle();

    // Substring, not prefix — "cardio" has to reach Pediatric Cardiology.
    expect(find.text('Cardiology'), findsOneWidget);
    expect(find.text('Pediatric Cardiology'), findsOneWidget);
    expect(find.text('Interventional Cardiology'), findsOneWidget);
    // Unrelated entries are filtered out.
    expect(find.text('Dermatology'), findsNothing);

    await tester.tap(find.text('Pediatric Cardiology'));
    await tester.pumpAndSettle();

    expect(controller.text, 'Pediatric Cardiology');
  });

  testWidgets('Other opens a second field carrying what was typed',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'cardio');
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.text('${Specialties.other}…'));
    await tester.pumpAndSettle();

    // The dropdown keeps saying Other; a second field appears below it,
    // prefilled with the half-typed query.
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    expect(tester.widget<TextField>(fields.at(0)).controller!.text,
        Specialties.other);
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, 'cardio');
    expect(find.text(Strings.regSpecialtyOther), findsOneWidget);

    // The submitted value is the write-in text, never the word Other.
    expect(controller.text, 'cardio');

    await tester.enterText(fields.at(1), 'Veterinary Cardiology');
    await tester.pumpAndSettle();
    expect(controller.text, 'Veterinary Cardiology');
  });

  testWidgets('typing in the dropdown again drops the write-in field',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'cardio');
    await tester.pumpAndSettle();
    await tester.tap(find.text('${Specialties.other}…'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.enterText(find.byType(TextField).at(0), 'derm');
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(controller.text, 'derm');
  });

  testWidgets('a value written from outside is left alone', (tester) async {
    // The NPI registry lookup writes a taxonomy straight into the controller;
    // the picker must not fight it.
    await pump(tester);

    controller.text = 'Student in an Organized Health Care Education Program';
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Student in an Organized Health Care Education Program',
    );
    // A write from outside also ends "Other" mode.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('the options stop above the keyboard and the field scrolls to the top',
      (tester) async {
    const keyboard = 300.0;
    // The real keyboard: an inset on the view, which the Scaffold consumes.
    tester.view.viewInsets = FakeViewPadding(
      bottom: keyboard * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              const SizedBox(height: 200),
              SpecialtyField(controller: controller, label: 'Specialty'),
              const SizedBox(height: 600),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    // Focus brought the field to the top of the viewport…
    expect(tester.getTopLeft(find.byType(SpecialtyField)).dy, 0);
    // …and the list ends above the keyboard, not behind it.
    final screen = tester.getSize(find.byType(MaterialApp)).height;
    final options = tester.getRect(find.byKey(const ValueKey('specialty-options')));
    expect(options.height, greaterThan(100));
    expect(options.bottom, lessThanOrEqualTo(screen - keyboard));
  });
}
