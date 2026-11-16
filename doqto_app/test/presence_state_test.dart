import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/websocket_client.dart';
import 'package:doqto_app/data/models/presence.dart';
import 'package:doqto_app/data/repositories/user_repository.dart';
import 'package:doqto_app/state/presence_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_socket.dart';

class _Repo extends UserRepository {
  _Repo() : super(ApiClient());
  final calls = <List<String>>[];
  var answer = <PresenceInfo>[];

  @override
  Future<List<PresenceInfo>> fetchPresence(List<String> ids) async {
    calls.add(List.of(ids));
    return answer;
  }
}

void main() {
  late _Repo repo;
  late FakeSocket socket;
  late ProviderContainer c;

  setUp(() {
    repo = _Repo();
    socket = FakeSocket();
    c = ProviderContainer(overrides: [
      userRepositoryProvider.overrideWithValue(repo),
      websocketClientProvider.overrideWithValue(socket),
      realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
    ]);
  });
  tearDown(() => c.dispose());

  test('track fetches new ids once and exposes them per user', () async {
    repo.answer = [
      const PresenceInfo(userId: 'a', status: PresenceStatus.online),
      PresenceInfo(
          userId: 'b', status: PresenceStatus.offline, lastSeenAt: DateTime.utc(2026, 1, 1)),
    ];
    final n = c.read(presenceProvider.notifier);
    await n.track(['a', 'b']);
    await n.track(['a']); // already tracked: no call
    expect(repo.calls, [
      ['a', 'b']
    ]);
    expect(c.read(presenceOfProvider('a'))?.isOnline, isTrue);
    expect(c.read(presenceOfProvider('b'))?.lastSeenAt, DateTime.utc(2026, 1, 1));
    expect(c.read(presenceOfProvider('zzz')), isNull);
  });

  test('presence_update frames patch the map and keep the last seen', () async {
    repo.answer = [
      PresenceInfo(
          userId: 'a', status: PresenceStatus.away, lastSeenAt: DateTime.utc(2026, 1, 1)),
    ];
    await c.read(presenceProvider.notifier).track(['a']);
    socket.emit(WsEventServer.presenceUpdate, {'user_id': 'a', 'status': 'online'});
    await settle();
    final online = c.read(presenceOfProvider('a'))!;
    expect(online.isOnline, isTrue);
    expect(online.lastSeenAt, DateTime.utc(2026, 1, 1), reason: 'kept from before');

    socket.emit(WsEventServer.presenceUpdate, {
      'user_id': 'a',
      'status': 'away',
      'last_seen_at': '2026-02-02T10:00:00+00:00',
    });
    await settle();
    final away = c.read(presenceOfProvider('a'))!;
    expect(away.status, PresenceStatus.away);
    expect(away.lastSeenAt, DateTime.utc(2026, 2, 2, 10));
  });

  test('a frame for an untracked doctor is still kept', () async {
    c.read(presenceProvider.notifier);
    socket.emit(WsEventServer.presenceUpdate, {'user_id': 'x', 'status': 'online'});
    await settle();
    expect(c.read(presenceOfProvider('x'))?.isOnline, isTrue);
  });

  test('reconnect and refresh refetch everyone tracked', () async {
    final n = c.read(presenceProvider.notifier);
    await n.track(['a', 'b']);
    socket.emitState(WsConnState.connected);
    await settle();
    expect(repo.calls.length, 2);
    expect(repo.calls.last.toSet(), {'a', 'b'});
    await n.refresh();
    expect(repo.calls.length, 3);
  });

  test('a failed fetch keeps the previous snapshot', () async {
    repo.answer = [const PresenceInfo(userId: 'a', status: PresenceStatus.online)];
    final n = c.read(presenceProvider.notifier);
    await n.track(['a']);
    final failing = _FailingRepo();
    final c2 = ProviderContainer(overrides: [
      userRepositoryProvider.overrideWithValue(failing),
      websocketClientProvider.overrideWithValue(socket),
    ]);
    addTearDown(c2.dispose);
    await c2.read(presenceProvider.notifier).track(['a']);
    expect(c2.read(presenceOfProvider('a')), isNull);
    expect(c.read(presenceOfProvider('a'))?.isOnline, isTrue);
  });
}

class _FailingRepo extends UserRepository {
  _FailingRepo() : super(ApiClient());
  @override
  Future<List<PresenceInfo>> fetchPresence(List<String> ids) async =>
      throw ApiException('offline');
}
