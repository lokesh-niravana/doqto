import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/websocket_client.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/data/services/outbox.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';

import 'support/fake_socket.dart';

Map<String, dynamic> _json(
  String id,
  String sender, {
  List<Map<String, dynamic>> reactions = const [],
  String? changedAt,
  bool read = false,
  int seq = 1,
}) =>
    {
      'id': id,
      'conversation_id': 'c1',
      'sender_id': sender,
      'type': 'text',
      'content': id,
      'seq': seq,
      'read': read,
      'delivered': read,
      'created_at': '2026-11-08T10:00:00.000Z',
      'reactions': reactions,
      'changed_at': changedAt,
    };

Map<String, dynamic> _r(String emoji, List<String> users) =>
    {'emoji': emoji, 'count': users.length, 'user_ids': users};

/// Scriptable repo: each reaction call waits on a completer the test
/// resolves, so ordering and in-flight behaviour can be asserted.
class _Repo extends ChatRepository {
  _Repo() : super(ApiClient());

  List<Message> page = [Message.fromJson(_json('m1', 'them', read: true))];
  List<Message> changed = [];
  final calls = <String>[];
  final pending = <Completer<Message>>[];
  DateTime? lastChangedSince;

  @override
  Future<List<Message>> listMessages(
    String conversationId, {
    DateTime? before,
    int? afterSeq,
    DateTime? changedSince,
  }) async {
    if (changedSince != null) {
      lastChangedSince = changedSince;
      return changed;
    }
    if (afterSeq != null) return const [];
    return page;
  }

  Future<Message> _wait(String call) {
    calls.add(call);
    final c = Completer<Message>();
    pending.add(c);
    return c.future;
  }

  @override
  Future<Message> setReaction(String messageId, String emoji) =>
      _wait('set $emoji');

  @override
  Future<Message> removeReaction(String messageId) => _wait('remove');
}

class _NoCache extends ChatCache {
  @override
  List<Message>? messages(String convId) => null;
  @override
  Future<void> putMessages(String convId, List<Message> msgs) async {}
}

class _NoOutbox extends Outbox {
  @override
  List<OutboxEntry> pending({String? conversationId}) => const [];
}

class _SignedIn extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        AuthStage.signedIn,
        User.fromJson({
          'id': 'me',
          'phone': '+15550000101',
          'full_name': 'Dr A',
          'npi_number': '1234567893',
          'role': 'doctor',
          'created_at': '2026-09-05T00:00:00Z',
        }),
      );
}

