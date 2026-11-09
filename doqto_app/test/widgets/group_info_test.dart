import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/group.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/groups_state.dart';
import 'package:doqto_app/ui/screens/groups/group_info_screen.dart';

Group _group({
  String myState = 'active',
  String myRole = 'member',
  String? inviteId,
  String postPolicy = 'all_members',
}) =>
    Group.fromJson({
      'id': 'g1',
      'name': 'Bonita Cardiology Team',
      'description': 'Inpatient cardiology coordination.',
      'member_count': 2,
      'conversation_id': 'c1',
      'my_role': myRole,
      'my_state': myState,
      'post_policy': postPolicy,
      'member_dm_policy': 'request',
      'invite_id': ?inviteId,
    });

class _FakeDetail extends GroupDetailNotifier {
  final Group group;
  _FakeDetail(this.group);
  final calls = <String>[];
  @override
  Future<Group> build(String groupId) async => group;
  @override
  Future<void> acceptInvite() async => calls.add('accept');
  @override
  Future<void> declineInvite() async => calls.add('decline');
}

class _FakeMembers extends GroupMembersNotifier {
  @override
  Future<List<GroupMember>> build(String groupId) async => [
        GroupMember.fromJson({
          'user_id': 'me',
          'full_name': 'Dr. Ravi Patel',
          'specialty': 'Cardiology',
          'role': 'owner',
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

class _FakeInvites extends GroupInvitesNotifier {
  @override
  Future<List<GroupInvite>> build(String groupId) async => [
        GroupInvite.fromJson({
          'id': 'i1',
          'group_id': 'g1',
          'inviter_id': 'me',
          'token': 'tok123',
          'use_count': 1,
          'max_uses': 5,
          'state': 'pending',
        }),
        GroupInvite.fromJson({
          'id': 'i2',
          'group_id': 'g1',
          'inviter_id': 'me',
          'invitee_id': 'u-pending',
          'invitee_name': 'Dr. Pending Person',
          'state': 'pending',
          'created_at': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(),
        }),
      ];
}

class _FakeConvs extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _SignedIn extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        AuthStage.signedIn,
        User.fromJson({
          'id': 'me',
          'phone': '+15550000101',
          'full_name': 'Dr. Ravi Patel',
          'npi_number': '1234567893',
          'role': 'doctor',
          'created_at': '2026-09-05T00:00:00Z',
        }),
      );
}

Widget _app(Group group, {_FakeDetail? detail}) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_SignedIn.new),
        groupDetailProvider.overrideWith(() => detail ?? _FakeDetail(group)),
        groupMembersProvider.overrideWith(_FakeMembers.new),
        groupInvitesProvider.overrideWith(_FakeInvites.new),
        conversationsProvider.overrideWith(_FakeConvs.new),
      ],
      child: const MaterialApp(home: GroupInfoScreen(groupId: 'g1')),
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  Future<void> tall(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('member: identity, about, members, the way out — no controls',
      (tester) async {
    await tall(tester);
    await tester.pumpWidget(_app(_group()));
    await tester.pumpAndSettle();
    expect(find.textContaining(Strings.groupPendingInvitesLabel), findsNothing);

    expect(find.text(Strings.groupInfoTitle), findsOneWidget);
    expect(find.text('Bonita Cardiology Team'), findsOneWidget);
    expect(find.text('Inpatient cardiology coordination.'), findsOneWidget);
    expect(find.text('Dr. Sarah Kim'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text(Strings.groupLeave), findsOneWidget);

    // Management surface is hidden from a plain member.
    expect(find.text(Strings.groupSettingsLabel), findsNothing);
    expect(find.text(Strings.groupInviteLinksLabel), findsNothing);
    expect(find.byKey(const ValueKey('members-add')), findsNothing);
    expect(find.byKey(const ValueKey('group-description-edit')), findsNothing);
    expect(find.byKey(const ValueKey('invite-accept')), findsNothing);
  });

  testWidgets('owner: settings, invite links, add members, member actions',
      (tester) async {
    await tall(tester);
    await tester.pumpWidget(_app(_group(myRole: 'owner')));
    await tester.pumpAndSettle();

    expect(find.text(Strings.groupSettingsLabel), findsOneWidget);
    expect(find.text(Strings.groupSendMessagesLabel), findsOneWidget);
    expect(find.text(Strings.groupSendAll), findsOneWidget);
    expect(find.text(Strings.groupDmLabel), findsOneWidget);
    expect(find.text(Strings.groupDisappearingLabel), findsOneWidget);
    expect(find.text(Strings.groupInviteLinksLabel), findsOneWidget);
    expect(find.text('doqto:///g/tok123'), findsOneWidget);
    expect(find.byKey(const ValueKey('members-add')), findsOneWidget);
    // Direct invites sent from Add members are listed until answered.
    expect(find.text('${Strings.groupPendingInvitesLabel} (1)'), findsOneWidget);
    expect(find.text('Dr. Pending Person'), findsOneWidget);
    expect(find.text(Strings.groupInvitedAgo('2h ago')), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-cancel-i2')), findsOneWidget);
    // The link invite stays under Invite links, not here.
    expect(find.byKey(const ValueKey('invite-i1')), findsNothing);
    expect(find.byKey(const ValueKey('group-description-edit')), findsOneWidget);

    // Tapping another member opens the actions sheet with owner powers.
    await tester.tap(find.text('Dr. Sarah Kim'));
    await tester.pumpAndSettle();
    expect(find.text(Strings.groupMemberMessage), findsOneWidget);
    expect(find.text(Strings.groupMemberPromote), findsOneWidget);
    expect(find.text(Strings.groupMemberTransfer), findsOneWidget);
    expect(find.text(Strings.groupMemberRemove), findsOneWidget);
    expect(find.text(Strings.groupMemberBan), findsOneWidget);
  });

  testWidgets('admin: can moderate members but not change roles',
      (tester) async {
    await tall(tester);
    await tester.pumpWidget(_app(_group(myRole: 'admin')));
    await tester.pumpAndSettle();

    expect(find.text(Strings.groupSettingsLabel), findsOneWidget);
    await tester.tap(find.text('Dr. Sarah Kim'));
    await tester.pumpAndSettle();
    expect(find.text(Strings.groupMemberPromote), findsNothing);
    expect(find.text(Strings.groupMemberTransfer), findsNothing);
    expect(find.text(Strings.groupMemberRemove), findsOneWidget);
  });

  testWidgets('post policy picker lists both options with the current ticked',
      (tester) async {
    await tall(tester);
    await tester.pumpWidget(_app(_group(myRole: 'owner')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('setting-post-policy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('post-all_members')), findsOneWidget);
    expect(find.byKey(const ValueKey('post-admins_only')), findsOneWidget);
  });

  testWidgets('a pending invitee sees Accept / Decline and no Exit',
      (tester) async {
    await tall(tester);
    final g = _group(myState: 'invited', inviteId: 'inv1');
    final detail = _FakeDetail(g);
    await tester.pumpWidget(_app(g, detail: detail));
    await tester.pumpAndSettle();

    expect(find.text('Bonita Cardiology Team'), findsOneWidget);
    expect(find.text(Strings.groupLeave), findsNothing);
    expect(find.text(Strings.groupInvitedBy), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-accept')), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-decline')), findsOneWidget);
    // No management surface for an outsider.
    expect(find.text(Strings.groupSettingsLabel), findsNothing);

    await tester.tap(find.byKey(const ValueKey('invite-accept')));
    await tester.pump();
    expect(detail.calls, ['accept']);
  });

  testWidgets('a non-member without an invite sees neither buttons nor Exit',
      (tester) async {
    await tall(tester);
    await tester.pumpWidget(_app(_group(myState: 'invited')));
    await tester.pumpAndSettle();
    expect(find.text(Strings.groupLeave), findsNothing);
    expect(find.byKey(const ValueKey('invite-accept')), findsNothing);
  });
}
