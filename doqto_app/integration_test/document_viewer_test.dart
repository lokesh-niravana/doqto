// On-device check for chat documents: the real download path and the real
// native viewer, on real PDF, Word and Excel files.
//
//   flutter test integration_test/document_viewer_test.dart -d <simulator> \
//     --dart-define=DOC_DIR=<folder> --dart-define=DOC=<file name> \
//     --dart-define=SHOT_DIR=<folder on this Mac>
//
// A tiny HTTP server plays S3 and counts downloads. Flutter stops drawing
// behind a full-screen native viewer, so the test cannot pump past one: it
// opens one document per run (DOC), drops a `ready_<DOC>` marker in SHOT_DIR
// and holds for an outside `simctl io screenshot`, which also ends the run.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'package:doqto_app/ui/widgets/attachment_bubbles.dart';

const _docDir = String.fromEnvironment('DOC_DIR');
const _shotDir = String.fromEnvironment('SHOT_DIR');
const _doc = String.fromEnvironment('DOC');
// An emulator cannot read this Mac's disk, so the bytes can come in here.
const _docB64 = String.fromEnvironment('DOC_B64');

Future<void> _settle(WidgetTester t, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('each document opens from a real download, once', (t) async {
    var downloads = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      downloads++;
      final name = Uri.decodeComponent(req.uri.pathSegments.last);
      req.response.headers.contentType = ContentType.binary;
      if (_docB64.isNotEmpty) {
        req.response.add(base64Decode(_docB64));
      } else {
        await req.response.addStream(File(p.join(_docDir, name)).openRead());
      }
      await req.response.close();
    });

    const name = _doc;
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: FileBubble(
                messageId:
                    'doc-${name.hashCode}-${DateTime.now().millisecondsSinceEpoch}',
                getFileUrl: () async =>
                    'http://127.0.0.1:${server.port}/${Uri.encodeComponent(name)}',
                fileName: name,
                isMine: false,
                timestamp: DateTime(2026),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(t, 400);
    await t.tap(find.text(name));
    await t.pump();
    // Real time only from here: no frames arrive behind the viewer.
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(downloads, 1, reason: '$name downloaded once');
    if (Platform.isAndroid && !name.endsWith('.pdf')) {
      // Past the prompt, the real FileProvider grant: a bad paths file throws
      // here, whether or not this device has an app for the format.
      await _settle(t, 500);
      expect(find.text('Open outside Doqto?'), findsOneWidget);
      await t.tap(find.text('Open'));
      await _settle(t, 1500);
      expect(find.text('Could not open the file'), findsNothing);
    }
    if (Platform.isAndroid && name.endsWith('.pdf')) {
      // Flutter stays in charge here, so prove the pages really painted.
      await _settle(t, 4000);
      final images = t.widgetList<Image>(find.byType(Image)).toList();
      // ignore: avoid_print
      print('PDF images on screen: ${images.length}');
      expect(images, isNotEmpty);
      final bytes = (images.first.image as MemoryImage).bytes;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData();
      final px = data!.buffer.asUint8List();
      var dark = 0;
      for (var i = 0; i < px.length; i += 4) {
        if (px[i] < 100) dark++;
      }
      // ignore: avoid_print
      print('PDF page ${frame.image.width}x${frame.image.height} dark=$dark');
      expect(dark, greaterThan(0), reason: 'page text was rendered');
      await t.drag(find.byType(InteractiveViewer), const Offset(0, -900));
      await _settle(t, 3000);
    }
    // ignore: avoid_print
    print('READY');
    try {
      await File('$_shotDir/ready_$name').writeAsString('');
    } on FileSystemException {
      // Android: the outside script watches the log instead.
    }
    await Future<void>.delayed(const Duration(seconds: 60));
  });
}
