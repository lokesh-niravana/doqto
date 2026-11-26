import 'package:flutter/services.dart';

/// The app is laid out for portrait. Only full-screen media (a photo, a
/// video) is worth turning the phone for, so those screens call
/// [enterMedia] when they open and [leaveMedia] when they close. Info.plist
/// keeps the landscape orientations so that is possible.
///
/// Media screens nest (the photo viewer opens the video player), so the
/// lock only returns when the last one has closed.
class AppOrientation {
  AppOrientation._();

  static int _mediaDepth = 0;

  static Future<void> lockPortrait() =>
      SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);

  static void enterMedia() {
    _mediaDepth++;
    if (_mediaDepth == 1) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  static void leaveMedia() {
    if (_mediaDepth == 0) return;
    _mediaDepth--;
    if (_mediaDepth == 0) lockPortrait();
  }
}
