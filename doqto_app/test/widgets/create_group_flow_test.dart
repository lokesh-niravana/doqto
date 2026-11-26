import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/ui/screens/groups/create_group_flow_screen.dart';

PersonCard _person(String id, String name, String specialty) => PersonCard(
      id: id,
      fullName: name,
      headline: null,
      specialty: specialty,
      locationLabel: null,
      avatarColor: null,
      avatarUrl: null,
      avatarPresignedUrl: null,
      degree: ConnectionDegree.out,
      mutualCount: 0,
    );

/// A connection and an org colleague — the invite step must offer both.
Widget _app({List<PersonCard>? people}) => ProviderScope(
      overrides: [
        invitablePeopleProvider.overrideWith((ref) async =>
            people ??
            [
              _person('u1', 'Dr. Ada Vance', 'Cardiology'),
              _person('u2', 'Dr. Ben Osei', 'Neurology'),
            ]),
      ],
      child: const MaterialApp(home: CreateGroupFlowScreen()),
    );

void main() {
  testWidgets('the description is a multi-line field with the 1000 limit',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField).at(1));
    expect(field.maxLines, 4);
    expect(field.maxLength, 1000);
    expect(field.keyboardType, TextInputType.multiline);
    // Keyboard rule: a multi-line field has no "done" key, so tap-outside
    // must still dismiss it.
    expect(field.onTapOutside, isNotNull);
  });

  testWidgets('advances Identity → Invite once a name is entered',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Step 1: Identity. The invite step is not shown yet.
    expect(find.text(Strings.groupsNameLabel), findsWidgets);
    expect(find.text(Strings.groupsInviteStepTitle), findsNothing);

    // "Next" is disabled with an empty name — tapping does nothing. (.last is
    // the visible label copy; .first is AppButton's invisible width-holder.)
    await tester.tap(find.text(Strings.groupsNext).last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text(Strings.groupsInviteStepTitle), findsNothing);

    // Enter a name → Next enabled → straight to Invite, which is now the last
    // step (the Access step went away with join policies).
    await tester.enterText(find.byType(TextField).first, 'Cardiology Leads');
    await tester.pumpAndSettle();
    await tester.tap(find.text(Strings.groupsNext).last);
    await tester.pumpAndSettle();

    expect(find.text(Strings.groupsInviteStepTitle), findsOneWidget);
    expect(find.text(Strings.groupsCreateCta), findsWidgets);
  });

  testWidgets('invite step lists connections and colleagues, and filters them',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Cardiology Leads');
    await tester.pumpAndSettle();
    await tester.tap(find.text(Strings.groupsNext).last);
    await tester.pumpAndSettle();

    expect(find.text('Dr. Ada Vance'), findsOneWidget);
    expect(find.text('Dr. Ben Osei'), findsOneWidget);

    // The search field is the last TextField on the invite step.
    await tester.enterText(find.byType(TextField).last, 'neuro');
    await tester.pumpAndSettle();
    expect(find.text('Dr. Ada Vance'), findsNothing);
    expect(find.text('Dr. Ben Osei'), findsOneWidget); // matched on specialty
  });

  testWidgets('empty invite list explains it instead of blaming connections',
      (tester) async {
    await tester.pumpWidget(_app(people: const []));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Cardiology Leads');
    await tester.pumpAndSettle();
    await tester.tap(find.text(Strings.groupsNext).last);
    await tester.pumpAndSettle();

    expect(find.text(Strings.groupsNoInvitablePeople), findsOneWidget);
    expect(find.text(Strings.netEmptyConnections), findsNothing);
  });
}
