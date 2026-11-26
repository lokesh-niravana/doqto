import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:doqto_app/ui/screens/media/image_markup_screen.dart';

/// Markup step before a photo is sent. The point of the test is the pixels:
/// what the user blocked out must be gone from the file that gets sent.
void main() {
  late Directory tmp;
  late File source;
  const w = 200, h = 120;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('doqto-markup-');
    // Gradient with high-frequency detail so pixelate/redact are measurable.
    final im = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final v = ((x ~/ 2) % 2 == 0) ? 230 : 40; // 2-px stripes
        im.setPixelRgb(x, y, v, (y * 2) % 256, 128);
      }
    }
    source = File('${tmp.path}/src.png')..writeAsBytesSync(img.encodePng(im));
  });

  tearDownAll(() => tmp.delete(recursive: true));

  bool doneEnabled(WidgetTester tester) {
    final f = find.byKey(const ValueKey('markup-done'));
    if (f.evaluate().isEmpty) return false;
    return tester.widget<TextButton>(f).onPressed != null;
  }

  /// Opens the editor on a 600x400 window, runs [drive] once the image has
  /// decoded, then waits for the route to pop. Returns what it popped.
  Future<File?> open(WidgetTester tester, Future<void> Function() drive) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    File? out = File('unset');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            key: const ValueKey('open'),
            onPressed: () async => out = await showImageMarkup(ctx, source, outputDir: tmp),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      for (var i = 0; i < 300 && !doneEnabled(tester); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
      expect(doneEnabled(tester), isTrue, reason: 'image decoded → Done enabled');
      await drive();
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find.byKey(const ValueKey('markup-done')).evaluate().isEmpty) break;
      }
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    return out;
  }

  /// Canvas rect on screen, and a mapper from image pixels to screen points.
  (Rect, Offset Function(double, double)) canvasMap(WidgetTester tester) {
    final r = tester.getRect(find.byKey(const ValueKey('markup-canvas')));
    final s = r.width / w;
    return (r, (x, y) => Offset(r.left + x * s, r.top + y * s));
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    final steps = 6;
    for (var i = 1; i <= steps; i++) {
      await g.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await g.up();
    await tester.pump();
  }

  img.Image decode(File f) => img.decodeJpg(f.readAsBytesSync())!;

  testWidgets('Block out paints the region black in the saved JPEG', (tester) async {
    final out = await open(tester, () async {
      await tester.tap(find.byKey(const ValueKey('markup-tool-block')));
      await tester.pump();
      final (_, at) = canvasMap(tester);
      await drag(tester, at(20, 20), at(100, 70));
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('markup-undo'))).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('markup-done')));
    });
    expect(out, isNotNull);
    final d = decode(out!);
    expect(d.width, w);
    expect(d.height, h);
    final inside = d.getPixel(60, 45);
    expect(inside.r, lessThan(20));
    expect(inside.g, lessThan(20));
    expect(inside.b, lessThan(20));
    final outside = d.getPixel(150, 100);
    expect(outside.r + outside.g + outside.b, greaterThan(150), reason: 'rest of the photo untouched');
  });

  testWidgets('Pixelate leaves uniform blocks, not the stripes', (tester) async {
    final out = await open(tester, () async {
      await tester.tap(find.byKey(const ValueKey('markup-tool-pixelate')));
      await tester.pump();
      final (_, at) = canvasMap(tester);
      await drag(tester, at(10, 10), at(190, 110));
      await tester.tap(find.byKey(const ValueKey('markup-done')));
    });
    final d = decode(out!);
    // Source alternates 230/40 every 2 px; a 5-px mosaic cell flattens that.
    final a = d.getPixel(60, 60), b = d.getPixel(62, 60);
    expect((a.r - b.r).abs(), lessThan(40), reason: 'stripes averaged away');
  });

  testWidgets('Pen stroke changes pixels along its path; undo removes it', (tester) async {
    final out = await open(tester, () async {
      await tester.tap(find.byKey(const ValueKey('markup-color-red')));
      await tester.pump();
      final (_, at) = canvasMap(tester);
      await drag(tester, at(20, 60), at(180, 60));
      // Second stroke, then undo it: only the first should remain.
      await drag(tester, at(20, 100), at(180, 100));
      await tester.tap(find.byKey(const ValueKey('markup-undo')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('markup-done')));
    });
    final d = decode(out!);
    final onLine = d.getPixel(100, 60);
    expect(onLine.r, greaterThan(180));
    expect(onLine.g, lessThan(120), reason: 'red pen where the stroke went');
    final undone = d.getPixel(100, 100);
    expect(undone.b, closeTo(128, 30), reason: 'undone stroke left no trace');
  });

  testWidgets('Text tool places a label through the dialog', (tester) async {
    final out = await open(tester, () async {
      await tester.tap(find.byKey(const ValueKey('markup-tool-text')));
      await tester.pump();
      final (_, at) = canvasMap(tester);
      await tester.tapAt(at(30, 30));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('markup-text-input')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('markup-text-input')), 'Rx');
      await tester.tap(find.byKey(const ValueKey('markup-text-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('markup-done')));
    });
    expect(out, isNotNull);
    expect(out!.path, endsWith('.jpg'));
    expect(decode(out).width, w);
  });

  testWidgets('Done with no edits and Cancel both pop null and write nothing', (tester) async {
    final before = tmp.listSync().length;
    var out = await open(tester, () async {
      await tester.tap(find.byKey(const ValueKey('markup-done')));
    });
    expect(out, isNull);
    out = await open(tester, () async {
      await tester.tap(find.byKey(const ValueKey('markup-cancel')));
    });
    expect(out, isNull);
    expect(tmp.listSync().length, before);
  });

  testWidgets('Cancel with edits asks first: Keep editing stays, Discard pops null', (tester) async {
    final before = tmp.listSync().length;
    final out = await open(tester, () async {
      final (_, at) = canvasMap(tester);
      await drag(tester, at(20, 60), at(180, 60));
      await tester.tap(find.byKey(const ValueKey('markup-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Keep editing'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('markup-keep-editing')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('markup-canvas')), findsOneWidget);
      expect(find.byKey(const ValueKey('markup-discard')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('markup-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('markup-discard')));
    });
    expect(out, isNull);
    expect(tmp.listSync().length, before);
  });

  testWidgets('tool row fits a 320pt phone at 3x text; every tool stays 44pt', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(3)),
        child: child!,
      ),
      home: ImageMarkupScreen(source: source, outputDir: tmp),
    ));
    await tester.runAsync(() async {
      for (var i = 0; i < 300 && !doneEnabled(tester); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(tester.takeException(), isNull);
    for (final t in ['pen', 'highlighter', 'text', 'block', 'pixelate']) {
      final r = tester.getRect(find.byKey(ValueKey('markup-tool-$t')));
      expect(r.width, greaterThanOrEqualTo(44), reason: t);
      expect(r.height, greaterThanOrEqualTo(44), reason: t);
      expect(r.right, lessThanOrEqualTo(320), reason: t);
    }
  });
}
