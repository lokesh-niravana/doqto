import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/data/models/group.dart';
import 'package:doqto_app/state/groups_state.dart';
import 'package:doqto_app/ui/screens/groups/group_info_screen.dart';

Group _group({String myState = 'active'}) => Group.fromJson({
      'id': 'g1',
      'name': 'Bonita Cardiology Team',
      'description': 'Inpatient cardiology coordination.',
      'member_count': 2,
      'conversation_id': 'c1',
      'my_role': 'member',
      'my_state': myState,
    });

class _FakeDetail extends GroupDetailNotifier {
  final Group group;
  _FakeDetail(this.group);
  @override
  Future<Group> build(String groupId) async => group;
}

class _FakeMembers extends GroupMembersNotifier {
  @override
  Future<List<GroupMember>> build(String groupId) async => [
        GroupMember.fromJson({
          'user_id': 'u1',
          'full_name': 'Dr. Ravi Patel',
          'specialty': 'Cardiology',
          'role': 'admin',
          'state': 'active',
        }),
        GroupMember.fromJson({
          'user_id': 'u2',
          'full_name': 'Dr. Sarah Kim',
          'specialty': 'Heart Failure',
          'role': 'member',
          'state': 'active',
        }),
      ];
}

Widget _app(Group group) => ProviderScope(
      overrides: [
        groupDetailProvider.overrideWith(() => _FakeDetail(group)),
        groupMembersProvider.overrideWith(_FakeMembers.new),
      ],
      child: const MaterialApp(home: GroupInfoScreen(groupId: 'g1')),
    );

void main() {
  testWidgets('group info: identity, about, members, and the way out',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_group()));
    await tester.pumpAndSettle();

    expect(find.text(Strings.groupInfoTitle), findsOneWidget);
    expect(find.text('Bonita Cardiology Team'), findsOneWidget);
    expect(find.text('Inpatient cardiology coordination.'), findsOneWidget);
    expect(find.text('Dr. Ravi Patel'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Dr. Sarah Kim'), findsOneWidget);
    expect(find.text(Strings.groupLeave), findsOneWidget);
  });

  testWidgets('a pending invitee sees the group but no Exit',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(_group(myState: 'invited')));
    await tester.pumpAndSettle();

    expect(find.text('Bonita Cardiology Team'), findsOneWidget);
    expect(find.text(Strings.groupLeave), findsNothing);
  });
}
