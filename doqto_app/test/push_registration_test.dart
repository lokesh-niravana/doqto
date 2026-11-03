import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/user_repository.dart';
import 'package:doqto_app/data/services/push_token_provider.dart';
import 'package:doqto_app/state/auth_state.dart';

// 2026-11-03: an iPhone could stay unregistered for push forever. The app
// asked Firebase for its token before Apple had issued the APNs token, the
// error was swallowed, and nothing retried. These tests pin the recovery.

class _Tokens implements PushTokenProvider {
  _Tokens(this.answers);
  final List<String?> answers; // one per getToken call; last repeats
  int calls = 0;
  final refresh = StreamController<String>.broadcast();

  @override
  Future<String?> getToken() async {
    final a = answers[calls < answers.length ? calls : answers.length - 1];
    calls++;
    return a;
  }

  @override
  Stream<String> get onTokenRefresh => refresh.stream;
}

class _Users implements UserRepository {
  final registered = <String>[];
  int failuresLeft = 0;

  @override
  Future<void> registerPushToken({
    required String token,
    required DevicePlatform platform,
  }) async {
    if (failuresLeft > 0) {
      failuresLeft--;
      throw Exception('network down');
    }
    registered.add(token);
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('${i.memberName}');
}

User _me() => User.fromJson({
      'id': 'u1',
      'phone': '+15555550100',
      'full_name': 'Dr Lokesh',
      'npi_number': '1851408082',
      'role': 'doctor',
      'created_at': DateTime(2026).toIso8601String(),
    });

void main() {
  late List<Duration> saved;
  setUp(() {
    saved = AuthNotifier.pushRetryDelays;
    AuthNotifier.pushRetryDelays = const [
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
    ];
  });
  tearDown(() => AuthNotifier.pushRetryDelays = saved);

  ProviderContainer container(_Tokens t, _Users u) {
    final c = ProviderContainer(overrides: [
      pushTokenProviderProvider.overrideWithValue(t),
      userRepositoryProvider.overrideWithValue(u),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('no token at launch is retried until one arrives', () async {
    final t = _Tokens([null, null, 'fcm-1']);
    final u = _Users();
    final c = container(t, u);

    await c.read(authProvider.notifier).syncPushToken();

    expect(u.registered, ['fcm-1']);
    expect(t.calls, 3);
  });

  test('a failed API call is retried', () async {
    final t = _Tokens(['fcm-1']);
    final u = _Users()..failuresLeft = 2;
    final c = container(t, u);

    await c.read(authProvider.notifier).syncPushToken();

    expect(u.registered, ['fcm-1']);
  });

  test('a token rotation is registered', () async {
    final t = _Tokens(['fcm-1']);
    final u = _Users();
    final c = container(t, u);
    await c.read(authProvider.notifier).syncPushToken();

    t.refresh.add('fcm-2');
    await Future<void>.delayed(Duration.zero);

    expect(u.registered, ['fcm-1', 'fcm-2']);
  });

  test('resume heals a phone that never registered, then stops nagging',
      () async {
    final t = _Tokens([null]); // every launch attempt misses
    final u = _Users();
    final c = container(t, u);
    final auth = c.read(authProvider.notifier);
    auth.setUser(_me());

    await auth.syncPushToken(); // all attempts miss
    expect(u.registered, isEmpty);

    t.answers.add('fcm-1'); // APNs is ready by the time the user comes back
    auth.onAppResumed();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(u.registered, ['fcm-1']);

    final callsAfter = t.calls;
    auth.onAppResumed(); // registered recently: no new attempt
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(t.calls, callsAfter);
  });

  test('resume does nothing for a signed-out device', () async {
    final t = _Tokens(['fcm-1']);
    final c = container(t, _Users());
    c.read(authProvider.notifier).onAppResumed();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(t.calls, 0);
  });

  test('waitForApnsToken polls until Apple hands the token over', () async {
    var reads = 0;
    final token = await waitForApnsToken(
      () async => ++reads < 4 ? null : 'apns',
      delays: const [Duration.zero, Duration.zero, Duration.zero, Duration.zero],
    );
    expect(token, 'apns');
    expect(reads, 4);
  });

  test('waitForApnsToken gives up with null, never throws', () async {
    final token = await waitForApnsToken(
      () async => throw Exception('apns-token-not-set'),
      delays: const [Duration.zero, Duration.zero],
    );
    expect(token, isNull);
  });
}
