import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/group.dart';

void main() {
  group('Group enum tolerance (A5)', () {
    test('GroupRole.fromWire garbage → unknown; isAdminTier ladder', () {
      expect(GroupRole.fromWire('garbage'), GroupRole.unknown);
      expect(GroupRole.fromWire('owner'), GroupRole.owner);
      expect(GroupRole.owner.isAdminTier, isTrue);
      expect(GroupRole.admin.isAdminTier, isTrue);
      expect(GroupRole.moderator.isAdminTier, isTrue);
      expect(GroupRole.member.isAdminTier, isFalse);
      expect(GroupRole.moderator.wire, 'moderator');
    });

    test('GroupMemberState.fromWire garbage → unknown', () {
      expect(GroupMemberState.fromWire('garbage'), GroupMemberState.unknown);
      expect(GroupMemberState.fromWire('active'), GroupMemberState.active);
      expect(GroupMemberState.banned.wire, 'banned');
    });

    test('WsEventServer mirrors the group events', () {
      expect(WsEventServer.fromWire('group_invite_received'),
          WsEventServer.groupInviteReceived);
      expect(WsEventServer.fromWire('group_member_joined'),
          WsEventServer.groupMemberJoined);
      // Retired with the join flow — must not resolve any more.
      expect(WsEventServer.fromWire('group_join_request'), isNull);
      expect(WsEventServer.fromWire('group_join_request_approved'), isNull);
    });
  });

  group('Group.fromJson', () {
    Map<String, dynamic> fullGroup() => {
          'id': 'g1',
          'conversation_id': 'c1',
          'name': 'Cardiology Leads',
          'description': 'Cross-org cardiology collaboration.',
          'post_policy': 'all_members',
          'member_dm_policy': 'request',
          'owner_id': 'u9',
          'org_id': null,
          'avatar_url': null,
          'member_count': 12,
          'created_at': '2026-07-20T00:00:00Z',
          'my_role': 'owner',
          'my_state': 'active',
        };

    test('full GroupOut parses every field', () {
      final g = Group.fromJson(fullGroup());
      expect(g.id, 'g1');
      expect(g.conversationId, 'c1');
      expect(g.name, 'Cardiology Leads');
      expect(g.memberDmPolicy, 'request');
      expect(g.postPolicy, 'all_members');
      expect(g.memberCount, 12);
      expect(g.ownerId, 'u9');
      expect(g.myRole, GroupRole.owner);
      expect(g.myState, GroupMemberState.active);
      expect(g.createdAt, isNotNull);
      expect(g.isMember, isTrue);
      expect(g.isAdmin, isTrue); // owner
      expect(g.initials, 'CL');
    });

    test('GroupCardOut (no conversation_id) is tolerant', () {
      final g = Group.fromJson({
        'id': 'g2',
        'name': 'Private Rounds',
        'member_count': 3,
      });
      expect(g.conversationId, ''); // card omits it
      expect(g.myRole, isNull);
      expect(g.isMember, isFalse);
      expect(g.isAdmin, isFalse);
      expect(g.memberCount, 3);
    });

    test('sparse/garbage payload never throws', () {
      final g = Group.fromJson({'id': 'x'});
      expect(g.name, '');
      expect(g.memberCount, 0);
      expect(g.avatarIndex, isNonNegative);
    });

    test('isMember respects non-active member state', () {
      final left = Group.fromJson({
        'id': 'g3',
        'name': 'Left Group',
        'member_count': 1,
        'my_role': 'member',
        'my_state': 'left',
      });
      expect(left.isMember, isFalse);
    });

    test('copyWith flips role/state and clears membership', () {
      final g = Group.fromJson(fullGroup());
      final left = g.copyWith(clearMyRole: true);
      expect(left.myRole, isNull);
      expect(left.myState, isNull);
      expect(left.isMember, isFalse);
      expect(left.name, g.name);
    });
  });

  group('GroupMember fromJson', () {
    test('GroupMember parses tolerantly', () {
      final m = GroupMember.fromJson({
        'user_id': 'u1',
        'full_name': 'Dr. Ada Vance',
        'role': 'admin',
        'state': 'active',
        'specialty': 'Cardiology',
      });
      expect(m.userId, 'u1');
      expect(m.role, GroupRole.admin);
      expect(m.state, GroupMemberState.active);
      expect(m.initials, 'DV'); // first+last word initials ("Dr." + "Vance")
    });
  });

  group('Group role helpers (B)', () {
    Group g(String role, {String state = 'active', String? invite, String post = 'all'}) =>
        Group.fromJson({
          'id': 'g1',
          'name': 'X',
          'my_role': role,
          'my_state': state,
          'post_policy': post,
          'invite_id': ?invite,
        });

    test('canManage / isOwner / canPost follow role and post policy', () {
      expect(g('owner').canManage, isTrue);
      expect(g('owner').isOwner, isTrue);
      expect(g('admin').canManage, isTrue);
      expect(g('admin').isOwner, isFalse);
      expect(g('member').canManage, isFalse);
      expect(g('member').canPost, isTrue);
      expect(g('member', post: 'admins_only').canPost, isFalse);
      expect(g('admin', post: 'admins_only').canPost, isTrue);
      expect(g('owner', state: 'invited').canManage, isFalse);
    });

    test('hasPendingInvite needs a non-member with an invite id', () {
      expect(g('member', state: 'invited', invite: 'i1').hasPendingInvite, isTrue);
      expect(g('member', state: 'invited').hasPendingInvite, isFalse);
      expect(g('member', invite: 'i1').hasPendingInvite, isFalse);
      expect(g('member', invite: 'i1').copyWith(clearInvite: true).inviteId, isNull);
    });
  });

  group('GroupInvite', () {
    test('link invites carry a deep link; direct ones do not', () {
      final link = GroupInvite.fromJson({
        'id': 'i1',
        'group_id': 'g1',
        'inviter_id': 'u1',
        'token': 'abc',
        'max_uses': 3,
        'use_count': 1,
        'state': 'pending',
        'expires_at': '2026-12-01T00:00:00Z',
      });
      expect(link.isLink, isTrue);
      expect(link.deepLink, 'doqto:///g/abc');
      expect(link.expiresAt!.isUtc, isTrue);
      final direct = GroupInvite.fromJson({
        'id': 'i2',
        'group_id': 'g1',
        'inviter_id': 'u1',
        'invitee_id': 'u2',
        'state': 'pending',
      });
      expect(direct.isLink, isFalse);
      expect(direct.useCount, 0);
    });

    test('already_member is not a join', () {
      expect(JoinResult.fromJson({'result': 'already_member', 'group_id': 'g1'}).joined,
          isFalse);
    });
  });

  group('JoinResult', () {
    test('accepting an invite link reports joined', () {
      expect(JoinResult.fromJson({'result': 'joined', 'group_id': 'g1'}).joined,
          isTrue);
      expect(JoinResult.fromJson({'result': '', 'group_id': 'g1'}).joined,
          isFalse);
    });
  });
}
