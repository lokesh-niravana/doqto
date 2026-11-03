import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';

/// Abstraction over the platform push-token source (FCM/APNs). The real
/// firebase_messaging-backed implementation slots in later via env/config;
/// until then [StubPushTokenProvider] keeps the registration plumbing wired
/// end-to-end without any Firebase dependency.
abstract class PushTokenProvider {
  /// Current device push token, or null when none is available (stub, or
  /// permissions denied).
  Future<String?> getToken();

  /// Emits whenever the platform rotates the token — each emission must be
  /// re-registered with the backend.
  Stream<String> get onTokenRefresh;
}

/// No-op provider used until real FCM/APNs wiring lands.
class StubPushTokenProvider implements PushTokenProvider {
  @override
  Future<String?> getToken() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream<String>.empty();
}

/// Apple hands the APNs device token to the app asynchronously, some time
/// after launch. Asking Firebase for its token before that throws
/// `apns-token-not-set`, which is how every iPhone ended up with no device
/// row on the server and no pushes (2026-11-03). Poll until it arrives.
const apnsWaitDelays = <Duration>[
  Duration(milliseconds: 300), Duration(milliseconds: 500),
  Duration(milliseconds: 700), Duration(seconds: 1), Duration(seconds: 1),
  Duration(seconds: 2), Duration(seconds: 2), Duration(seconds: 3),
  Duration(seconds: 4), Duration(seconds: 5),
]; // ≈ 20 s, then the caller's own retry schedule takes over

/// Reads [read] until it yields a non-empty value or [delays] run out.
Future<String?> waitForApnsToken(
  Future<String?> Function() read, {
  List<Duration> delays = apnsWaitDelays,
}) async {
  String? t;
  try {
    t = await read();
  } catch (_) {}
  for (final d in delays) {
    if (t != null && t.isNotEmpty) break;
    await Future<void>.delayed(d);
    try {
      t = await read();
    } catch (_) {}
  }
  return (t == null || t.isEmpty) ? null : t;
}

/// Real FCM-backed provider. On iOS firebase_messaging bridges the APNs token
/// to an FCM token, so the backend only ever deals with FCM tokens.
class FirebasePushTokenProvider implements PushTokenProvider {
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;

  @override
  Future<String?> getToken() async {
    final perm = await _fcm.requestPermission(alert: true, badge: true, sound: true);
    if (perm.authorizationStatus == AuthorizationStatus.denied) return null;
    if (Platform.isIOS) {
      // No APNs token yet → no FCM token. Null tells the caller to retry.
      final apns = await waitForApnsToken(_fcm.getAPNSToken);
      if (apns == null) return null;
    }
    return _fcm.getToken();
  }

  @override
  Stream<String> get onTokenRefresh => _fcm.onTokenRefresh;
}