void main() {
  group('MessageReaction.apply', () {
    const a = MessageReaction(emoji: '👍', userIds: ['x']);
    const b = MessageReaction(emoji: '❤️', userIds: ['y', 'z']);

    test('adds a new emoji at the end of equal counts', () {
      final out = MessageReaction.apply([a], 'me', '😂');
      expect(out.map((r) => r.emoji), ['👍', '😂']);
    });

    test('joins an existing emoji and re-sorts by count', () {
      // Tie at 2 keeps the earlier group first (matches server order).
      final tie = MessageReaction.apply([b, a], 'me', '👍');
      expect(tie.map((r) => (r.emoji, r.count)), [('❤️', 2), ('👍', 2)]);
      // Joining makes 👍 the most used → it moves to the front.
      final out = MessageReaction.apply([b, a, const MessageReaction(emoji: '😂', userIds: ['q'])], 'me', '😂');
      expect(out.map((r) => r.emoji), ['❤️', '😂', '👍']);
    });

    test('replace moves me out of my old emoji and drops empty groups', () {
      const mine = MessageReaction(emoji: '😢', userIds: ['me']);
      final out = MessageReaction.apply([a, mine], 'me', '👍');
      expect(out.map((r) => r.emoji), ['👍']);
      expect(out.single.userIds, ['x', 'me']);
    });

    test('remove (null) drops only me', () {
      const both = MessageReaction(emoji: '👍', userIds: ['x', 'me']);
      expect(MessageReaction.apply([both], 'me', null).single.userIds, ['x']);
      expect(MessageReaction.apply([const MessageReaction(emoji: '👍', userIds: ['me'])], 'me', null), isEmpty);
    });

    test('json round trip keeps reactions and changedAt', () {
      final m = Message.fromJson(_json('m', 's', reactions: [_r('👍', ['a', 'b'])], changedAt: '2026-11-08T10:00:01.000Z'));
      final back = Message.fromJson(m.toJson());
      expect(back.reactions.single.userIds, ['a', 'b']);
      expect(back.changedAt, m.changedAt);
      expect(back.myReaction('b'), '👍');
      expect(back.myReaction('c'), isNull);
    });

    test('legacy cache without reactions parses as empty', () {
      final j = _json('m', 's')..remove('reactions')..remove('changed_at');
      expect(Message.fromJson(j).reactions, isEmpty);
    });

    test('canReact: no system, tombstone, or unsent rows', () {
      expect(Message.fromJson(_json('m', 's')).canReact, isTrue);
      expect(Message.fromJson({..._json('m', 's'), 'type': 'system'}).canReact, isFalse);
      expect(Message.fromJson({..._json('m', 's'), 'deleted_at': '2026-11-08T10:00:00Z'}).canReact, isFalse);
      expect(Message.pending(clientId: 'c', conversationId: 'c1', senderId: 's', content: 'x').canReact, isFalse);
    });
  });

  group('MessagesNotifier reactions', () {
    late FakeSocket socket;
    late _Repo repo;
    late ProviderContainer c;

    setUp(() async {
      socket = FakeSocket();
      repo = _Repo();
      c = ProviderContainer(overrides: [
        websocketClientProvider.overrideWithValue(socket),
        chatRepositoryProvider.overrideWithValue(repo),
        chatCacheProvider.overrideWithValue(_NoCache()),
        outboxProvider.overrideWithValue(_NoOutbox()),
        authProvider.overrideWith(_SignedIn.new),
      ]);
      await c.read(messagesProvider('c1').future);
    });
    tearDown(() => c.dispose());

    Message m1() => c.read(messagesProvider('c1')).value!.firstWhere((m) => m.id == 'm1');
    MessagesNotifier n() => c.read(messagesProvider('c1').notifier);
    Future<void> tick() => Future<void>.delayed(Duration.zero);

    test('optimistic, then confirmed by the server', () async {
      final f = n().react('m1', '👍');
      expect(m1().myReaction('me'), '👍', reason: 'applied before the network');
      repo.pending.single.complete(Message.fromJson(
          _json('m1', 'them', reactions: [_r('👍', ['me'])], changedAt: '2026-11-08T10:00:05.000Z')));
      await f;
      expect(m1().reactions.single.userIds, ['me']);
      expect(m1().changedAt, DateTime.parse('2026-11-08T10:00:05.000Z'));
      expect(m1().read, isTrue, reason: 'ticks untouched');
    });

    test('failure restores the previous reactions and rethrows', () async {
      final f = n().react('m1', '❤️');
      expect(m1().myReaction('me'), '❤️');
      repo.pending.single.completeError(ApiException('message_deleted', status: 409));
      await expectLater(f, throwsA(isA<ApiException>()));
      expect(m1().reactions, isEmpty);
    });

    test('rapid taps collapse: one request in flight, latest wins', () async {
      final f1 = n().react('m1', '👍');
      unawaited(n().react('m1', '❤️'));
      unawaited(n().react('m1', '😂'));
      await tick();
      expect(repo.calls, ['set 👍'], reason: 'only one in flight');
      expect(m1().myReaction('me'), '😂', reason: 'UI shows the latest tap');
      repo.pending[0].complete(Message.fromJson(_json('m1', 'them', reactions: [_r('👍', ['me'])], changedAt: '2026-11-08T10:00:01.000Z')));
      await tick();
      expect(repo.calls, ['set 👍', 'set 😂'], reason: 'middle tap skipped');
      repo.pending[1].complete(Message.fromJson(_json('m1', 'them', reactions: [_r('😂', ['me'])], changedAt: '2026-11-08T10:00:02.000Z')));
      await f1;
      expect(m1().myReaction('me'), '😂');
    });

    test('ws event patches reactions only and keeps ticks', () async {
      socket.emit(WsEventServer.messageReacted, {
        'conversation_id': 'c1',
        'message_id': 'm1',
        'reactions': [_r('🙏', ['them'])],
        'changed_at': '2026-11-08T10:00:03.000Z',
        'actor_id': 'them',
        'emoji': '🙏',
      });
      await tick();
      expect(m1().reactions.single.emoji, '🙏');
      expect(m1().read, isTrue);
      expect(m1().content, 'm1');
    });

    test('stale ws event is dropped', () async {
      socket.emit(WsEventServer.messageReacted, {
        'conversation_id': 'c1', 'message_id': 'm1',
        'reactions': [_r('👍', ['them'])],
        'changed_at': '2026-11-08T10:00:10.000Z', 'actor_id': 'them', 'emoji': '👍',
      });
      socket.emit(WsEventServer.messageReacted, {
        'conversation_id': 'c1', 'message_id': 'm1',
        'reactions': <Map<String, dynamic>>[],
        'changed_at': '2026-11-08T10:00:09.000Z', 'actor_id': 'them', 'emoji': null,
      });
      await tick();
      expect(m1().reactions.single.emoji, '👍');
    });

    test('event for another conversation is ignored', () async {
      socket.emit(WsEventServer.messageReacted, {
        'conversation_id': 'other', 'message_id': 'm1',
        'reactions': [_r('👍', ['them'])],
        'changed_at': '2026-11-08T10:00:10.000Z', 'actor_id': 'them', 'emoji': '👍',
      });
      await tick();
      expect(m1().reactions, isEmpty);
    });

    test('while my request is in flight, my echo is ignored and others merge', () async {
      final f = n().react('m1', '👍');
      socket.emit(WsEventServer.messageReacted, {
        'conversation_id': 'c1', 'message_id': 'm1',
        'reactions': [_r('❤️', ['them'])],
        'changed_at': '2026-11-08T10:00:04.000Z', 'actor_id': 'them', 'emoji': '❤️',
      });
      await tick();
      expect(m1().myReaction('me'), '👍', reason: 'my pending choice survives');
      expect(m1().reactions.any((r) => r.emoji == '❤️'), isTrue);
      repo.pending.single.complete(Message.fromJson(_json('m1', 'them',
          reactions: [_r('❤️', ['them']), _r('👍', ['me'])], changedAt: '2026-11-08T10:00:05.000Z')));
      await f;
      expect(m1().reactions.length, 2);
    });

    test('reconnect pulls changed_since and applies newer rows', () async {
      repo.changed = [
        Message.fromJson(_json('m1', 'them',
            reactions: [_r('😮', ['them'])], changedAt: '2026-11-08T10:01:00.000Z')),
      ];
      socket.emitState(WsConnState.connected);
      await tick();
      await tick();
      expect(repo.lastChangedSince, isNotNull);
      expect(m1().reactions.single.emoji, '😮');
      expect(m1().read, isTrue, reason: 'catch-up keeps ticks');
    });

    test('react on an unknown or unsent message does nothing', () async {
      await n().react('nope', '👍');
      expect(repo.calls, isEmpty);
    });
  });
}
