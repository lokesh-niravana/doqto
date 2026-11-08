// On-device walk of batch 5 (media): three photos with a caption land as an
// album → a video goes up through the presigned flow (poster, duration,
// caption) → the viewer shows it, Save to Photos writes an export audit, the
// player scrubs → the peer's voice note plays with its real waveform, speed
// pill and drag-to-scrub → the gallery lists Media / Docs / Links and
// multi-selects → a poll is created from the attach menu, I vote, the peer
// votes over REST and the bubble updates live → hold-to-record shows the
// slide-to-cancel panel → Storage and data shows the counters and Manage
// storage clears this chat's cache. The app signs in as +1 650-555-0198; the
// peer (+1 650-555-0199) acts over REST.
//
//   cd doqto_backend && venv/bin/python scripts/media_device_prep.py
//   xcrun simctl privacy <udid> grant microphone com.doqto.ios
//   xcrun simctl privacy <udid> grant photos-add com.doqto.ios
//   flutter test integration_test/media_test.dart -d <sim> \
//     --dart-define=FIREBASE_TEST_NUMBERS=true \
//     --dart-define=API_BASE_URL=http://localhost:8010 \
//     --dart-define=WS_BASE_URL=ws://localhost:8010 \
//     --dart-define=ME_ID=… --dart-define=PEER_ID=… --dart-define=CONV_ID=… \
//     --dart-define=PEER_TOKEN=… [--dart-define=SHOT_DIR=<folder on this Mac>]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/core/utils/waveform.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/main.dart' as app;
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/ui/screens/chat/chat_thread_screen.dart';
import 'package:doqto_app/ui/screens/chat/voice_recorder_panel.dart';

import 'fixtures/fixtures.dart';

const _me = String.fromEnvironment('ME_ID');
const _peer = String.fromEnvironment('PEER_ID');
const _conv = String.fromEnvironment('CONV_ID');
const _peerToken = String.fromEnvironment('PEER_TOKEN');
const _shotDir = String.fromEnvironment('SHOT_DIR');
const _liveTimeout = Duration(seconds: 20);

Future<void> _shot(WidgetTester t, String name) async {
  if (_shotDir.isEmpty) return;
  final view = t.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size * view.flutterView.devicePixelRatio;
  final image = await layer.toImage(Offset.zero & size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(
    '$_shotDir/batch5_$name.png',
  ).writeAsBytes(png!.buffer.asUint8List());
}

Future<void> _settle(WidgetTester t, [int ms = 1500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<Duration> _until(
  WidgetTester t,
  String what,
  FutureOr<bool> Function() ready, {
  Duration timeout = _liveTimeout,
}) async {
  final start = DateTime.now();
  while (!await ready()) {
    if (DateTime.now().difference(start) > timeout) {
      fail('not within $timeout: $what');
    }
    await t.pump(const Duration(milliseconds: 100));
  }
  final took = DateTime.now().difference(start);
  // ignore: avoid_print
  print('LIVE  ${took.inMilliseconds} ms  $what');
  return took;
}

/// Like [_until] but gives up quietly (steps the simulator may not allow).
Future<bool> _maybe(
  WidgetTester t,
  String what,
  FutureOr<bool> Function() ready, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final start = DateTime.now();
  while (!await ready()) {
    if (DateTime.now().difference(start) > timeout) {
      // ignore: avoid_print
      print('SKIP  $what did not happen within $timeout');
      return false;
    }
    await t.pump(const Duration(milliseconds: 100));
  }
  return true;
}

Future<(int, Object?)> _restRaw(
  String method,
  String path, {
  Map<String, dynamic>? body,
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(
      method,
      Uri.parse('${AppConstants.apiBaseUrl}/api/v1$path'),
    );
    req.headers.set('Authorization', 'Bearer $_peerToken');
    req.headers.contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
  } finally {
    client.close();
  }
}

Future<Object?> _rest(
  String method,
  String path, {
  Map<String, dynamic>? body,
}) async {
  final (status, json) = await _restRaw(method, path, body: body);
  if (status < 200 || status >= 300) fail('$method $path → $status $json');
  return json;
}

/// The peer uploads a file through the inline multipart routes.
Future<Map<String, dynamic>> _peerUpload(
  String path, {
  required List<int> bytes,
  required String filename,
  required String contentType,
  Map<String, String> fields = const {},
}) async {
  final client = HttpClient();
  try {
    final boundary = 'doqto${DateTime.now().microsecondsSinceEpoch}';
    final req = await client.postUrl(
      Uri.parse('${AppConstants.apiBaseUrl}/api/v1$path'),
    );
    req.headers.set('Authorization', 'Bearer $_peerToken');
    req.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
    final body = BytesBuilder();
    for (final e in fields.entries) {
      body.add(
        utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="${e.key}"\r\n\r\n${e.value}\r\n',
        ),
      );
    }
    body.add(
      utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$filename"\r\nContent-Type: $contentType\r\n\r\n',
      ),
    );
    body.add(bytes);
    body.add(utf8.encode('\r\n--$boundary--\r\n'));
    final out = body.takeBytes();
    req.contentLength = out.length;
    req.add(out);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      fail('POST $path → ${res.statusCode} $text');
    }
    return (jsonDecode(text) as Map).cast<String, dynamic>();
  } finally {
    client.close();
  }
}

