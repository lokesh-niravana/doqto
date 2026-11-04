import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/data/services/outbox.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';

import 'support/fake_socket.dart';

Message _msg(String id, String sender) => Message.fromJson({
      'id': id,
      'conversation_id': 'c1',
      'sender_id': sender,
      'type': 'text',
      'content': id,
      'created_at': DateTime(2026).toIso8601String(),
    });

class _Repo extends ChatRepository {
  _Repo() : super(ApiClient());
  @override
  Future<List<Message>> listMessages(
    String conversationId, {
    DateTime? before,
    int? afterSeq,
  }) async =>
      [_msg('mine', 'me'), _msg('theirs', 'them')];
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
  late FakeSocket socket;
  late ProviderContainer c;

  setUp(() async {
    socket = FakeSocket();
    c = ProviderContainer(overrides: [
      websocketClientProvider.overrideWithValue(socket),
      chatRepositoryProvider.overrideWithValue(_Repo()),
      chatCacheProvider.overrideWithValue(_NoCache()),
      outboxProvider.overrideWithValue(_NoOutbox()),
      authProvider.overrideWith(_SignedIn.new),
    ]);
    await c.read(messagesProvider('c1').future);
  });
  tearDown(() => c.dispose());

  Message byId(String id) =>
      c.read(messagesProvider('c1')).value!.firstWhere((m) => m.id == id);

  test('my own read echo never turns my sent messages blue', () async {
    // I opened the chat: the server echoes MY read back to me.
    socket.emit(WsEventServer.messageRead,
        {'conversation_id': 'c1', 'user_id': 'me'});
    await Future<void>.delayed(Duration.zero);
    expect(byId('mine').read, isFalse, reason: 'nobody else has read it');
    expect(byId('theirs').read, isTrue);
  });

  test('the other side reading turns my messages blue', () async {
    socket.emit(WsEventServer.messageRead,
        {'conversation_id': 'c1', 'user_id': 'them'});
    await Future<void>.delayed(Duration.zero);
    expect(byId('mine').read, isTrue);
  });

  test('my own delivered ack never double-ticks my sent messages', () async {
    socket.emit(WsEventServer.messageDelivered,
        {'conversation_id': 'c1', 'user_id': 'me'});
    await Future<void>.delayed(Duration.zero);
    expect(byId('mine').delivered, isFalse);
    socket.emit(WsEventServer.messageDelivered,
        {'conversation_id': 'c1', 'user_id': 'them'});
    await Future<void>.delayed(Duration.zero);
    expect(byId('mine').delivered, isTrue);
  });
}
