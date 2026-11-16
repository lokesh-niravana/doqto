import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/di/providers.dart';
import '../data/services/chat_media_cache.dart';
import '../data/models/message.dart';

/// Playback speeds a voice note cycles through (batch 5).
const kVoiceSpeeds = [1.0, 1.5, 2.0];

/// The audio engine behind voice-note playback, so widget tests can drive a
/// fake instead of just_audio's platform channel.
abstract class VoiceAudioEngine {
  Stream<Duration> get position;
  Stream<Duration?> get duration;
  Stream<bool> get playing;

  /// Fires once each time a note reaches its end.
  Stream<void> get completed;

  Future<Duration?> load(String pathOrUrl, {required bool isFile});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> stop();
  Future<void> dispose();
}

class JustAudioEngine implements VoiceAudioEngine {
  final _player = AudioPlayer();
  late final _completed = _player.processingStateStream
      .where((s) => s == ProcessingState.completed)
      .map((_) {});

  @override
  Stream<Duration> get position => _player.positionStream;
  @override
  Stream<Duration?> get duration => _player.durationStream;
  @override
  Stream<bool> get playing => _player.playingStream;
  @override
  Stream<void> get completed => _completed;

  @override
  Future<Duration?> load(String pathOrUrl, {required bool isFile}) =>
      isFile ? _player.setFilePath(pathOrUrl) : _player.setUrl(pathOrUrl);
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> dispose() => _player.dispose();
}

