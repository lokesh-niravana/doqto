import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../../core/di/providers.dart';
import '../screens/chat/pdf_viewer_screen.dart';

void _say(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));

/// Opens a chat document the way this phone can:
///   * iOS: QuickLook inside the app, for every format it knows;
///   * Android PDF: [PdfViewerScreen] inside the app;
///   * Android Word, Excel and the rest: the phone's installed app, after
///     saying the file is leaving Doqto. Android has no built-in renderer.
Future<void> openChatDocument(
  BuildContext context,
  WidgetRef ref, {
  required String messageId,
  required String fileName,
  required Future<String> Function() resolveUrl,
}) async {
  final store = ref.read(chatDocumentStoreProvider);
  final viewer = ref.read(documentViewerProvider);
  final File file;
  try {
    file = await store.open(messageId, fileName, resolveUrl);
  } catch (_) {
    if (context.mounted) _say(context, 'Could not download the file');
    return;
  }
  if (!context.mounted) return;
  try {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      if (!await viewer.preview(file.path) && context.mounted) {
        _say(context, 'This file type can’t be previewed');
      }
    } else if (p.extension(file.path).toLowerCase() == '.pdf') {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => PdfViewerScreen(file: file, title: fileName),
        ),
      );
    } else {
      await openOutsideDoqto(context, ref, file);
    }
  } catch (_) {
    if (context.mounted) _say(context, 'Could not open the file');
  }
}

/// Android hand-off to an installed app, with the user's say-so: from here on
/// the file is outside Doqto's protection.
Future<void> openOutsideDoqto(
  BuildContext context,
  WidgetRef ref,
  File file,
) async {
  final viewer = ref.read(documentViewerProvider);
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Open outside Doqto?'),
      content: const Text(
        'This file opens in another app on your phone. That app may keep a '
        'copy, and Doqto can’t protect it there.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if (go != true) return;
  final mime = lookupMimeType(file.path) ?? '*/*';
  final opened = await viewer.openExternally(file.path, mime);
  if (!opened && context.mounted) {
    _say(context, 'No app on this phone can open this file');
  }
}
