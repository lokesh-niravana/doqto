import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../models/notification_settings.dart';

/// Plays a bundled notification tone (batch 6): the picker's preview and the
/// in-app "conversation tones" receive sound. Behind an interface so widget
/// tests never touch an audio session.
abstract class TonePlayer {
  /// Plays `assets/tones/<tone>.wav`; a no-op for `default` / `none`.
  Future<void> play(String tone);

  Future<void> stop();

  Future<void> dispose();
}

class JustAudioTonePlayer implements TonePlayer {
  AudioPlayer? _player;

  @override
  Future<void> play(String tone) async {
    final asset = NotificationTones.assetFor(tone);
    if (asset == null) return;
    try {
      final p = _player ??= AudioPlayer();
      await p.stop();
      await p.setAsset(asset);
      await p.seek(Duration.zero);
      // Not awaited: play() completes when the clip ends.
      p.play().catchError((_) {});
    } catch (_) {
      // A missing asset or audio session hiccup must never break settings.
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
  }
}

/// Test double: records what was asked for.
class FakeTonePlayer implements TonePlayer {
  final List<String> played = [];
  int stops = 0;

  @override
  Future<void> play(String tone) async => played.add(tone);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {}
}

final tonePlayerProvider = Provider<TonePlayer>((ref) {
  final p = JustAudioTonePlayer();
  ref.onDispose(p.dispose);
  return p;
});