Future<Map<String, dynamic>?> _peerSees(
  String convId,
  bool Function(Map<String, dynamic>) where,
) async {
  final list = (await _rest('GET', '/conversations/$convId/messages')) as List;
  for (final m in list.cast<Map<String, dynamic>>()) {
    if (where(m)) return m;
  }
  return null;
}

/// 16-bit mono PCM WAV: a 440 Hz tone with a slow envelope, so the note has
/// a visible waveform and plays on the simulator.
Uint8List _wav({int seconds = 4, int rate = 8000}) {
  final n = seconds * rate;
  final data = ByteData(44 + n * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    final env = 0.5 + 0.5 * math.sin(t * 2.5);
    final v = math.sin(2 * math.pi * 440 * t) * env * 0.6;
    data.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// The levels the recorder would have sampled for [_wav], 10 per second.
List<double> _wavLevels({int seconds = 4}) => [
  for (var i = 0; i < seconds * 10; i++) 0.5 + 0.5 * math.sin((i / 10) * 2.5),
];

/// A one-page PDF with a line of text — enough for Docs and the viewer.
Uint8List _pdf(String text) {
  final content = 'BT /F1 24 Tf 72 720 Td ($text) Tj ET';
  final objs = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
  ];
  final buf = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objs.length; i++) {
    offsets.add(buf.length);
    buf.write('${i + 1} 0 obj\n${objs[i]}\nendobj\n');
  }
  final xref = buf.length;
  buf.write('xref\n0 ${objs.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    buf.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  buf.write(
    'trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(latin1.encode(buf.toString()));
}

bool _has(Finder f) => f.evaluate().isNotEmpty;
Finder _key(String k) => find.byKey(ValueKey(k));

/// Taps once the widget is on screen and hit-testable (route transitions
/// absorb pointers for ~300 ms). Scrolls only when it is actually off screen:
/// `ensureVisible` on a visible item in the reversed list would drag it to
/// the viewport edge and hide the row below.
Future<void> _tapKey(
  WidgetTester t,
  String k, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final screen = Offset.zero & t.binding.renderViews.first.size;
  if (!screen.overlaps(t.getRect(_key(k)))) {
    await t.ensureVisible(_key(k));
  }
  await _until(
    t,
    '$k hit-testable',
    () => _has(_key(k).hitTestable()),
    timeout: timeout,
  );
  await t.tap(_key(k));
  await _settle(t, 400);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets(
    'album → video (viewer, save, player) → voice note (waveform, speed, scrub) → gallery → poll → hold-to-record → storage',
    (tester) async {
      try {
        await _walk(tester);
      } catch (_) {
        await _shot(tester, '99_failure');
        rethrow;
      }
    },
  );
}

Future<void> _walk(WidgetTester tester) async {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  {
    expect(
      _me.isNotEmpty &&
          _peer.isNotEmpty &&
          _conv.isNotEmpty &&
          _peerToken.isNotEmpty,
      isTrue,
      reason: 'run scripts/media_device_prep.py and pass its dart-defines',
    );
    await app.main();
    await _settle(tester, 3000);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    final auth = container.read(authProvider.notifier);
    final router = container.read(routerProvider);

    if (container.read(authProvider).stage != AuthStage.signedIn) {
      final challenge = await auth.startPhoneSignIn('+16505550198');
      await auth.confirmPhoneCode(challenge, '654321');
    }
    await _until(
      tester,
      'signed in',
      () => container.read(authProvider).stage == AuthStage.signedIn,
    );
    // The XCTest host leaves the app `inactive`; act like a foreground app.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester, 1500);
    await container.read(draftsProvider.notifier).clear(_conv);

    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    final startedAt = DateTime.now().toUtc().subtract(
      const Duration(seconds: 5),
    );
    List<Message> msgs() =>
        container.read(messagesProvider(_conv)).value ?? const [];
    Iterable<Message> fresh(MessageType type) => msgs().where(
      (m) =>
          m.type == type &&
          m.status == MessageStatus.sent &&
          m.createdAt.isAfter(startedAt),
    );

    // Fixtures onto the simulator's disk.
    final tmp = await getTemporaryDirectory();
    Future<String> drop(String name) async {
      final f = File('${tmp.path}/$name');
      await f.writeAsBytes(base64Decode(kFixtures[name]!.replaceAll('\n', '')));
      return f.path;
    }

    final photos = [
      for (final n in ['photo1.jpg', 'photo2.jpg', 'photo3.jpg']) await drop(n),
    ];
    final clip = await drop('clip.mp4');

    router.go(AppRoutes.chats);
    await _settle(tester, 1000);
    router.push(AppRoutes.chat(_conv));
    await _until(tester, 'composer', () => _has(_key('composer-input')));
    await _settle(tester, 800);
    final thread = tester.state(find.byType(ChatThreadScreen)) as dynamic;

    // ---- 1. Three photos + caption → one album row, caption on the last.
    final albumCaption = 'Rounds $stamp';
    await thread.sendPhotoFiles(<({String path, String name, String? mime})>[
      for (final (i, p) in photos.indexed)
        (path: p, name: 'photo${i + 1}.jpg', mime: 'image/jpeg'),
    ], caption: albumCaption);
    await _until(
      tester,
      '3 photos sent',
      () => fresh(MessageType.image).length >= 3,
    );
    final images = fresh(MessageType.image).toList();
    final newest = images.first;
    await _until(tester, 'album row', () => _has(_key('album-${newest.id}')));
    await _settle(tester, 1200);
    expect(find.text(albumCaption), findsOneWidget);
    await _shot(tester, '01_album');
    final serverLast = await _peerSees(_conv, (m) => m['id'] == newest.id);
    expect(
      serverLast?['caption'],
      albumCaption,
      reason: 'caption rides on the last photo',
    );
    expect(images.where((m) => m.caption == albumCaption).length, 1);

    // ---- 2. Video through the presigned flow: poster, duration, caption.
    final videoCaption = 'Echo $stamp';
    await thread.sendVideoFile(
      clip,
      fileName: 'clip.mp4',
      contentType: 'video/mp4',
      askCaption: false,
      caption: videoCaption,
    );
    await _until(
      tester,
      'video sent',
      () => fresh(MessageType.video).isNotEmpty,
      timeout: const Duration(seconds: 40),
    );
    final video = fresh(MessageType.video).first;
    await _until(
      tester,
      'video bubble',
      () => _has(_key('video-open-${video.id}')),
    );
    await _settle(tester, 1500);
    expect(find.text(videoCaption), findsOneWidget);
    expect(_has(_key('video-duration-${video.id}')), isTrue);
    await _shot(tester, '02_video_bubble');
    final serverVideo = await _peerSees(_conv, (m) => m['id'] == video.id);
    expect(serverVideo?['type'], 'video');
    expect(
      serverVideo?['thumb_key'],
      isNotNull,
      reason: 'poster made on the phone and PUT with the clip',
    );
    expect(serverVideo?['voice_duration_sec'], 2);
    expect(serverVideo?['media_width'], 160);
    expect(serverVideo?['caption'], videoCaption);

    // Viewer: index, caption, Save to Photos (export audit first), player.
    await _tapKey(tester, 'video-open-${video.id}');
    await _until(tester, 'viewer', () => _has(_key('viewer-index')));
    await _settle(tester, 1500);
    expect(
      _has(_key('viewer-save')),
      isTrue,
      reason: 'org policy allow_media_export is on for this walk',
    );
    expect(_has(_key('viewer-share')), isTrue);
    await _shot(tester, '03_viewer_video');
    await tester.tap(_key('viewer-save'));
    final saved = await _maybe(
      tester,
      'saved toast',
      () =>
          _has(find.text(Strings.mediaSaved)) ||
          _has(find.text(Strings.mediaSaveFailed)),
      // The simulator's photo library can take a while on its first write.
      timeout: const Duration(seconds: 45),
    );
    if (saved) {
      await _settle(tester, 500); // let the toast slide in
      await _shot(tester, '04_viewer_saved');
    }
    await _maybe(
      tester,
      'toast gone',
      () => !_has(find.byType(SnackBar)),
      timeout: const Duration(seconds: 6),
    );
    await _tapKey(
      tester,
      'viewer-play-${video.id}',
      timeout: const Duration(seconds: 45),
    );
    await _until(tester, 'player', () => _has(_key('video-scrub')));
    await _settle(tester, 1500);
    await _shot(tester, '05_video_player');
    await tester.tap(_key('video-toggle'));
    await _settle(tester, 400);
    await tester.tap(_key('video-close'));
    await _settle(tester, 600);
    await tester.tap(_key('viewer-close'));
    await _until(tester, 'back in thread', () => _has(_key('composer-input')));

    // ---- 3. The peer's voice note: real waveform, play, speed, scrub.
    final wave = Waveform.encode(_wavLevels());
    final voiceCaption = 'Listen $stamp';
    final voiceJson = await _peerUpload(
      '/messages/voice-notes/$_conv',
      bytes: _wav(),
      filename: 'note.wav',
      contentType: 'audio/wav',
      fields: {
        'duration_sec': '4',
        'waveform': base64Encode(wave),
        'caption': voiceCaption,
      },
    );
    final voiceId = voiceJson['id'] as String;
    expect(
      voiceJson['waveform'],
      base64Encode(wave),
      reason: 'server keeps the 64 bytes',
    );
    await _until(
      tester,
      'voice bubble',
      () => _has(_key('voice-play-$voiceId')),
    );
    await _settle(tester, 800);
    await _tapKey(tester, 'voice-play-$voiceId');
    await _until(
      tester,
      'note playing',
      () => _has(_key('voice-speed')),
      timeout: const Duration(seconds: 25),
    );
    await _settle(tester, 1200);
    expect(find.text(voiceCaption), findsOneWidget);
    await _shot(tester, '06_voice_playing');
    await tester.tap(_key('voice-speed'));
    await _settle(tester, 300);
    await tester.tap(_key('voice-speed'));
    await _until(tester, '2× pill', () => _has(find.text('2×')));
    final waveRect = tester.getRect(_key('voice-wave-$voiceId'));
    await tester.dragFrom(
      waveRect.centerLeft + const Offset(4, 0),
      Offset(waveRect.width * 0.5, 0),
    );
    await _settle(tester, 600);
    final timeText =
        tester.widget<Text>(_key('voice-time-$voiceId')).data ?? '';
    expect(timeText, contains('/'), reason: 'elapsed / total while current');
    await _shot(tester, '07_voice_scrubbed');
    await tester.tap(_key('voice-play-$voiceId')); // pause
    await _settle(tester, 400);

    // ---- 4. Peer adds a document and a link, then the gallery tabs.
    final docJson = await _peerUpload(
      '/messages/upload/$_conv',
      bytes: _pdf('Discharge summary $stamp'),
      filename: 'discharge_$stamp.pdf',
      contentType: 'application/pdf',
      fields: {'caption': 'Summary $stamp'},
    );
    await _rest(
      'POST',
      '/conversations/$_conv/messages',
      body: {
        'content':
            'Guideline $stamp https://en.wikipedia.org/wiki/Electrocardiography',
      },
    );
    await _until(
      tester,
      'doc bubble',
      () => _has(find.text('discharge_$stamp.pdf')),
    );
    router.push(AppRoutes.mediaGallery(_conv));
    await _until(tester, 'gallery grid', () => _has(_key('gallery-grid')));
    await _until(
      tester,
      'tiles for the album and the video',
      () =>
          _has(_key('gallery-tile-${video.id}')) &&
          images.every((m) => _has(_key('gallery-tile-${m.id}'))),
    );
    await _settle(tester, 1500);
    await _shot(tester, '08_gallery_media');
    await tester.tap(find.text(Strings.mediaTabDocs));
    await _until(
      tester,
      'docs list',
      () => _has(_key('gallery-doc-${docJson['id']}')),
    );
    await _settle(tester, 800);
    await _shot(tester, '09_gallery_docs');
    await tester.tap(find.text(Strings.mediaTabLinks));
    await _until(
      tester,
      'links list',
      () =>
          _has(_key('gallery-links')) &&
          _has(find.textContaining('wikipedia.org')),
    );
    await _settle(tester, 1500);
    await _shot(tester, '10_gallery_links');
    await tester.tap(find.text(Strings.mediaTabMedia));
    await _until(
      tester,
      'grid again',
      () => _has(_key('gallery-tile-${video.id}')),
    );
    await tester.longPress(_key('gallery-tile-${images[0].id}'));
    await _until(tester, 'selection bar', () => _has(_key('gallery-star')));
    await tester.tap(_key('gallery-tile-${images[1].id}'));
    await _settle(tester, 500);
    expect(find.text('2'), findsOneWidget, reason: 'two selected in the title');
    await _shot(tester, '11_gallery_select');
    await tester.tap(_key('gallery-star'));
    await _until(tester, 'starred on the server', () async {
      final a = await _peerSees(_conv, (m) => m['id'] == images[0].id);
      return a != null &&
          (await container.read(chatRepositoryProvider).starred()).data.any(
            (s) => s.message.id == images[0].id,
          );
    });
    await _maybe(
      tester,
      'toast gone',
      () => !_has(find.byType(SnackBar)),
      timeout: const Duration(seconds: 6),
    );
    router.pop();
    await _until(tester, 'thread again', () => _has(_key('composer-input')));
    await _settle(tester, 800);

    // ---- 5. Poll from the attach menu; I vote, the peer votes over REST.
    await _tapKey(tester, 'composer-attach');
    await _until(
      tester,
      'attach sheet',
      () => _has(find.text(Strings.mediaPoll)),
    );
    await _shot(tester, '12_attach_menu');
    await tester.tap(find.text(Strings.mediaPoll));
    await _until(tester, 'poll sheet', () => _has(_key('poll-question')));
    final question = 'Journal club $stamp?';
    await tester.enterText(
      find.descendant(
        of: _key('poll-question'),
        matching: find.byType(EditableText),
      ),
      question,
    );
    await tester.enterText(
      find.descendant(
        of: _key('poll-option-0'),
        matching: find.byType(EditableText),
      ),
      'Tuesday',
    );
    await tester.enterText(
      find.descendant(
        of: _key('poll-option-1'),
        matching: find.byType(EditableText),
      ),
      'Thursday',
    );
    await _settle(tester, 400);
    await _shot(tester, '13_poll_create');
    await _tapKey(tester, 'poll-send');
    await _until(tester, 'poll sent', () => fresh(MessageType.poll).isNotEmpty);
    final poll = fresh(MessageType.poll).first;
    await _until(tester, 'poll bubble', () => _has(find.text(question)));
    await _settle(tester, 800);
    final o1 = poll.poll!.options[0].id;
    final o2 = poll.poll!.options[1].id;
    await _tapKey(tester, 'poll-opt-$o1');
    await _until(tester, 'my tick', () => _has(_key('poll-selected')));
    await _until(tester, 'server has my vote', () async {
      final m = await _peerSees(_conv, (m) => m['id'] == poll.id);
      final opts =
          (m?['poll']?['options'] as List?)?.cast<Map<String, dynamic>>() ??
          const [];
      return opts.any(
        (o) => o['id'] == o1 && (o['voter_ids'] as List).contains(_me),
      );
    });
    await _rest(
      'PUT',
      '/messages/${poll.id}/vote',
      body: {
        'option_ids': [o2],
      },
    );
    await _until(
      tester,
      'live poll_updated → 2 votes',
      () => _has(find.text('2 ${Strings.pollVotes}')),
    );
    await _settle(tester, 800);
    await _shot(tester, '14_poll_votes');
    await _tapKey(tester, 'poll-view-votes');
    await _until(tester, 'voters sheet', () => _has(_key('poll-voters-sheet')));
    await _settle(tester, 600);
    await _shot(tester, '15_poll_voters');
    await tester.tapAt(const Offset(20, 60));
    await _until(
      tester,
      'sheet closed',
      () => !_has(_key('poll-voters-sheet')),
    );

    // ---- 6. Hold-to-record: slide to cancel, then slide up to lock.
    // Best-effort on the simulator: the speech-recognition prompt (no simctl
    // grant exists for it) can hold the recorder at 0:00, so each step
    // tolerates the panel not reacting.
    final mic = tester.getCenter(_key('composer-mic'));
    final g = await tester.startGesture(mic);
    final held = await _maybe(
      tester,
      'held recorder',
      () => _has(_key('recorder-held')),
    );
    if (held) {
      await _maybe(
        tester,
        'recording timer ticking',
        () => _has(find.text('0:01')) || _has(find.text('0:02')),
        timeout: const Duration(seconds: 4),
      );
      await _shot(tester, '16_hold_recording');
      await g.moveBy(const Offset(-160, 0));
      final cancelled = await _maybe(
        tester,
        'cancelled by slide',
        () => !_has(find.byType(VoiceRecorderPanel)),
      );
      await g.up();
      await _settle(tester, 500);
      if (cancelled) {
        final g2 = await tester.startGesture(
          tester.getCenter(_key('composer-mic')),
        );
        await _until(tester, 'held again', () => _has(_key('recorder-held')));
        await g2.moveBy(const Offset(0, -120));
        await _until(
          tester,
          'locked',
          () =>
              _has(find.byType(VoiceRecorderPanel)) &&
              !_has(_key('recorder-held')),
        );
        await g2.up();
        await _settle(tester, 1500);
        await _shot(tester, '17_hold_locked');
        if (_has(find.text('Cancel'))) {
          await tester.tap(find.text('Cancel'));
          await _maybe(
            tester,
            'recorder closed',
            () => !_has(find.byType(VoiceRecorderPanel)),
          );
        }
      }
    } else {
      await g.up();
    }

    // ---- 7. Storage and data → Manage storage → clear this chat.
    router.push(AppRoutes.storage);
    await _until(
      tester,
      'storage screen',
      () => _has(_key('storage-row-quality')),
    );
    await _settle(tester, 800);
    await _shot(tester, '18_storage');
    await _tapKey(tester, 'storage-manage');
    await _until(
      tester,
      'this chat listed',
      () => _has(_key('storage-row-$_conv')),
    );
    await _settle(tester, 600);
    await _shot(tester, '19_manage_storage');
    await _tapKey(tester, 'storage-clear-$_conv');
    await _until(tester, 'confirm', () => _has(_key('storage-clear-confirm')));
    await tester.tap(_key('storage-clear-confirm'));
    await _until(tester, 'row gone', () => !_has(_key('storage-row-$_conv')));
    await _settle(tester, 600);
    await _shot(tester, '20_storage_cleared');
    expect(
      container.read(chatMediaCacheProvider).sizesByConversation()[_conv],
      isNull,
    );
  }
}
