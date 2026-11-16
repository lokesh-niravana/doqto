import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Copy message text (batch 4). On iOS the text goes on the pasteboard with
/// `UIPasteboard.localOnly`, so Universal Clipboard never ships PHI to the
/// doctor's other Apple devices (ios/Runner/AppDelegate.swift, channel
/// `doqto/clipboard`). Elsewhere, the plain system clipboard.
abstract class AppClipboard {
  Future<void> copy(String text);
}

class SystemClipboard implements AppClipboard {
  const SystemClipboard();

  static const _channel = MethodChannel('doqto/clipboard');

  @override
  Future<void> copy(String text) async {
    if (!kIsWeb && Platform.isIOS) {
      try {
        await _channel.invokeMethod<void>('setLocalOnly', {'text': text});
        return;
      } on MissingPluginException {
        // Older Runner without the channel: fall through.
      } on PlatformException {
        // Fall through to the plain clipboard rather than lose the copy.
      }
    }
    await Clipboard.setData(ClipboardData(text: text));
  }
}

class FakeClipboard implements AppClipboard {
  final List<String> copied = [];

  @override
  Future<void> copy(String text) async => copied.add(text);
}