final voiceAudioEngineProvider = Provider<VoiceAudioEngine>((ref) {
  final engine = JustAudioEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

/// One voice note plays at a time, app-wide. Holds which note, where it is,
/// the speed (sticky across notes) and auto-plays the next note of the same
/// chat when one ends. Bubbles read it and call [toggle] / [seek] /
/// [cycleSpeed]. The earpiece follows the proximity sensor while playing.
class VoicePlayback extends ChangeNotifier {
  VoicePlayback(this._ref) {
    final engine = _ref.read(voiceAudioEngineProvider);
    _subs.add(engine.position.listen((p) {
      _position = p;
      notifyListeners();
    }));
    _subs.add(engine.duration.listen((d) {
      if (d != null) {
        _duration = d;
        notifyListeners();
      }
    }));
    _subs.add(engine.playing.listen((p) {
      if (_playing != p) {
        _playing = p;
        _syncProximity();
        notifyListeners();
      }
    }));
    _subs.add(engine.completed.listen((_) => _onCompleted()));
  }

  final Ref _ref;
  final _subs = <StreamSubscription<dynamic>>[];

  String? _messageId;
  String? _conversationId;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  double _speed = kVoiceSpeeds.first;
  StreamSubscription<bool>? _proximity;
  Future<Duration?> Function()? _loader;

  /// The note currently loaded (playing or paused), or null.
  String? get messageId => _messageId;
  bool get playing => _playing;
  bool get loading => _loading;
  double get speed => _speed;
  Duration get duration => _duration;

  bool isCurrent(String messageId) => _messageId == messageId;
  bool isPlaying(String messageId) => isCurrent(messageId) && _playing;
  bool isLoading(String messageId) => isCurrent(messageId) && _loading;
  Duration positionOf(String messageId) => isCurrent(messageId) ? _position : Duration.zero;

  /// 0.0–1.0 through [messageId], given its known [fallbackSec] length when
  /// the engine has not reported one yet.
  double progressOf(String messageId, int fallbackSec) {
    if (!isCurrent(messageId)) return 0;
    final total = _duration > Duration.zero ? _duration : Duration(seconds: fallbackSec);
    if (total <= Duration.zero) return 0;
    return (_position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
  }

  /// What a chat should auto-play after [messageId] ends: the next newer
  /// voice note from the same conversation. Set by the thread when it
  /// renders (it knows the order); null = stop at the end.
  Message? Function(String endedId)? nextAfter;

  /// Start / pause [messageId]. [resolve] returns a local file (preferred) or
  /// a URL when the note must stream.
  Future<void> toggle(
    String messageId,
    String conversationId,
    Future<({String path, bool isFile})> Function() resolve,
  ) async {
    final engine = _ref.read(voiceAudioEngineProvider);
    if (isCurrent(messageId)) {
      if (_playing) {
        await engine.pause();
      } else {
        if (_duration > Duration.zero && _position >= _duration) await engine.seek(Duration.zero);
        await engine.play();
      }
      return;
    }
    await _start(messageId, conversationId, resolve);
  }

  Future<void> _start(
    String messageId,
    String conversationId,
    Future<({String path, bool isFile})> Function() resolve,
  ) async {
    final engine = _ref.read(voiceAudioEngineProvider);
    try {
      await engine.stop();
    } catch (_) {}
    _messageId = messageId;
    _conversationId = conversationId;
    _position = Duration.zero;
    _duration = Duration.zero;
    _loading = true;
    notifyListeners();
    try {
      final src = await resolve();
      if (_messageId != messageId) return; // superseded while resolving
      _loader = () => engine.load(src.path, isFile: src.isFile);
      final d = await _loader!();
      if (d != null) _duration = d;
      await engine.setSpeed(_speed);
      _loading = false;
      notifyListeners();
      await engine.play();
    } catch (e) {
      debugPrint('[VoicePlayback] load failed: $e');
      if (_messageId == messageId) {
        _messageId = null;
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Drag on the waveform: 0.0–1.0 of the note.
  Future<void> seekFraction(String messageId, double fraction, int fallbackSec) async {
    if (!isCurrent(messageId)) return;
    final total = _duration > Duration.zero ? _duration : Duration(seconds: fallbackSec);
    final target = total * fraction.clamp(0.0, 1.0);
    _position = target;
    notifyListeners();
    await _ref.read(voiceAudioEngineProvider).seek(target);
  }

  /// 1× → 1.5× → 2× → 1×. Applies at once and to every later note.
  Future<void> cycleSpeed() async {
    final i = kVoiceSpeeds.indexOf(_speed);
    _speed = kVoiceSpeeds[(i + 1) % kVoiceSpeeds.length];
    notifyListeners();
    try {
      await _ref.read(voiceAudioEngineProvider).setSpeed(_speed);
    } catch (_) {}
  }

  Future<void> stop() async {
    _messageId = null;
    _conversationId = null;
    _playing = false;
    _position = Duration.zero;
    notifyListeners();
    try {
      await _ref.read(voiceAudioEngineProvider).stop();
    } catch (_) {}
  }

  /// Auto-play the next note in the same chat, if the thread knows one.
  void _onCompleted() {
    final ended = _messageId;
    final conv = _conversationId;
    if (ended == null || conv == null) return;
    final next = nextAfter?.call(ended);
    _position = _duration;
    notifyListeners();
    if (next == null || next.conversationId != conv) return;
    final resolver = resolverFor;
    if (resolver == null) return;
    unawaited(_start(next.id, conv, () => resolver(next)));
  }

  /// How to get a note's audio (set by the thread, which has the cache).
  Future<({String path, bool isFile})> Function(Message m)? resolverFor;

  /// Earpiece while the phone is at the ear, speaker otherwise. Best effort;
  /// the channel is a no-op where unsupported.
  void _syncProximity() {
    final native = _ref.read(mediaNativeProvider);
    if (_playing && _proximity == null) {
      try {
        _proximity = native.proximity.listen((near) {
          unawaited(native.setEarpiece(near));
        });
      } catch (_) {}
    } else if (!_playing && _proximity != null) {
      unawaited(_proximity!.cancel());
      _proximity = null;
      unawaited(native.setEarpiece(false));
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _proximity?.cancel();
    super.dispose();
  }
}

// ChangeNotifierProvider disposes the notifier itself.
final voicePlaybackProvider = ChangeNotifierProvider<VoicePlayback>((ref) => VoicePlayback(ref));

/// Local file for a cached voice note, else a presigned URL to stream.
/// Works from a provider ([Ref]) or a widget ([WidgetRef]) — both `read`.
Future<({String path, bool isFile})> resolveVoiceSource(
  dynamic ref,
  Message m, {
  required Future<String> Function() url,
  bool download = false,
}) async {
  final ChatMediaCache cache = ref.read(chatMediaCacheProvider);
  final hit = await cache.cached(m.id);
  if (hit != null) return (path: hit.path, isFile: true);
  if (download) {
    final File f = await cache.media(m.id, url, conversationId: m.conversationId);
    return (path: f.path, isFile: true);
  }
  return (path: await url(), isFile: false);
}
