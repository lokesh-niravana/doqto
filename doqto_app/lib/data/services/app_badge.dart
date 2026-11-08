import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// App-icon badge number. iOS: a tiny MethodChannel in ios/Runner
/// (AppDelegate.swift) calls `UNUserNotificationCenter.setBadgeCount` (iOS
/// 16+) or `applicationIconBadgeNumber`. Android has no app-level badge API
/// without a notification: launchers badge off the notifications already
/// shown (flutter_local_notifications) and the server's `aps.badge` is iOS
/// only, so Android is a no-op here.
class AppBadge {
  static const _channel = MethodChannel('doqto/badge');

  /// Last value handed to the platform (so the sync layer can skip repeats).
  int? _last;

  Future<void> set(int count) async {
    final n = count < 0 ? 0 : count;
    if (_last == n) return;
    _last = n;
    if (kIsWeb || !Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('set', {'count': n});
    } on MissingPluginException {
      // Host without the channel (tests, older Runner): nothing to do.
    } on PlatformException {
      // Permission not granted yet — the next sync tries again.
      _last = null;
    }
  }

  Future<void> clear() => set(0);
}
