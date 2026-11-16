import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/websocket_client.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/repositories/network_repository.dart';
import 'package:doqto_app/data/services/network_cache.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_socket.dart';

PersonCard _card(String id) =>
    PersonCard.fromJson({'id': id, 'full_name': 'Dr $id', 'degree': 'second'});

Invitation _received(String id, String from) => Invitation.fromJson({
      'id': id,
      'sender': {'id': from, 'full_name': 'Dr $from'},
      'recipient': {'id': 'me', 'full_name': 'Me'},
      'status': 'pending',
    });

Invitation _sent(String id, String to) => Invitation.fromJson({
      'id': id,
      'sender': {'id': 'me', 'full_name': 'Me'},
      'recipient': {'id': to, 'full_name': 'Dr $to'},
      'status': 'pending',
    });

/// In-memory network: lists mutate the way the server would, and every read
/// is counted so tests can tell a local patch from a refetch.
class _Repo extends NetworkRepository {
  _Repo() : super(ApiClient());

  final received = <Invitation>[_received('i1', 'u2'), _received('i2', 'u3')];
  final sent = <Invitation>[_sent('s1', 'u4')];
  final connections = <PersonCard>[_card('u5')];
  final suggestionList = <PersonCard>[_card('u2'), _card('u4'), _card('u9')];
  final profileState = <String, String>{};

  final calls = <String, int>{};
  void _count(String k) => calls[k] = (calls[k] ?? 0) + 1;

  @override
  Future<NetworkProfile> getProfile(String userId) async {
    _count('profile:$userId');
    return NetworkProfile.fromJson({
      'id': userId,
      'full_name': 'Dr $userId',
      'connection_state': profileState[userId] ?? 'none',
      'degree': 'second',
      'can_message': 'request',
      'is_colleague': false,
    });
  }

  @override
  Future<CursorPage<Invitation>> listInvitations({
    String? direction,
    String? status,
    String? cursor,
  }) async {
    _count('invitations:$direction');
    return CursorPage(List.of(direction == 'sent' ? sent : received), null);
  }

  @override
  Future<CursorPage<PersonCard>> listConnections({String? q, String? cursor}) async {
    _count('connections');
    return CursorPage(List.of(connections), null);
  }

  @override
  Future<CursorPage<PersonCard>> suggestions({String? cursor, int? limit}) async {
    _count('suggestions');
    return CursorPage(List.of(suggestionList), null);
  }

  @override
  Future<Invitation> sendInvitation(String recipientId, {String? message}) async {
    _count('send');
    final inv = _sent('s-$recipientId', recipientId);
    sent.add(inv);
    return inv;
  }

  @override
  Future<void> acceptInvitation(String invitationId) async {
    _count('accept');
    final inv = received.firstWhere((i) => i.id == invitationId);
    received.remove(inv);
    connections.add(_card(inv.sender!.id));
  }

  @override
  Future<void> ignoreInvitation(String invitationId) async {
    _count('ignore');
    received.removeWhere((i) => i.id == invitationId);
  }

  @override
  Future<void> withdrawInvitation(String invitationId) async {
    _count('withdraw');
    sent.removeWhere((i) => i.id == invitationId);
  }

  @override
  Future<void> removeConnection(String userId) async {
    _count('remove');
    connections.removeWhere((p) => p.id == userId);
  }

  @override
  Future<void> block(String userId) async {
    _count('block');
    connections.removeWhere((p) => p.id == userId);
  }
}

/// No Hive in unit tests.
class _NoCache extends NetworkCache {
  @override
  List<PersonCard>? connections() => null;
  @override
  Future<void> putConnections(List<PersonCard> list) async {}
}

