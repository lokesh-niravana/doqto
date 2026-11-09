import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/chat_theme.dart';
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/utils/waveform.dart';
import 'package:doqto_app/data/models/media_settings.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/data/services/chat_media_cache.dart';
import 'package:doqto_app/data/services/media_native.dart';
import 'package:doqto_app/data/services/network_usage.dart';
import 'package:doqto_app/state/voice_playback_state.dart';
import 'package:doqto_app/ui/screens/chat/caption_sheet.dart';
import 'package:doqto_app/ui/screens/chat/poll_create_sheet.dart';
import 'package:doqto_app/ui/screens/storage/storage_screen.dart';
import 'package:doqto_app/ui/widgets/album_bubble.dart';
import 'package:doqto_app/ui/widgets/attachment_bubbles.dart';
import 'package:doqto_app/ui/widgets/poll_bubble.dart';
import 'package:doqto_app/ui/widgets/voice_note_bubble.dart';

import 'package:doqto_app/ui/widgets/app_pressable.dart';

import '../support/fake_media_backend.dart';

/// Batch 5 widgets: the voice bubble over a fake audio engine (waveform
/// bars, play, speed pill, scrub), the poll create sheet (validation and the
/// keyboard rule), the caption sheet, album tiles with "+N", the poll bubble's
/// vote callbacks, video bubble chrome, and the Storage screen rows.

class _Engine implements VoiceAudioEngine {
  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _done = StreamController<void>.broadcast();
  final loaded = <String>[];
  final seeks = <Duration>[];
  final speeds = <double>[];
  int plays = 0;
  int pauses = 0;

  @override
  Stream<Duration> get position => _pos.stream;
  @override
  Stream<Duration?> get duration => _dur.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<void> get completed => _done.stream;

  @override
  Future<Duration?> load(String pathOrUrl, {required bool isFile}) async {
    loaded.add(pathOrUrl);
    return const Duration(seconds: 10);
  }

  @override
  Future<void> play() async {
    plays++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauses++;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _pos.add(position);
  }

  @override
  Future<void> setSpeed(double speed) async => speeds.add(speed);
  @override
  Future<void> stop() async => _playing.add(false);
  @override
  Future<void> dispose() async {}

  void tick(Duration d) => _pos.add(d);
  void finish() => _done.add(null);
}

class _Native implements MediaNative {
  NetworkType network = NetworkType.wifi;
  final earpiece = <bool>[];
  final _prox = StreamController<bool>.broadcast();
  @override
  Future<VideoPoster?> videoPoster(String path, {int maxSide = 720}) async => null;
  @override
  Future<bool> saveToPhotos(String path) async => true;
  @override
  Future<bool?> scanDocument(String outputPath) async => null;
  @override
  Future<NetworkType> networkType() async => network;
  @override
  Future<void> setEarpiece(bool e) async => earpiece.add(e);
  @override
  Stream<bool> get proximity => _prox.stream;
}

class _Cache extends ChatCache {
  MediaSettings? saved;
  @override
  MediaSettings mediaSettings() => saved ?? MediaSettings.defaults;
  @override
  Future<void> putMediaSettings(MediaSettings s) async => saved = s;
}

Message _msg(String id, {String type = 'image', String sender = 'them', int secs = 0, String? caption, Map<String, dynamic>? poll}) =>
    Message.fromJson({
      'id': id,
      'conversation_id': 'c1',
      'sender_id': sender,
      'type': type,
      'seq': secs,
      'file_name': '$id.jpg',
      'created_at': DateTime.utc(2026, 11, 8, 10, 0, secs).toIso8601String(),
      'caption': caption,
      'poll': poll,
    });

bool _enabled(WidgetTester t, Finder button) =>
    t.widget<AppPressable>(find.descendant(of: button, matching: find.byType(AppPressable)).first).enabled;

