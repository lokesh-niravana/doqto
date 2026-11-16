import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import 'settings_state.dart';

/// Face ID / Touch ID / device passcode behind an interface so widget tests
/// never touch the local_auth plugin.
abstract class LocalAuthenticator {
  /// Whether the device can authenticate at all (biometrics enrolled OR a
  /// passcode set).
  Future<bool> canAuthenticate();

  /// True when the person proved it is them. Never throws.
  Future<bool> authenticate(String reason);
}

class LocalAuthAuthenticator implements LocalAuthenticator {
  LocalAuthAuthenticator({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();
  final LocalAuthentication _auth;

  @override
  Future<bool> canAuthenticate() async {
    try {
      // isDeviceSupported covers "passcode set, no biometrics" too.
      return await _auth.isDeviceSupported() || await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // biometricOnly false: the device passcode is an acceptable
        // fallback, and the only option on phones without biometrics.
        biometricOnly: false,
        // Keep the system prompt alive across the background trip it
        // itself causes (stickyAuth in local_auth 2.x).
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      // NotAvailable / PasscodeNotSet / LockedOut and friends: treat as
      // "could not prove", never as "unlocked".
      debugPrint('app lock: authenticate failed: $e');
      return false;
    }
  }
}

/// Test double: scripted answers, records prompts.
class FakeLocalAuthenticator implements LocalAuthenticator {
  FakeLocalAuthenticator({this.available = true, this.result = true});
  bool available;
  bool result;
  final List<String> prompts = [];

  @override
  Future<bool> canAuthenticate() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts.add(reason);
    return result;
  }
}

/// `--dart-define=FAKE_LOCAL_AUTH=true` swaps in the scripted double so the
/// on-device walk (integration_test/settings_test.dart) can enable the lock
/// and show the gate on a simulator with no enrolled biometrics. Never set
/// for a release build.
final localAuthenticatorProvider = Provider<LocalAuthenticator>((ref) =>
    const bool.fromEnvironment('FAKE_LOCAL_AUTH')
        ? FakeLocalAuthenticator()
        : LocalAuthAuthenticator());

/// Wall clock for the lock timeout; tests inject a fake.
final appLockClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

@immutable
class AppLockState {
  /// Covered: the app is not in the foreground (inactive / paused / hidden),
  /// so an opaque cover hides PHI from the task switcher.
  final bool covered;

  /// Locked: a re-auth is owed before the content shows again.
  final bool locked;

  /// A prompt is in flight (avoid stacking two system dialogs).
  final bool prompting;

  const AppLockState({
    this.covered = false,
    this.locked = false,
    this.prompting = false,
  });

  AppLockState copyWith({bool? covered, bool? locked, bool? prompting}) =>
      AppLockState(
        covered: covered ?? this.covered,
        locked: locked ?? this.locked,
        prompting: prompting ?? this.prompting,
      );

  @override
  bool operator ==(Object other) =>
      other is AppLockState &&
      other.covered == covered &&
      other.locked == locked &&
      other.prompting == prompting;

  @override
  int get hashCode => Object.hash(covered, locked, prompting);
}

/// App lock (batch 6). Observes the widgets lifecycle: leaving the foreground
/// covers the app and stamps the time; coming back uncovers it and, when the
/// lock is on and the timeout has elapsed, locks until [unlock] succeeds. A
/// cold start with the lock on starts locked.
class AppLockNotifier extends Notifier<AppLockState> with WidgetsBindingObserver {
  DateTime? _leftAt;

  static const unlockReason = 'Unlock Doqto';

  @override
  AppLockState build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    final settings = ref.read(appSettingsProvider);
    if (settings.appLock) {
      // Locked from launch; the gate prompts on first frame.
      scheduleMicrotask(unlock);
      return const AppLockState(locked: true);
    }
    return const AppLockState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        onLeftForeground();
      case AppLifecycleState.detached:
        break;
    }
  }

  /// The app left the foreground (also called by tests).
  void onLeftForeground() {
    // A biometric sheet makes the app `inactive` too; do not restart the
    // clock while we are the ones asking.
    if (state.prompting) return;
    _leftAt ??= ref.read(appLockClockProvider)();
    if (!state.covered) state = state.copyWith(covered: true);
  }

  /// The app is back in the foreground (also called by tests).
  void onResumed() {
    final leftAt = _leftAt;
    _leftAt = null;
    final settings = ref.read(appSettingsProvider);
    var next = state.copyWith(covered: false);
    if (settings.appLock && !next.locked && leftAt != null && !state.prompting) {
      final away = ref.read(appLockClockProvider)().difference(leftAt);
      if (away.inSeconds >= settings.appLockTimeout.seconds) {
        next = next.copyWith(locked: true);
      }
    }
    state = next;
    if (state.locked && !state.prompting) unawaited(unlock());
  }

  /// Prompt Face ID / Touch ID / passcode; clears the lock on success.
  Future<bool> unlock() async {
    if (state.prompting) return false;
    state = state.copyWith(prompting: true);
    bool ok;
    try {
      ok = await ref.read(localAuthenticatorProvider).authenticate(unlockReason);
    } finally {
      state = state.copyWith(prompting: false);
    }
    if (ok) state = state.copyWith(locked: false);
    return ok;
  }

  /// Settings turned the lock off: nothing to owe any more.
  void clearLock() {
    _leftAt = null;
    if (state.locked) state = state.copyWith(locked: false);
  }
}

final appLockProvider =
    NotifierProvider<AppLockNotifier, AppLockState>(AppLockNotifier.new);
