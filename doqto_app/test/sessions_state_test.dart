import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/session.dart';
import 'package:doqto_app/data/repositories/settings_repository.dart';
import 'package:doqto_app/state/sessions_state.dart';

import 'support/fake_socket.dart';

DeviceSession session(String id, {bool current = false, String? name}) => DeviceSession(
      id: id,
      deviceName: name ?? 'Device $id',
      platform: DevicePlatform.ios,
      appVersion: '1.0.0+45',
      ip: null,
      createdAt: DateTime.utc(2026, 11, 1),
      lastSeenAt: DateTime.utc(2026, 11, 8, 11, 55),
      current: current,
    );

class FakeSettingsRepo extends SettingsRepository {
  FakeSettingsRepo() : super(ApiClient());
  List<DeviceSession> sessions = [session('me', current: true), session('s2'), session('s3')];
  int listCalls = 0;
  final List<String> revoked = [];
  int revokeOthersCalls = 0;
  bool fail = false;

  @override
  Future<List<DeviceSession>> listSessions() async {
    listCalls++;
    return List.of(sessions);
  }

  @override
  Future<void> revokeSession(String id) async {
    if (fail) throw ApiException('session_not_found', status: 404);
    revoked.add(id);
    sessions.removeWhere((s) => s.id == id);
  }

  @override
  Future<int> revokeOtherSessions() async {
    if (fail) throw ApiException('boom', status: 500);
    revokeOthersCalls++;
    final n = sessions.where((s) => !s.current).length;
    sessions.removeWhere((s) => !s.current);
    return n;
  }
}

void main() {
  late FakeSettingsRepo repo;
  late FakeSocket socket;
  late ProviderContainer c;

  setUp(() {
    repo = FakeSettingsRepo();
    socket = FakeSocket();
    c = ProviderContainer(overrides: [
      settingsRepositoryProvider.overrideWithValue(repo),
      websocketClientProvider.overrideWithValue(socket),
    ]);
  });
  tearDown(() => c.dispose());

  List<String> ids() => [for (final s in c.read(sessionsProvider).value!) s.id];

  test('loads my sessions', () async {
    final list = await c.read(sessionsProvider.future);
    expect(list.map((s) => s.id), ['me', 's2', 's3']);
    expect(list.first.current, isTrue);
  });

  test('revoke is optimistic and calls the server', () async {
    await c.read(sessionsProvider.future);
    final f = c.read(sessionsProvider.notifier).revoke('s2');
    expect(ids(), ['me', 's3'], reason: 'gone before the server answers');
    await f;
    expect(repo.revoked, ['s2']);
  });

  test('a failed revoke rolls the row back and rethrows', () async {
    await c.read(sessionsProvider.future);
    repo.fail = true;
    await expectLater(c.read(sessionsProvider.notifier).revoke('s2'), throwsA(isA<ApiException>()));
    expect(ids(), ['me', 's2', 's3']);
  });

  test('revokeOthers keeps only this device and returns the count', () async {
    await c.read(sessionsProvider.future);
    final n = await c.read(sessionsProvider.notifier).revokeOthers();
    expect(n, 2);
    expect(ids(), ['me']);
    expect(repo.revokeOthersCalls, 1);
  });

  test('WS session_created / session_revoked refetch the list', () async {
    await c.read(sessionsProvider.future);
    expect(repo.listCalls, 1);
    repo.sessions.add(session('s4', name: 'Pixel 9'));
    socket.emit(WsEventServer.sessionCreated, {'session_id': 's4'});
    await Future<void>.delayed(Duration.zero);
    expect(repo.listCalls, 2);
    expect(ids(), contains('s4'));

    repo.sessions.removeWhere((s) => s.id == 's3');
    socket.emit(WsEventServer.sessionRevoked, {'session_id': 's3'});
    await Future<void>.delayed(Duration.zero);
    expect(repo.listCalls, 3);
    expect(ids(), isNot(contains('s3')));
  });

  test('formatLastActive buckets', () {
    final now = DateTime.utc(2026, 11, 8, 12);
    expect(formatLastActive(now.subtract(const Duration(seconds: 20)), now: now), 'Active now');
    expect(formatLastActive(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
    expect(formatLastActive(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
    expect(formatLastActive(now.subtract(const Duration(days: 2)), now: now), '2 d ago');
    expect(formatLastActive(now.subtract(const Duration(days: 30)), now: now), contains('/'));
  });
}
