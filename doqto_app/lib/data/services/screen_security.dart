import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS screenshot detection (batch 6). AppDelegate listens for
/// `userDidTakeScreenshotNotification` and invokes `taken` on the
/// `doqto/screenshot` channel; this exposes it as a stream. iOS cannot block
/// a screenshot — the app audits it against the open chat instead.
abstract class ScreenshotDetector {
  Stream<void> get taken;
}

class ChannelScreenshotDetector implements ScreenshotDetector {
  ChannelScreenshotDetector({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('doqto/screenshot') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'taken') _controller.add(null);
    });
  }

  final MethodChannel _channel;
  final _controller = StreamController<void>.broadcast();

  @override
  Stream<void> get taken => _controller.stream;

  void dispose() {
    _channel.setMethodCallHandler(null);
    _controller.close();
  }
}

/// Test double: `fire()` simulates a screenshot.
class FakeScreenshotDetector implements ScreenshotDetector {
  final _controller = StreamController<void>.broadcast();

  @override
  Stream<void> get taken => _controller.stream;

  void fire() => _controller.add(null);
}

/// Android FLAG_SECURE toggle (batch 6): blanks the app in the task switcher
/// and refuses screenshots / screen recording while on. Set ONLY while an
/// org chat with the `block_screenshots` policy is open — Play review's
/// capture must keep working everywhere else (see MainActivity.kt).
abstract class ScreenSecurity {
  Future<void> setSecure(bool secure);
}

class ChannelScreenSecurity implements ScreenSecurity {
  const ChannelScreenSecurity();
  static const _channel = MethodChannel('doqto/screen_secure');

  @override
  Future<void> setSecure(bool secure) async {
    if (kIsWeb || !Platform.isAndroid) return; // iOS has no equivalent
    try {
      await _channel.invokeMethod('set', {'secure': secure});
    } catch (_) {}
  }
}

class FakeScreenSecurity implements ScreenSecurity {
  final List<bool> calls = [];

  @override
  Future<void> setSecure(bool secure) async => calls.add(secure);
}
