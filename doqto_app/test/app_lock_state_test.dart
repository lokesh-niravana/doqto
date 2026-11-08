import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/state/app_lock_state.dart';
import 'package:doqto_app/state/settings_state.dart';

/// App lock (batch 6): the lifecycle → cover / lock state machine, with a
/// fake authenticator and an injectable clock.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLocalAuthenticator auth;
  late DateTime now;
  late ProviderContainer c;

  ProviderContainer make() => ProviderContainer(overrides: [
        localAuthenticatorProvider.overrideWithValue(auth),
        appLockClockProvider.overrideWithValue(() => now),
      ]);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    auth = FakeLocalAuthenticator();
    now = DateTime.utc(2026, 11, 8, 12);
    c = make();
  });
  tearDown(() => c.dispose());

  test('lock off: leaving covers, returning uncovers, never locks', () async {
    final n = c.read(appLockProvider.notifier);
    expect(c.read(appLockProvider), const AppLockState());
    n.onLeftForeground();
    expect(c.read(appLockProvider).covered, isTrue);
    now = now.add(const Duration(hours: 2));
    n.onResumed();
    await settle();
    expect(c.read(appLockProvider), const AppLockState());
    expect(auth.prompts, isEmpty);
  });

  test('lock on: a short trip away stays unlocked, a long one locks and prompts',
      () async {
    final n = c.read(appLockProvider.notifier); // built with the lock off
    await c.read(appSettingsProvider.notifier).setAppLock(true);
    await c.read(appSettingsProvider.notifier).setAppLockTimeout(AppLockTimeout.oneMinute);

    n.onLeftForeground();
    now = now.add(const Duration(seconds: 30));
    n.onResumed();
    await settle();
    expect(c.read(appLockProvider).locked, isFalse, reason: '30 s < 1 min');
    expect(auth.prompts, isEmpty);

    auth.result = false;
    n.onLeftForeground();
    now = now.add(const Duration(seconds: 61));
    n.onResumed();
    await settle();
    expect(c.read(appLockProvider).locked, isTrue);
    expect(auth.prompts, [AppLockNotifier.unlockReason]);

    // The prompt failed: still locked. A retry that succeeds opens it.
    auth.result = true;
    expect(await n.unlock(), isTrue);
    expect(c.read(appLockProvider).locked, isFalse);
    expect(c.read(appLockProvider).prompting, isFalse);
  });

  test('"Immediately" locks on any resume', () async {
    final n = c.read(appLockProvider.notifier);
    await c.read(appSettingsProvider.notifier).setAppLock(true);
    auth.result = false;
    n.onLeftForeground();
    n.onResumed();
    await settle();
    expect(c.read(appLockProvider).locked, isTrue);
  });

  test('cold start with the lock on starts locked and prompts once', () async {
    c.dispose();
    c = make();
    await c.read(appSettingsProvider.notifier).setAppLock(true);
    // Build the lock provider only now, as the app would after settings load.
    expect(c.read(appLockProvider).locked, isTrue);
    await settle();
    expect(auth.prompts, hasLength(1));
    expect(c.read(appLockProvider).locked, isFalse, reason: 'fake auth succeeded');
  });

  test('the biometric sheet itself does not restart the away clock', () async {
    // While prompting, iOS sends inactive → resumed around the sheet.
    final slow = _SlowAuth();
    final c2 = ProviderContainer(overrides: [
      localAuthenticatorProvider.overrideWithValue(slow),
      appLockClockProvider.overrideWithValue(() => now),
    ]);
    addTearDown(c2.dispose);
    final n2 = c2.read(appLockProvider.notifier);
    await c2.read(appSettingsProvider.notifier).setAppLock(true);
    n2.onLeftForeground();
    n2.onResumed(); // locks and starts prompting
    await settle();
    expect(c2.read(appLockProvider).prompting, isTrue);
    n2.onLeftForeground();
    expect(c2.read(appLockProvider).covered, isFalse, reason: 'ignored while prompting');
    slow.finish(true);
    await settle();
    expect(c2.read(appLockProvider).locked, isFalse);
  });

  test('clearLock drops a pending lock (settings turned it off)', () async {
    final n = c.read(appLockProvider.notifier);
    await c.read(appSettingsProvider.notifier).setAppLock(true);
    auth.result = false;
    n.onLeftForeground();
    n.onResumed();
    await settle();
    expect(c.read(appLockProvider).locked, isTrue);
    n.clearLock();
    expect(c.read(appLockProvider).locked, isFalse);
  });
}

class _SlowAuth implements LocalAuthenticator {
  final List<Completer<bool>> _pending = [];
  @override
  Future<bool> canAuthenticate() async => true;
  @override
  Future<bool> authenticate(String reason) {
    final c = Completer<bool>();
    _pending.add(c);
    return c.future;
  }

  void finish(bool ok) {
    for (final p in _pending) {
      p.complete(ok);
    }
    _pending.clear();
  }
}
