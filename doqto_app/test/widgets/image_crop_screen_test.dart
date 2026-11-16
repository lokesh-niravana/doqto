import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:doqto_app/ui/screens/media/image_crop_screen.dart';

/// Crop step (before a photo is saved or sent): Done returns a JPEG file on
/// disk that decodes; Cancel returns null; the circle variant hides the
/// aspect presets and still produces a square.
void main() {
  late Directory tmp;
  late File source;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('doqto-crop-');
    // 64×48 PNG with a gradient so the crop has real pixels to cut.
    final im = img.Image(width: 64, height: 48);
    for (var y = 0; y < 48; y++) {
      for (var x = 0; x < 64; x++) {
        im.setPixelRgb(x, y, x * 4, y * 5, 128);
      }
    }
    source = File('${tmp.path}/src.png')..writeAsBytesSync(img.encodePng(im));
  });

  tearDownAll(() => tmp.delete(recursive: true));

  bool doneEnabled(WidgetTester tester) {
    final f = find.byKey(const ValueKey('crop-done'));
    if (f.evaluate().isEmpty) return false;
    return tester.widget<TextButton>(f).onPressed != null;
  }

  Future<File?> open(
    WidgetTester tester, {
    bool circle = false,
    required Future<void> Function() drive,
  }) async {
    File? out = File('unset');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () async => out = await showImageCrop(
              ctx,
              source,
              circle: circle,
              outputDir: tmp,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Image parsing and the crop itself run in isolates: real async, so
    // wait on the wall clock until Done lights up, then until the route pops.
    await tester.runAsync(() async {
      for (var i = 0; i < 300 && !doneEnabled(tester); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
      expect(doneEnabled(tester), isTrue, reason: 'image parsed → Done enabled');
      await drive();
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find.byKey(const ValueKey('crop-done')).evaluate().isEmpty) break;
      }
    });
    // Let the route's exit transition finish (a plain pump: the editor's
    // spinner would keep pumpAndSettle busy for the whole timeout).
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    return out;
  }

  testWidgets('Done writes a decodable JPEG and pops it', (tester) async {
    final out = await open(tester, drive: () async {
      expect(find.byKey(const ValueKey('crop-aspect-Free')), findsOneWidget);
      expect(find.byKey(const ValueKey('crop-aspect-1:1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('crop-done')));
    });
    expect(out, isNotNull);
    expect(out!.path, endsWith('.jpg'));
    expect(out.existsSync(), isTrue);
    final decoded = img.decodeJpg(out.readAsBytesSync());
    expect(decoded, isNotNull);
    expect(decoded!.width, greaterThan(0));
    expect(decoded.height, greaterThan(0));
    expect(find.byKey(const ValueKey('crop-done')), findsNothing, reason: 'screen popped');
  });

  testWidgets('Cancel pops null and writes nothing new', (tester) async {
    final before = tmp.listSync().length;
    final out = await open(tester, drive: () async {
      await tester.tap(find.byKey(const ValueKey('crop-cancel')));
    });
    expect(out, isNull);
    expect(tmp.listSync().length, before);
  });

  testWidgets('circle: no aspect presets, output is square', (tester) async {
    final out = await open(tester, circle: true, drive: () async {
      expect(find.byKey(const ValueKey('crop-aspect-Free')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('crop-done')));
    });
    expect(out, isNotNull);
    final decoded = img.decodeJpg(out!.readAsBytesSync())!;
    expect(decoded.width, decoded.height);
  });
}
