// On-device check for chat photos (build 42): the real flutter_cache_manager
// backend, real HTTP, the real iOS file-protection channel.
//
//   flutter test integration_test/media_cache_test.dart -d <simulator> \
//     [--dart-define=SHOT_DIR=<folder on this Mac>]
//
// A tiny HTTP server inside the test plays S3 and counts downloads. Every
// getFileUrl returns a NEW signed-looking URL, exactly like the API does, so a
// URL-keyed cache would download on every visit.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/services/chat_media_cache.dart';
import 'package:doqto_app/ui/widgets/attachment_bubbles.dart';

const _shotDir = String.fromEnvironment('SHOT_DIR');

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File('$_shotDir/shot_$name.png')
      .writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1200]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// A 600x400 "x-ray" so the screenshot shows a real photo.
Future<List<int>> _photo() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, 600, 400),
      Paint()..color = const Color(0xFF0B2545));
  c.drawCircle(const Offset(300, 200), 130,
      Paint()..color = const Color(0xFF8DA9C4));
  c.drawCircle(const Offset(300, 200), 60,
      Paint()..color = const Color(0xFFEEF4ED));
  final img = await rec.endRecording().toImage(600, 400);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('a photo downloads once, survives leaving and relaunching, '
      'is file-protected, and is wiped on sign-out', (t) async {
    final photo = await _photo();
    var hits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) {
      hits++;
      req.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(photo)
        ..close();
    });
    var urls = 0;
    Future<String> signedUrl() async =>
        'http://127.0.0.1:${server.port}/media/m1.png?X-Amz-Signature=${++urls}';

    // Start from an empty cache, as after a fresh install.
    final cache = ChatMediaCache(CacheManagerMediaBackend());
    await cache.clear();

    // Keyed by cache instance: a new instance is a new app launch, so the
    // whole tree (and every bubble's State) must start fresh.
    Widget thread(ChatMediaCache c, {required bool open}) => ProviderScope(
          key: ObjectKey(c),
          overrides: [chatMediaCacheProvider.overrideWithValue(c)],
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const Text('Dr. Patel')),
              body: open
                  ? ListView(children: [
                      ImageBubble(
                        messageId: 'm1',
                        getFileUrl: signedUrl,
                        isMine: false,
                        timestamp: DateTime(2026, 11, 3, 9, 41),
                      ),
                    ])
                  : const Center(child: Text('Chats')),
            ),
          ),
        );

    // 1. First view downloads.
    await t.pumpWidget(thread(cache, open: true));
    await _settle(t);
    expect(find.byType(Image), findsOneWidget);
    expect(hits, 1);
    await _shot(t, 'media_first_view');

    // 2. Leave and come back five times: no URL, no download, no spinner.
    for (var i = 0; i < 5; i++) {
      await t.pumpWidget(thread(cache, open: false));
      await t.pump();
      await t.pumpWidget(thread(cache, open: true));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await _settle(t, 300);
    }
    expect(hits, 1, reason: 'revisits must read the phone');
    expect(urls, 1);

    // 3. "Relaunch": a new cache object with an empty memory map still finds
    //    the file on disk.
    final relaunched = ChatMediaCache(CacheManagerMediaBackend());
    await t.pumpWidget(thread(relaunched, open: true));
    await _settle(t);
    expect(find.byType(Image), findsOneWidget);
    expect(hits, 1, reason: 'a relaunch must not download again');
    await _shot(t, 'media_after_relaunch');

    // 4. The native protection channel is registered and accepts the file.
    final file = relaunched.peek('m1')!;
    await const MethodChannel('doqto/file_protection')
        .invokeMethod<void>('complete', {'path': file.path});
    expect(file.readAsBytesSync(), photo, reason: 'readable while unlocked');

    // 5. Sign-out wipe: the file is gone and the next view downloads again.
    await relaunched.clear();
    expect(file.existsSync(), isFalse);
    final afterWipe = ChatMediaCache(CacheManagerMediaBackend());
    await t.pumpWidget(thread(afterWipe, open: false));
    await t.pump();
    await t.pumpWidget(thread(afterWipe, open: true));
    await _settle(t);
    expect(hits, 2);
    await afterWipe.clear();

    // ignore: avoid_print
    print('MEDIA_CACHE downloads=$hits urlsResolved=$urls file=${file.path}');
  });
}