void main() {
  late _Engine engine;
  late _Native native;
  late FakeMediaBackend backend;
  late ChatMediaCache cache;

  setUp(() {
    engine = _Engine();
    native = _Native();
    backend = FakeMediaBackend();
    cache = ChatMediaCache(backend, index: MemoryMediaIndex());
  });

  Widget app(Widget child, {List<Override> extra = const []}) => ProviderScope(
        overrides: [
          voiceAudioEngineProvider.overrideWithValue(engine),
          mediaNativeProvider.overrideWithValue(native),
          chatMediaCacheProvider.overrideWithValue(cache),
          ...extra,
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  Future<void> settle(WidgetTester t, [int n = 4]) async {
    for (var i = 0; i < n; i++) {
      await t.pump();
    }
  }

  group('VoiceNoteBubble', () {
    final wave = Waveform.encode([for (var i = 0; i < 64; i++) (i % 8) / 8]);

    Widget bubble({String id = 'v1', bool withResolve = true}) => VoiceNoteBubble(
          messageId: id,
          conversationId: 'c1',
          durationSec: 10,
          transcript: null,
          waveform: wave,
          isMine: false,
          timestamp: DateTime(2026, 11, 8, 10),
          resolve: withResolve ? () async => (path: '/tmp/$id.m4a', isFile: true) : null,
        );

    testWidgets('draws the waveform, plays on tap, shows the speed pill and cycles it', (tester) async {
      await tester.pumpWidget(app(bubble()));
      expect(find.byKey(const ValueKey('voice-wave-v1')), findsOneWidget);
      expect(find.text('0:10'), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-speed')), findsNothing, reason: 'speed only while this note is current');

      await tester.tap(find.byKey(const ValueKey('voice-play-v1')));
      await settle(tester);
      expect(engine.loaded, ['/tmp/v1.m4a']);
      expect(engine.plays, 1);
      expect(find.byKey(const ValueKey('voice-pause-icon')), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-speed')), findsOneWidget);
      expect(find.text('1×'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('voice-speed')));
      await settle(tester);
      expect(find.text('1.5×'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voice-speed')));
      await settle(tester);
      expect(find.text('2×'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voice-speed')));
      await settle(tester);
      expect(find.text('1×'), findsOneWidget);
      expect(engine.speeds.where((s) => s == 1.5), isNotEmpty);

      // Position ticks update the elapsed / total label.
      engine.tick(const Duration(seconds: 4));
      await settle(tester);
      expect(find.text('0:04 / 0:10'), findsOneWidget);

      // Tap again pauses.
      await tester.tap(find.byKey(const ValueKey('voice-play-v1')));
      await settle(tester);
      expect(engine.pauses, 1);
      expect(find.byKey(const ValueKey('voice-play-icon')), findsOneWidget);
    });

    testWidgets('dragging the waveform seeks to that fraction', (tester) async {
      await tester.pumpWidget(app(bubble()));
      await tester.tap(find.byKey(const ValueKey('voice-play-v1')));
      await settle(tester);
      final wave = find.byKey(const ValueKey('voice-wave-v1'));
      final box = tester.getRect(wave);
      await tester.dragFrom(box.centerLeft + const Offset(2, 0), Offset(box.width * 0.5, 0));
      await settle(tester);
      expect(engine.seeks, isNotEmpty);
      final target = engine.seeks.last;
      expect(target.inMilliseconds, inInclusiveRange(4000, 6000), reason: 'half way through 10 s');
    });

    testWidgets('a pending (still local) note has no player and shows the sending tick', (tester) async {
      await tester.pumpWidget(app(VoiceNoteBubble(
        messageId: 'local',
        conversationId: 'c1',
        durationSec: 3,
        transcript: null,
        isMine: true,
        timestamp: DateTime(2026, 11, 8, 10),
        status: MessageStatus.sending,
      )));
      await tester.tap(find.byKey(const ValueKey('voice-play-local')));
      await settle(tester);
      expect(engine.loaded, isEmpty);
    });

    testWidgets('auto-plays the next note the thread names when one ends', (tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          voiceAudioEngineProvider.overrideWithValue(engine),
          mediaNativeProvider.overrideWithValue(native),
          chatMediaCacheProvider.overrideWithValue(cache),
        ],
        child: Consumer(builder: (ctx, ref, _) {
          container = ProviderScope.containerOf(ctx);
          return MaterialApp(home: Scaffold(body: Column(children: [bubble(id: 'v1'), bubble(id: 'v2')])));
        }),
      ));
      final playback = container.read(voicePlaybackProvider);
      final next = _msg('v2', type: 'voice_note');
      playback.nextAfter = (ended) => ended == 'v1' ? next : null;
      playback.resolverFor = (m) async => (path: '/tmp/${m.id}.m4a', isFile: true);
      await tester.tap(find.byKey(const ValueKey('voice-play-v1')));
      await settle(tester);
      engine.finish();
      await settle(tester, 8);
      expect(engine.loaded, ['/tmp/v1.m4a', '/tmp/v2.m4a']);
      expect(playback.isCurrent('v2'), isTrue);
    });
  });

  group('PollCreateSheet', () {
    Future<void> open(WidgetTester tester, void Function(PollDraft?) onDone) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                key: const ValueKey('open'),
                onPressed: () async => onDone(await showPollCreateSheet(ctx)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
    }

    testWidgets('two options minimum, duplicates refused, up to twelve, returns the draft', (tester) async {
      PollDraft? out;
      await open(tester, (d) => out = d);
      expect(find.byKey(const ValueKey('poll-option-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('poll-option-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('poll-option-remove-0')), findsNothing, reason: 'cannot go below two');

      await tester.enterText(find.byKey(const ValueKey('poll-question')), 'Lunch?');
      await tester.enterText(find.byKey(const ValueKey('poll-option-0')), 'Pizza');
      await tester.pump();
      final send = find.byKey(const ValueKey('poll-send'));
      expect(_enabled(tester, send), isFalse,
          reason: 'one option is not a poll');

      await tester.enterText(find.byKey(const ValueKey('poll-option-1')), 'pizza');
      await tester.pump();
      expect(_enabled(tester, send), isFalse,
          reason: 'duplicate options differ only by case');

      await tester.enterText(find.byKey(const ValueKey('poll-option-1')), 'Sushi');
      await tester.pump();
      expect(_enabled(tester, send), isTrue);

      // Add up to the cap: the add row disappears at 12.
      for (var i = 2; i < PollData.maxOptions; i++) {
        await tester.ensureVisible(find.byKey(const ValueKey('poll-add-option')));
        await tester.tap(find.byKey(const ValueKey('poll-add-option')));
        await tester.pump();
      }
      expect(find.byKey(const ValueKey('poll-option-11')), findsOneWidget);
      expect(find.byKey(const ValueKey('poll-add-option')), findsNothing);
      // Empty extra rows are ignored; remove one to prove the control works.
      await tester.ensureVisible(find.byKey(const ValueKey('poll-option-remove-11')));
      await tester.tap(find.byKey(const ValueKey('poll-option-remove-11')));
      await tester.pump();
      expect(find.byKey(const ValueKey('poll-option-11')), findsNothing);

      await tester.ensureVisible(find.byKey(const ValueKey('poll-switch-multiple')));
      await tester.tap(find.byKey(const ValueKey('poll-switch-multiple')));
      await tester.pump();
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(out, isNotNull);
      expect(out!.question, 'Lunch?');
      expect(out!.options, ['Pizza', 'Sushi']);
      expect(out!.multiple, isTrue);
    });

    testWidgets('keyboard rule: tapping outside the question field dismisses the keypad', (tester) async {
      await open(tester, (_) {});
      await tester.tap(find.byKey(const ValueKey('poll-question')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.text(Strings.pollOptions));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byKey(const ValueKey('poll-option-0')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.text(Strings.pollCreateTitle));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
    });
  });

  group('CaptionSheet', () {
    testWidgets('returns the trimmed caption on send, null on close; tap outside dismisses the keypad', (tester) async {
      CaptionResult? out = const CaptionResult(caption: 'unset', previews: []);
      Future<void> open(WidgetTester tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                key: const ValueKey('open'),
                onPressed: () async => out = await showCaptionSheet(ctx, previews: const [CaptionPreview(label: 'a.pdf'), CaptionPreview(label: 'b.pdf')]),
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.byKey(const ValueKey('open')));
        await tester.pumpAndSettle();
      }

      await open(tester);
      expect(find.byKey(const ValueKey('caption-title')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('caption-input')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.byKey(const ValueKey('caption-title')));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.enterText(find.byKey(const ValueKey('caption-input')), '  Results  ');
      await tester.tap(find.byKey(const ValueKey('caption-send')));
      await tester.pumpAndSettle();
      expect(out?.caption, 'Results');
      expect(out?.previews.length, 2, reason: 'previews come back as they stand');
      expect(find.byKey(const ValueKey('caption-crop-0')), findsNothing, reason: 'documents have no crop');

      await open(tester);
      await tester.tap(find.byKey(const ValueKey('caption-close')));
      await tester.pumpAndSettle();
      expect(out, isNull);
    });

    testWidgets('photo previews carry a crop button; untouched photos send as picked', (tester) async {
      // Sync IO only: an awaited real Future never completes under fake async.
      final tmp = Directory.systemTemp.createTempSync('doqto-caption-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final a = File('${tmp.path}/a.jpg')..writeAsBytesSync(const [0xFF, 0xD8, 0xFF, 0xD9]);
      CaptionResult? out;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () async => out = await showCaptionSheet(ctx, previews: [CaptionPreview(imagePath: a.path, label: 'Photo')]),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      // Image.file reads real IO, which never completes under fake async, so
      // pump by hand instead of pumpAndSettle (it would wait the full timeout).
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('caption-crop-0')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('caption-send')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(out?.previews.single.imagePath, a.path);
      expect(out?.previews.single.cropped, isFalse);
    });
  });

  group('AlbumBubble', () {
    setUp(() {
      // Phone-sized surface: the album is 72 % of the width, which on the
      // default 800 px test screen would be taller than the screen.
      final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(390, 844);
      view.devicePixelRatio = 1;
      addTearDown(view.reset);
    });

    testWidgets('four tiles with +N for the rest, caption from the last photo, viewer index by send order', (tester) async {
      final msgs = [for (var i = 6; i >= 1; i--) _msg('p$i', secs: i, caption: i == 6 ? 'Rounds' : null)];
      int? opened;
      await tester.pumpWidget(app(AlbumBubble(
        messages: msgs,
        conversationId: 'c1',
        isMine: false,
        resolveUrl: (m) async => 'https://s3/${m.id}',
        onOpen: (i) => opened = i,
      )));
      await settle(tester);
      expect(find.byType(Image), findsNWidgets(4));
      expect(find.byKey(const ValueKey('album-more')), findsOneWidget);
      expect(find.text('+2'), findsOneWidget);
      expect(find.text('Rounds'), findsOneWidget);
      expect(backend.downloadedUrls, hasLength(4), reason: 'hidden photos are not fetched');
      await tester.tap(find.byKey(const ValueKey('album-tile-p2')));
      expect(opened, 1, reason: 'p1 is index 0 in send order');
    });

    testWidgets('three photos: one wide on top, two below; off-Wi-Fi shows download tiles', (tester) async {
      final msgs = [for (var i = 3; i >= 1; i--) _msg('q$i', secs: i)];
      await tester.pumpWidget(app(AlbumBubble(
        messages: msgs,
        conversationId: 'c1',
        isMine: true,
        resolveUrl: (m) async => 'https://s3/${m.id}',
        onOpen: (_) {},
        autoDownload: false,
      )));
      await settle(tester);
      expect(find.byKey(const ValueKey('media-download')), findsNWidgets(3));
      expect(backend.downloadedUrls, isEmpty);
      final top = tester.getSize(find.byKey(const ValueKey('album-tile-q1')));
      final bottom = tester.getSize(find.byKey(const ValueKey('album-tile-q2')));
      expect(top.width, greaterThan(bottom.width * 1.9));
      await tester.tap(find.byKey(const ValueKey('media-download')).first);
      await settle(tester);
      expect(backend.downloadedUrls, ['https://s3/q1']);
    });
  });

  group('PollBubble', () {
    final pollJson = {
      'question': 'Lunch?',
      'multiple': false,
      'options': [
        {'id': 'o1', 'position': 0, 'text': 'Pizza', 'voter_ids': ['them', 'x']},
        {'id': 'o2', 'position': 1, 'text': 'Sushi', 'voter_ids': ['me']},
      ],
    };

    testWidgets('single choice: tapping another option replaces mine, tapping mine unvotes; totals and view votes', (tester) async {
      final m = _msg('q', type: 'poll', poll: pollJson);
      List<String>? voted;
      var viewed = 0;
      await tester.pumpWidget(app(PollBubble(message: m, poll: m.poll!, isMine: false, me: 'me', onVote: (ids) => voted = ids, onViewVotes: () => viewed++)));
      expect(find.text('Lunch?'), findsOneWidget);
      expect(find.text(Strings.pollSelectOne), findsOneWidget);
      expect(find.text('3 ${Strings.pollVotes}'), findsOneWidget);
      expect(find.byKey(const ValueKey('poll-count-o1')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('poll-opt-o1')));
      expect(voted, ['o1']);
      await tester.tap(find.byKey(const ValueKey('poll-opt-o2')));
      expect(voted, isEmpty, reason: 'tapping my current pick unvotes');
      await tester.tap(find.byKey(const ValueKey('poll-view-votes')));
      expect(viewed, 1);
    });

    testWidgets('multiple choice toggles within my set', (tester) async {
      final m = _msg('q', type: 'poll', poll: {...pollJson, 'multiple': true});
      List<String>? voted;
      await tester.pumpWidget(app(PollBubble(message: m, poll: m.poll!, isMine: true, me: 'me', onVote: (ids) => voted = ids)));
      expect(find.text(Strings.pollSelectMany), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('poll-opt-o1')));
      expect(voted!.toSet(), {'o1', 'o2'});
      await tester.tap(find.byKey(const ValueKey('poll-opt-o2')));
      expect(voted, isEmpty);
    });

    testWidgets('voters sheet lists names under each option', (tester) async {
      final m = _msg('q', type: 'poll', poll: pollJson);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              key: const ValueKey('open'),
              onPressed: () => showPollVotersSheet(context: ctx, poll: m.poll!, nameFor: (u) => 'Dr $u', colorFor: (_) => 0),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('poll-voters-sheet')), findsOneWidget);
      expect(find.text('Dr them'), findsOneWidget);
      expect(find.text('Dr x'), findsOneWidget);
      expect(find.text('Dr me'), findsOneWidget);
    });
  });

  group('video and file bubbles', () {
    testWidgets('VideoBubble shows duration, play and the caption; poster comes from the thumb cache', (tester) async {
      var opened = 0;
      await tester.pumpWidget(app(VideoBubble(
        messageId: 'v9',
        conversationId: 'c1',
        getFileUrl: () async => 'https://s3/v9',
        getThumbUrl: () async => 'https://s3/v9-thumb',
        durationSec: 65,
        isMine: true,
        timestamp: DateTime(2026, 11, 8, 10),
        caption: 'Echo',
        width: 320,
        height: 240,
        onOpen: () => opened++,
      )));
      await settle(tester);
      expect(find.text('1:05'), findsOneWidget);
      expect(find.text('Echo'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(backend.downloadedUrls, ['https://s3/v9-thumb'], reason: 'poster only; the clip waits for play');
      await tester.tap(find.byKey(const ValueKey('video-open-v9')));
      expect(opened, 1);
    });

    testWidgets('PendingVideoBubble / PendingImageBubble show the upload ring with the fraction', (tester) async {
      final tmp = File('${Directory.systemTemp.path}/pending_${DateTime.now().microsecondsSinceEpoch}.png')..writeAsBytesSync(FakeMediaBackend.png);
      await tester.pumpWidget(app(Column(children: [
        PendingVideoBubble(posterPath: tmp.path, durationSec: 4, isMine: true, timestamp: DateTime(2026, 11, 8, 10), status: MessageStatus.sending, progress: 0.4, caption: 'up'),
        PendingImageBubble(path: tmp.path, isMine: true, timestamp: DateTime(2026, 11, 8, 10), status: MessageStatus.sending, progress: 0.7),
      ])));
      await settle(tester);
      final rings = tester.widgetList<CircularProgressIndicator>(find.byKey(const ValueKey('upload-ring'))).toList();
      expect(rings.map((r) => r.value), [0.4, 0.7]);
      expect(find.text('up'), findsOneWidget);
      tmp.deleteSync();
    });

    testWidgets('FileBubble shows caption and a percentage while sending', (tester) async {
      await tester.pumpWidget(app(FileBubble(
        getFileUrl: null,
        fileName: 'labs.pdf',
        fileSizeBytes: 3 * 1024 * 1024,
        isMine: true,
        timestamp: DateTime(2026, 11, 8, 10),
        status: MessageStatus.sending,
        caption: 'Labs',
        progress: 0.25,
      )));
      expect(find.text('Labs'), findsOneWidget);
      expect(find.text('25% · 3.0 MB'), findsOneWidget);
    });
  });

  group('StorageScreen', () {
    testWidgets('quality and auto-download rows read and write the settings; usage counters show', (tester) async {
      final cacheBox = _Cache();
      final usage = NetworkUsage()..addSent(2048)..addReceived(5 * 1024 * 1024);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          chatCacheProvider.overrideWithValue(cacheBox),
          networkUsageProvider.overrideWith((_) => usage),
          mediaNativeProvider.overrideWithValue(native),
        ],
        child: const MaterialApp(home: StorageScreen()),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('storage-row-quality')), findsOneWidget);
      expect(find.text('Standard (1600 px)'), findsOneWidget);
      expect(find.text(Strings.storageWifiOnly), findsOneWidget, reason: 'photos default to Wi-Fi only');
      expect(find.text(Strings.storageNever), findsNWidgets(3));

      await tester.tap(find.byKey(const ValueKey('storage-row-quality')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('storage-opt-quality-hd')));
      await tester.pumpAndSettle();
      expect(cacheBox.saved?.uploadQuality, UploadQuality.hd);
      expect(find.text('HD (2560 px)'), findsOneWidget);

      await tester.scrollUntilVisible(find.byKey(const ValueKey('storage-row-video')), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const ValueKey('storage-row-video')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('storage-opt-video-always')));
      await tester.pumpAndSettle();
      expect(cacheBox.saved?.ruleFor(MediaDownloadKind.video), AutoDownloadRule.always);

      await tester.scrollUntilVisible(find.byKey(const ValueKey('storage-reset-usage')), 200, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('storage-sent'))).data, '2 KB');
      expect(tester.widget<Text>(find.byKey(const ValueKey('storage-received'))).data, '5.0 MB');
      await tester.tap(find.byKey(const ValueKey('storage-reset-usage')));
      await tester.pump();
      expect(usage.bytesSent, 0);
      expect(tester.widget<Text>(find.byKey(const ValueKey('storage-sent'))).data, '0 B');
      expect(tester.widget<Text>(find.byKey(const ValueKey('storage-received'))).data, '0 B');
    });
  });

  test('Uint8List waveform survives the bubble constructor', () {
    final w = Uint8List.fromList([1, 2, 3]);
    final b = VoiceNoteBubble(messageId: 'x', conversationId: 'c', durationSec: 1, transcript: null, isMine: true, timestamp: DateTime(2026), waveform: w);
    expect(b.waveform, w);
  });

  group('chat theme on media bubbles', () {
    // Received voice/document bubbles used to be hard-coded white regardless
    // of the chat colour theme. They follow ChatThemeScope now.
    final dark = ChatThemeData(theme: ChatTheme.byId('ocean')!);

    Color? bubbleBg(WidgetTester t, Type root) {
      for (final c in t.widgetList<Container>(find.descendant(of: find.byType(root), matching: find.byType(Container)))) {
        final d = c.decoration;
        if (d is BoxDecoration && d.color != null && d.borderRadius != null) return d.color;
      }
      return null;
    }

    testWidgets('received voice note takes the themed received colour', (tester) async {
      final wave = Waveform.encode([for (var i = 0; i < 16; i++) i / 16]);
      await tester.pumpWidget(app(ChatThemeScope(
        data: dark,
        child: VoiceNoteBubble(
          messageId: 'vd', conversationId: 'c1', durationSec: 3, transcript: null,
          waveform: wave, isMine: false, timestamp: DateTime(2026, 11, 8, 10), resolve: null,
        ),
      )));
      expect(dark.receivedBg, isNot(const Color(0xFFFFFFFF)), reason: 'precondition');
      expect(bubbleBg(tester, VoiceNoteBubble), dark.receivedBg);
    });

    testWidgets('received document takes the themed received colour and foreground', (tester) async {
      await tester.pumpWidget(app(ChatThemeScope(
        data: dark,
        child: FileBubble(
          getFileUrl: null, fileName: 'discharge.pdf', fileSizeBytes: 598,
          isMine: false, timestamp: DateTime(2026, 11, 8, 10),
        ),
      )));
      expect(bubbleBg(tester, FileBubble), dark.receivedBg);
      final name = tester.widget<Text>(find.text('discharge.pdf'));
      expect(name.style?.color, dark.receivedFg);
    });

    testWidgets('sent document follows the sent colour of the theme', (tester) async {
      await tester.pumpWidget(app(ChatThemeScope(
        data: dark,
        child: FileBubble(
          getFileUrl: null, fileName: 'mine.pdf', isMine: true, timestamp: DateTime(2026, 11, 8, 10),
        ),
      )));
      expect(bubbleBg(tester, FileBubble), dark.sentBg);
    });
  });
}