void main() {
  late _Repo repo;
  late FakeSocket socket;
  late ProviderContainer c;

  setUp(() {
    repo = _Repo();
    socket = FakeSocket();
    c = ProviderContainer(overrides: [
      websocketClientProvider.overrideWithValue(socket),
      networkRepositoryProvider.overrideWithValue(repo),
      networkCacheProvider.overrideWithValue(_NoCache()),
      realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
    ]);
  });
  tearDown(() => c.dispose());

  Future<void> warm() async {
    await c.read(invitationsProvider.future);
    await c.read(sentInvitationsProvider.future);
    await c.read(connectionsProvider.future);
    await c.read(suggestionsProvider.future);
    await c.read(relationshipProvider('u2').future);
    await settle();
  }

  List<String> inbox() =>
      c.read(invitationsProvider).value!.map((i) => i.id).toList();
  List<String> sentIds() =>
      c.read(sentInvitationsProvider).value!.map((i) => i.id).toList();
  List<String> conns() =>
      c.read(connectionsProvider).value!.map((p) => p.id).toList();
  List<String> suggs() =>
      c.read(suggestionsProvider).value!.map((p) => p.id).toList();
  RelationshipState rel(String id) =>
      c.read(relationshipProvider(id)).value!.relationship.connectionState;

  group('the other party acts (socket events)', () {
    test('they withdraw: the card leaves the inbox at once', () async {
      await warm();
      // Simulate the server having already removed it, then the event.
      repo.received.removeWhere((i) => i.id == 'i1');
      socket.emit(WsEventServer.invitationWithdrawn,
          {'invitation_id': 'i1', 'sender_id': 'u2'});
      await settle();
      expect(inbox(), ['i2']);
      expect(rel('u2'), RelationshipState.none, reason: 'profile flips too');
    });

    test('they invite: profile shows Accept/Ignore, suggestion goes', () async {
      await warm();
      repo.received.add(_received('i3', 'u9'));
      socket.emit(WsEventServer.invitationReceived,
          {'invitation_id': 'i3', 'sender_id': 'u9', 'sender_name': 'Dr u9'});
      await settle();
      expect(inbox(), contains('i3'));
      expect(suggs(), isNot(contains('u9')));
      // A profile we already had open for the sender flips without refetch.
      socket.emit(WsEventServer.invitationReceived, {'sender_id': 'u2'});
      await settle();
      expect(rel('u2'), RelationshipState.pendingIncoming);
      expect(repo.calls['profile:u2'], 1);
    });

    test('they accept: Message button, sent list, connections, suggestions',
        () async {
      await warm();
      await c.read(relationshipProvider('u4').future);
      repo.sent.clear();
      repo.connections.add(_card('u4'));
      socket.emit(WsEventServer.invitationAccepted,
          {'invitation_id': 's1', 'user_id': 'u4', 'user_name': 'Dr u4'});
      await settle();
      expect(sentIds(), isEmpty);
      expect(rel('u4'), RelationshipState.connected);
      expect(conns(), contains('u4'));
      expect(suggs(), isNot(contains('u4')));
    });

    test('they remove the connection: list and profile update', () async {
      await warm();
      await c.read(relationshipProvider('u5').future);
      repo.profileState['u5'] = 'connected';
      repo.connections.clear();
      socket.emit(WsEventServer.connectionRemoved, {'user_id': 'u5'});
      await settle();
      expect(conns(), isEmpty);
      expect(rel('u5'), RelationshipState.none);
    });

    test('a profile edit refetches that profile and the connections list',
        () async {
      await warm();
      final before = repo.calls['connections']!;
      socket.emit(WsEventServer.profileUpdated, {'user_id': 'u2'});
      await settle();
      expect(repo.calls['profile:u2'], 2);
      expect(repo.calls['connections'], before + 1);
    });

    test('a reconnect refetches every list once', () async {
      await warm();
      final before = Map.of(repo.calls);
      socket.emitState(WsConnState.connected);
      await settle();
      expect(repo.calls['invitations:received'], before['invitations:received']! + 1);
      expect(repo.calls['invitations:sent'], before['invitations:sent']! + 1);
      expect(repo.calls['connections'], before['connections']! + 1);
      expect(repo.calls['suggestions'], before['suggestions']! + 1);
    });
  });

  group('I act (cross-provider fan-out, same device)', () {
    test('accept from the profile clears the inbox and grows connections',
        () async {
      await warm();
      repo.profileState['u2'] = 'pending_incoming';
      c.invalidate(relationshipProvider('u2'));
      await c.read(relationshipProvider('u2').future);

      await c.read(relationshipProvider('u2').notifier).accept();
      await settle();
      expect(rel('u2'), RelationshipState.connected);
      expect(inbox(), ['i2'], reason: 'the Network badge drops too');
      expect(conns(), contains('u2'));
      expect(suggs(), isNot(contains('u2')));
    });

    test('ignore from the profile clears the inbox', () async {
      await warm();
      repo.profileState['u2'] = 'pending_incoming';
      c.invalidate(relationshipProvider('u2'));
      await c.read(relationshipProvider('u2').future);
      await c.read(relationshipProvider('u2').notifier).ignore();
      await settle();
      expect(inbox(), ['i2']);
    });

    test('invite from the profile updates Sent and suggestions', () async {
      await warm();
      await c.read(relationshipProvider('u9').future);
      await c.read(relationshipProvider('u9').notifier).invite();
      await settle();
      expect(rel('u9'), RelationshipState.pendingOutgoing);
      expect(sentIds(), contains('s-u9'));
      expect(suggs(), isNot(contains('u9')));
    });

    test('withdraw from the profile drops the Sent row', () async {
      await warm();
      await c.read(relationshipProvider('u4').future);
      repo.profileState['u4'] = 'pending_outgoing';
      c.invalidate(relationshipProvider('u4'));
      await c.read(relationshipProvider('u4').future);
      await c.read(relationshipProvider('u4').notifier).withdraw();
      await settle();
      expect(sentIds(), isEmpty);
      expect(rel('u4'), RelationshipState.none);
    });

    test('accept from the inbox flips an open profile', () async {
      await warm();
      final inv = c.read(invitationsProvider).value!.first; // from u2
      await c.read(invitationsProvider.notifier).accept(inv);
      await settle();
      expect(rel('u2'), RelationshipState.connected);
      expect(conns(), contains('u2'));
      expect(suggs(), isNot(contains('u2')));
    });

    test('a row Connect (no profile) updates Sent and an open profile',
        () async {
      await warm();
      await c.read(relationshipProvider('u9').future);
      await c.read(sentInvitationsProvider.notifier).send('u9');
      await settle();
      expect(sentIds(), contains('s-u9'));
      expect(rel('u9'), RelationshipState.pendingOutgoing);
      expect(suggs(), isNot(contains('u9')));
    });

    test('withdraw from the Sent tab flips an open profile', () async {
      await warm();
      await c.read(relationshipProvider('u4').future);
      final inv = c.read(sentInvitationsProvider).value!.single;
      await c.read(sentInvitationsProvider.notifier).withdraw(inv);
      await settle();
      expect(sentIds(), isEmpty);
      expect(rel('u4'), RelationshipState.none);
    });

    test('remove / block from the connections list flip an open profile',
        () async {
      await warm();
      await c.read(relationshipProvider('u5').future);
      repo.profileState['u5'] = 'connected';
      c.invalidate(relationshipProvider('u5'));
      await c.read(relationshipProvider('u5').future);
      await c.read(connectionsProvider.notifier).remove('u5');
      await settle();
      expect(conns(), isEmpty);
      expect(rel('u5'), RelationshipState.none);
      expect(repo.calls['remove'], 1);

      await c.read(connectionsProvider.notifier).block('u2');
      await settle();
      expect(repo.calls['block'], 1);
      expect(inbox(), ['i2'], reason: 'their pending request is gone');
      expect(suggs(), isNot(contains('u2')));
    });

    test('a failed accept restores the inbox and rethrows', () async {
      await warm();
      final inv = _received('ghost', 'u8');
      await expectLater(
        c.read(invitationsProvider.notifier).accept(inv),
        throwsA(anything),
      );
      await settle();
      expect(inbox(), ['i1', 'i2']);
    });
  });

  test('patching a profile that is not open never fetches it', () async {
    await warm();
    expect(repo.calls.containsKey('profile:u3'), isFalse);
    socket.emit(WsEventServer.invitationWithdrawn,
        {'invitation_id': 'i2', 'sender_id': 'u3'});
    await settle();
    expect(repo.calls.containsKey('profile:u3'), isFalse);
  });
}
