import 'dart:io';

import 'package:doqto_app/data/services/on_device_speech.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Voice transcripts are PHI. They may only be produced by a recogniser that
/// runs on the phone (no BAA with Apple/Google speech services), so every
/// listen() asks for on-device recognition and nothing listens until the OS
/// has confirmed it can do that locally.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(
    () => messenger.setMockMethodCallHandler(OnDeviceSpeech.channel, null),
  );

  test('listen options demand on-device recognition', () {
    expect(OnDeviceSpeech.listenOptions().onDevice, isTrue);
  });

  test('no answer from the host means no transcription', () async {
    expect(await OnDeviceSpeech.available(), isFalse);
  });

  test('the host answer gates transcription', () async {
    var answer = false;
    messenger.setMockMethodCallHandler(OnDeviceSpeech.channel, (call) async {
      expect(call.method, 'onDeviceAvailable');
      return answer;
    });
    expect(await OnDeviceSpeech.available(), isFalse);
    answer = true;
    expect(await OnDeviceSpeech.available(), isTrue);
  });

  test('a host error means no transcription', () async {
    messenger.setMockMethodCallHandler(
      OnDeviceSpeech.channel,
      (_) async => throw PlatformException(code: 'boom'),
    );
    expect(await OnDeviceSpeech.available(), isFalse);
  });

  test('nothing in lib/ builds its own SpeechListenOptions', () {
    final offenders = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('on_device_speech.dart'))
        .where((f) => f.readAsStringSync().contains('SpeechListenOptions('))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty,
        reason: 'use OnDeviceSpeech.listenOptions() so onDevice stays true');
  });
}
