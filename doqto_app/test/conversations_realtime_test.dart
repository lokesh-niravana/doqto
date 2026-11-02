import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/websocket_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_socket.dart';

Conversation _conv(String id) {
  final now = DateTime(2026).toIso8601String();
  return Conversation.fromJson({
    'id': id,
    'type': 'direct',
    'member_ids': ['me', 'them'],
    'created_at': now,
    'updated_at': now,
  });
}

class _Repo extends ChatRepository {
  _Repo() : super(ApiClient());
  int lists = 0;
  final convs = <Conversation>[_conv('c1')];
  @override
  Future<List<Conversation>> listConversations() async {
    lists++;
    return List.of(convs);
  }
}

class _NoCache extends ChatCache {
  @override
  List<Conversation>? conversations() => null;
  @override
  Future<void> putConversations(List<Conversation> list) async {}
}

void main() {
  late _Repo repo;
  late FakeSocket socket;
  late ProviderContainer c;

  setUp(() {
    repo = _Repo();
    socket = FakeSocket();
  });
  tearDown(() => c.dispose());

  ProviderContainer make(Duration debounce) => ProviderContainer(overrides: [
        websocketClientProvider.overrideWithValue(socket),
        chatRepositoryProvider.overrideWithValue(repo),
        chatCacheProvider.overrideWithValue(_NoCache()),
        realtimeRefreshDebounceProvider.overrideWithValue(debounce),
      ]);

  test('membership and group changes refresh the list, not just messages',
      () async {
    c = make(Duration.zero);
    await c.read(conversationsProvider.future);
    expect(repo.lists, 1);

    for (final type in [
      WsEventServer.memberRemoved,
      WsEventServer.memberAdded,
      WsEventServer.groupUpdated,
      WsEventServer.messageEdited,
      WsEventServer.messageDeleted,
      WsEventServer.messageRead,
      WsEventServer.newMessage,
    ]) {
      final before = repo.lists;
      socket.emit(type, {'conversation_id': 'c1'});
      await settle();
      expect(repo.lists, before + 1, reason: '$type should refresh');
    }
  });

  test('a removed chat disappears without a pull-to-refresh', () async {
    c = make(Duration.zero);
    await c.read(conversationsProvider.future);
    repo.convs.clear();
    socket.emit(WsEventServer.memberRemoved,
        {'conversation_id': 'c1', 'user_id': 'me'});
    await settle();
    expect(c.read(conversationsProvider).value, isEmpty);
  });

  test('events that do not change the list are ignored', () async {
    c = make(Duration.zero);
    await c.read(conversationsProvider.future);
    socket.emit(WsEventServer.typingStart, {'conversation_id': 'c1'});
    socket.emit(WsEventServer.presenceUpdate, {'user_id': 'x'});
    socket.emit(WsEventServer.heartbeatAck);
    await settle();
    expect(repo.lists, 1);
  });

  test('a burst coalesces into one refetch', () async {
    c = make(const Duration(milliseconds: 40));
    await c.read(conversationsProvider.future);
    for (var i = 0; i < 6; i++) {
      socket.emit(WsEventServer.newMessage, {'conversation_id': 'c1'});
    }
    socket.emitState(WsConnState.connected); // reconnect replay in the burst
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(repo.lists, 2);
  });
}
