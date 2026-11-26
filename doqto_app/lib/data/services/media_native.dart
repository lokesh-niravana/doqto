import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/media_settings.dart';

/// A video's poster frame plus what the player needs to know about it.
class VideoPoster {
  final Uint8List jpeg;
  final int width;
  final int height;
  final int durationSec;
  const VideoPoster({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.durationSec,
  });
}

/// How a save into the system photo library ended. [denied] is the user's
/// own setting (photo access refused or restricted), which only Settings can
/// change; [failed] is everything else.
enum SaveToPhotosResult { saved, failed, denied }

/// The phone's own media tools, behind one MethodChannel (`doqto/media`) in
/// AppDelegate.swift / MainActivity.kt. No plugin: AVFoundation, Photos,
/// VisionKit and Network are system frameworks, so nothing here can bring
/// back the embedded binary framework behind the ITMS-90111 rejections.
abstract class MediaNative {
  /// First-frame JPEG of a video (AVAssetImageGenerator /
  /// MediaMetadataRetriever), scaled to at most [maxSide] px.
  Future<VideoPoster?> videoPoster(String path, {int maxSide = 720});

  /// Save a photo or video file into the system photo library.
  Future<SaveToPhotosResult> saveToPhotos(String path);

  /// iOS: VisionKit document camera → PDF written to [outputPath]. False when
  /// the user cancelled; null when the device has no scanner (Android).
  Future<bool?> scanDocument(String outputPath);

  /// True when camera access has been refused or restricted in Settings.
  /// Reads the status only; never shows the permission prompt.
  Future<bool> cameraAccessDenied();

  Future<NetworkType> networkType();

  /// Route voice-note playback to the earpiece (true) or the speaker.
  Future<void> setEarpiece(bool earpiece);

  /// Proximity sensor: true while the phone is at the ear. Monitoring runs
  /// only while the stream has a listener.
  Stream<bool> get proximity;
}

class ChannelMediaNative implements MediaNative {
  ChannelMediaNative() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'proximity') _proximity.add(call.arguments == true);
    });
  }

  static const _channel = MethodChannel('doqto/media');
  late final _proximity = StreamController<bool>.broadcast(
    onListen: () => _invoke<void>('proximityStart'),
    onCancel: () => _invoke<void>('proximityStop'),
  );

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    if (kIsWeb) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null; // widget tests, older native builds
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<VideoPoster?> videoPoster(String path, {int maxSide = 720}) async {
    final r = await _invoke<Map<dynamic, dynamic>>('videoPoster', {'path': path, 'maxSide': maxSide});
    final jpeg = r?['jpeg'];
    if (r == null || jpeg is! Uint8List) return null;
    return VideoPoster(
      jpeg: jpeg,
      width: (r['width'] as num?)?.toInt() ?? 0,
      height: (r['height'] as num?)?.toInt() ?? 0,
      durationSec: (((r['durationMs'] as num?)?.toDouble() ?? 0) / 1000).round(),
    );
  }

  /// The native side's error code for refused photo-library access (the
  /// same code image_picker uses).
  static const photoAccessDeniedCode = 'photo_access_denied';

  /// Not through [_invoke]: that swallows PlatformException, and the refusal
  /// arrives as one. iOS answers true / false / a `photo_access_denied`
  /// error; Android (and an older iOS build) answers only true / false.
  @override
  Future<SaveToPhotosResult> saveToPhotos(String path) async {
    if (kIsWeb) return SaveToPhotosResult.failed;
    try {
      final ok = await _channel.invokeMethod<Object?>('saveToPhotos', {'path': path});
      return ok == true ? SaveToPhotosResult.saved : SaveToPhotosResult.failed;
    } on MissingPluginException {
      return SaveToPhotosResult.failed;
    } on PlatformException catch (e) {
      return e.code == photoAccessDeniedCode
          ? SaveToPhotosResult.denied
          : SaveToPhotosResult.failed;
    }
  }

  @override
  Future<bool?> scanDocument(String outputPath) =>
      _invoke<bool>('scanDocument', {'path': outputPath});

  @override
  Future<bool> cameraAccessDenied() async =>
      await _invoke<bool>('cameraAccessDenied') ?? false;

  @override
  Future<NetworkType> networkType() async {
    final s = await _invoke<String>('networkType');
    return switch (s) {
      'cellular' => NetworkType.cellular,
      'none' => NetworkType.none,
      _ => NetworkType.wifi, // unknown channel (tests, desktop) → generous
    };
  }

  @override
  Future<void> setEarpiece(bool earpiece) => _invoke<void>('setEarpiece', {'earpiece': earpiece});

  @override
  Stream<bool> get proximity => _proximity.stream;
}
