import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/data/models/group.dart';
import 'package:doqto_app/state/groups_state.dart';
import 'package:doqto_app/ui/screens/groups/groups_tab_screen.dart';
import 'package:doqto_app/ui/widgets/app_segmented.dart';
import 'package:doqto_app/ui/widgets/search_bar.dart';

Group _member(String id, String name) => Group.fromJson({
      'id': id,
      'name': name,
      'visibility': 'public',
      'join_policy': 'open',
      'member_count': 5,
      'my_role': 'member',
      'my_state': 'active',
    });

Group _invited(String id, String name) => Group.fromJson({
      'id': id,
      'name': name,
      'member_count': 3,
      'my_role': 'member',
      'my_state': 'invited',
      'invite_id': 'inv-$id',
    }).copyWith(membershipTag: GroupMembershipTag.invited);

/// Fake that skips the WS/Hive path and returns fixed member groups.
class _FakeMyGroups extends MyGroupsNotifier {
  final List<Group> invited;
  _FakeMyGroups({this.invited = const []});
  final calls = <String>[];
  @override
  Future<MyGroupsData> build() async => MyGroupsData(
        member: [_member('g1', 'Cardiology Leads'), _member('g2', 'ICU Rounds')],
        invited: invited,
      );
  @override
  Future<void> acceptInvite(Group g) async {
    calls.add('accept:${g.id}');
    final d = state.value!;
    state = AsyncData(MyGroupsData(
      member: [...d.member, g.copyWith(membershipTag: GroupMembershipTag.member)],
      invited: [for (final x in d.invited) if (x.id != g.id) x],
    ));
  }
  @override
  Future<void> declineInvite(Group g) async {
    calls.add('decline:${g.id}');
    final d = state.value!;
    state = AsyncData(MyGroupsData(
      member: d.member,
      invited: [for (final x in d.invited) if (x.id != g.id) x],
    ));
  }
}

Widget _app({_FakeMyGroups? fake}) => ProviderScope(
      overrides: [myGroupsProvider.overrideWith(() => fake ?? _FakeMyGroups())],
      child: const MaterialApp(home: GroupsTabScreen()),
    );

void main() {
  testWidgets('renders my group rows with no discovery affordances',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Cardiology Leads'), findsOneWidget);
    expect(find.text('ICU Rounds'), findsOneWidget);

    // Groups are not browsable: no segmented control, no search.
    expect(find.byType(AppSegmented), findsNothing);
    expect(find.byType(AppSearchBar), findsNothing);
    expect(find.text(Strings.groupsDiscover), findsNothing);
    // No invite → no Accept / Decline anywhere.
    expect(find.text(Strings.groupAccept), findsNothing);
  });

  testWidgets('an invited group shows the chip with Accept / Decline on the row',
      (tester) async {
    final fake = _FakeMyGroups(invited: [_invited('g9', 'Stroke Network')]);
    await tester.pumpWidget(_app(fake: fake));
    await tester.pumpAndSettle();

    expect(find.text('Stroke Network'), findsOneWidget);
    expect(find.text(Strings.groupInvited), findsOneWidget);
    expect(find.byKey(const ValueKey('group-accept-g9')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-decline-g9')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('group-decline-g9')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['decline:g9']);
    expect(find.text('Stroke Network'), findsNothing);
    expect(find.text(Strings.groupDeclinedToast), findsOneWidget);
  });

  testWidgets('Accept moves the row to members and drops the chip',
      (tester) async {
    final fake = _FakeMyGroups(invited: [_invited('g9', 'Stroke Network')]);
    await tester.pumpWidget(_app(fake: fake));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('group-accept-g9')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['accept:g9']);
    expect(find.text('Stroke Network'), findsOneWidget);
    expect(find.text(Strings.groupInvited), findsNothing);
    expect(find.byKey(const ValueKey('group-accept-g9')), findsNothing);
  });
}
