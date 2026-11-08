import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/network_profile.dart';

void main() {
  group('Networking enum tolerance (A5)', () {
    test('InvitationStatus.fromWire garbage → unknown sentinel', () {
      expect(InvitationStatus.fromWire('garbage'), InvitationStatus.unknown);
      expect(InvitationStatus.fromWire('pending'), InvitationStatus.pending);
      expect(InvitationStatus.fromWire('withdrawn'), InvitationStatus.withdrawn);
      expect(InvitationStatus.unknown.wire, 'unknown');
    });

    test('InvitePolicy.fromWire garbage → unknown', () {
      expect(InvitePolicy.fromWire('garbage'), InvitePolicy.unknown);
      expect(InvitePolicy.fromWire('second_degree'), InvitePolicy.secondDegree);
      expect(InvitePolicy.secondDegree.wire, 'second_degree');
    });

    test('DmPolicy.fromWire garbage → unknown', () {
      expect(DmPolicy.fromWire('garbage'), DmPolicy.unknown);
      expect(DmPolicy.fromWire('connections_only'), DmPolicy.connectionsOnly);
      expect(DmPolicy.connectionsAndRequests.wire, 'connections_and_requests');
    });

    test('batch 2 visibility enums tolerate garbage', () {
      expect(LastSeenVisibility.fromWire('garbage'), LastSeenVisibility.unknown);
      expect(LastSeenVisibility.fromWire('nobody'), LastSeenVisibility.nobody);
      expect(OnlineVisibility.fromWire('same_as_last_seen'),
          OnlineVisibility.sameAsLastSeen);
      expect(OnlineVisibility.fromWire(null), OnlineVisibility.unknown);
      expect(ProfileFieldVisibility.fromWire('connections'),
          ProfileFieldVisibility.connections);
      expect(RelationshipState.fromWire('blocked'), RelationshipState.blocked);
    });

    test('PrivacySettings parses the batch 2 fields with defaults', () {
      final legacy = PrivacySettings.fromJson({
        'invite_policy': 'everyone',
        'dm_policy': 'connections_only',
        'discoverability': 'connections',
      });
      expect(legacy.lastSeenVisibility, LastSeenVisibility.connections);
      expect(legacy.onlineVisibility, OnlineVisibility.sameAsLastSeen);
      expect(legacy.readReceipts, isTrue);
      expect(legacy.defaultDisappearSec, isNull);
      expect(legacy.linkPreviews, isTrue);
      expect(legacy.showMutualConnections, isTrue);

      final full = PrivacySettings.fromJson({
        'invite_policy': 'nobody',
        'dm_policy': 'everyone',
        'discoverability': 'everyone',
        'show_mutual_connections': false,
        'last_seen_visibility': 'nobody',
        'online_visibility': 'nobody',
        'profile_photo_visibility': 'connections',
        'about_visibility': 'connections',
        'read_receipts': false,
        'default_disappear_sec': 86400,
        'link_previews': false,
      });
      expect(full.lastSeenVisibility, LastSeenVisibility.nobody);
      expect(full.profilePhotoVisibility, ProfileFieldVisibility.connections);
      expect(full.defaultDisappearSec, 86400);
      expect(full.toJson()['about_visibility'], 'connections');
      expect(full.copyWith(defaultDisappearSec: () => null).defaultDisappearSec, isNull);
      expect(full.copyWith(readReceipts: true).defaultDisappearSec, 86400);
    });

    test('Discoverability.fromWire garbage → unknown', () {
      expect(Discoverability.fromWire('garbage'), Discoverability.unknown);
      expect(Discoverability.fromWire('connections'), Discoverability.connections);
    });

    test('WsEventServer.fromWire mirrors new M1 events', () {
      expect(WsEventServer.fromWire('invitation_received'),
          WsEventServer.invitationReceived);
      expect(WsEventServer.fromWire('invitation_accepted'),
          WsEventServer.invitationAccepted);
      expect(WsEventServer.fromWire('connection_removed'),
          WsEventServer.connectionRemoved);
      expect(WsEventServer.fromWire('notification_created'),
          WsEventServer.notificationCreated);
      expect(WsEventServer.fromWire('brand_new_event'), isNull);
    });

    test('client-only relationship strings are tolerant', () {
      // degree: unknown → out (least connected)
      expect(ConnectionDegree.fromWire('garbage'), ConnectionDegree.out);
      expect(ConnectionDegree.fromWire('1st'), ConnectionDegree.first);
      expect(ConnectionDegree.fromWire(null), ConnectionDegree.out);
      // state: unknown → none
      expect(RelationshipState.fromWire('garbage'), RelationshipState.none);
      expect(RelationshipState.fromWire('pending_incoming'),
          RelationshipState.pendingIncoming);
      // can_message: unknown → denied (fail-safe)
      expect(CanMessage.fromWire('garbage'), CanMessage.denied);
      expect(CanMessage.fromWire('open'), CanMessage.open);
      expect(CanMessage.fromWire(null), CanMessage.denied);
    });
  });

  group('Relationship / NetworkProfile fromJson', () {
    Map<String, dynamic> profileJson() => {
          'id': 'u1',
          'full_name': 'Dr. Ada Vance',
          'headline': 'Interventional Cardiologist',
          'specialty': 'Cardiology',
          'location_label': 'Boston, MA',
          'avatar_color': '2',
          'avatar_url': null,
          'avatar_presigned_url': null,
          'about': 'Loves stents.',
          'years_of_experience': 12,
          'skills': ['Angioplasty', 'Echo'],
          'degree': '2nd',
          'connection_state': 'pending_incoming',
          'mutual_count': 4,
          'can_message': 'request',
          'context_label': '4 mutual connections',
        };

    test('flat relationship fields parse onto NetworkProfile', () {
      final p = NetworkProfile.fromJson(profileJson());
      expect(p.id, 'u1');
      expect(p.fullName, 'Dr. Ada Vance');
      expect(p.headline, 'Interventional Cardiologist');
      expect(p.about, 'Loves stents.');
      expect(p.yearsOfExperience, 12);
      expect(p.skills, ['Angioplasty', 'Echo']);
      expect(p.initials, 'DV'); // first+last word initials (honorific naive)
      expect(p.avatarIndex, 2); // from avatar_color hint
      expect(p.relationship.degree, ConnectionDegree.second);
      expect(p.relationship.connectionState, RelationshipState.pendingIncoming);
      expect(p.relationship.canMessage, CanMessage.request);
      expect(p.relationship.mutualCount, 4);
      expect(p.relationship.contextLabel, '4 mutual connections');
    });

    test('copyWith swaps relationship, keeps profile fields', () {
      final p = NetworkProfile.fromJson(profileJson());
      final flipped = p.copyWith(
        relationship: p.relationship
            .copyWith(connectionState: RelationshipState.connected),
      );
      expect(flipped.relationship.connectionState, RelationshipState.connected);
      expect(flipped.fullName, p.fullName);
      expect(flipped.skills, p.skills);
    });

    test('sparse/garbage payload never throws', () {
      final p = NetworkProfile.fromJson({'id': 'x', 'degree': 'bogus'});
      expect(p.fullName, '');
      expect(p.skills, isEmpty);
      expect(p.relationship.degree, ConnectionDegree.out);
      expect(p.relationship.connectionState, RelationshipState.none);
      expect(p.relationship.canMessage, CanMessage.denied);
      expect(p.avatarIndex, isNonNegative);
    });
  });

  group('PersonCard / Invitation fromJson', () {
    test('PersonCard parses tolerantly', () {
      final c = PersonCard.fromJson({
        'id': 'p1',
        'full_name': 'Dr. Ben Cho',
        'specialty': 'Neurology',
        'degree': '1st',
        'mutual_count': 3,
      });
      expect(c.initials, 'DC'); // "Dr. Ben Cho" → first+last word initials
      expect(c.degree, ConnectionDegree.first);
      expect(c.mutualCount, 3);
    });

    test('Invitation parses nested sender + flat recipient', () {
      final inv = Invitation.fromJson({
        'id': 'i1',
        'sender': {'id': 's1', 'full_name': 'Dr. Sender'},
        'recipient_id': 'r1',
        'recipient_name': 'Dr. Recipient',
        'status': 'pending',
        'message': 'Hello!',
        'created_at': '2026-07-25T00:00:00Z',
      });
      expect(inv.id, 'i1');
      expect(inv.sender?.id, 's1');
      expect(inv.sender?.fullName, 'Dr. Sender');
      expect(inv.recipient?.id, 'r1');
      expect(inv.status, InvitationStatus.pending);
      expect(inv.message, 'Hello!');
      expect(inv.createdAt, isNotNull);
    });
  });
}
