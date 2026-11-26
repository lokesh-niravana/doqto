import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/data/services/media_native.dart';

// Save to Photos tells a refusal apart from a failed write: iOS answers
// true / false / a `photo_access_denied` error, Android only true / false.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('doqto/media');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<SaveToPhotosResult> saveWith(Future<Object?> Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    return ChannelMediaNative().saveToPhotos('/tmp/a.jpg');
  }

  test('true is saved', () async {
    expect(await saveWith((_) async => true), SaveToPhotosResult.saved);
  });

  test('false (failed write, or Android) is failed', () async {
    expect(await saveWith((_) async => false), SaveToPhotosResult.failed);
  });

  test('photo_access_denied is denied', () async {
    expect(
      await saveWith((_) async => throw PlatformException(code: 'photo_access_denied')),
      SaveToPhotosResult.denied,
    );
  });

  test('any other platform error is failed', () async {
    expect(
      await saveWith((_) async => throw PlatformException(code: 'boom')),
      SaveToPhotosResult.failed,
    );
  });
}
