import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Live voice-note transcription is PHI leaving the phone if the OS sends the
/// audio to Apple's or Google's speech servers, and neither signs a BAA. So
/// the recogniser runs on the device or not at all (compliance/README.md).
///
/// `speech_to_text`'s `onDevice: true` is enforced on iOS (the plugin refuses
/// when `supportsOnDeviceRecognition` is false) but on Android it is only a
/// preference: below API 31, or when no offline model is installed, the
/// plugin silently falls back to the default cloud recogniser. So before
/// anything listens, the `doqto/speech` channel (AppDelegate / MainActivity)
/// asks the OS directly, and the answer gates transcription.
abstract class OnDeviceSpeech {
  static const channel = MethodChannel('doqto/speech');

  /// Platform channels never answer in a widget test (no host); a recording
  /// must not wait on this.
  static const _timeout = Duration(seconds: 2);

  /// The options every `listen()` in the app uses. Nothing else constructs
  /// `SpeechListenOptions` (guarded by `test/on_device_speech_test.dart`).
  static SpeechListenOptions listenOptions() => SpeechListenOptions(
        listenMode: ListenMode.dictation,
        onDevice: true,
      );

  /// True only when the OS confirms recognition can run locally. Any doubt
  /// (no host, timeout, old OS, no offline model) is a no: the note still
  /// records, just without a transcript.
  static Future<bool> available() async {
    try {
      final ok = await channel
          .invokeMethod<bool>('onDeviceAvailable')
          .timeout(_timeout);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
