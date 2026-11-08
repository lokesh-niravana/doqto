import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart' show decodeImageFromList;
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/utils/album_grouping.dart';
import 'package:doqto_app/core/utils/image_metadata.dart';
import 'package:doqto_app/core/utils/waveform.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/media.dart';
import 'package:doqto_app/data/models/media_settings.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/services/network_usage.dart';

/// Batch 5 pure-Dart pieces: EXIF stripping on a real JPEG carrying a
/// hand-built GPS block, album grouping, the 64-byte waveform, the media
/// models, the auto-download rules and the network counters.

/// A JPEG APP1 segment: "Exif\0\0" + little-endian TIFF with IFD0 → one entry
/// (GPSInfo pointer) → a GPS IFD holding GPSLatitudeRef "N".
Uint8List _exifApp1() {
  final tiff = BytesBuilder();
  void u16(int v) => tiff.add([v & 0xFF, v >> 8]);
  void u32(int v) => tiff.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  tiff.add('II'.codeUnits);
  u16(0x2A);
  u32(8); // IFD0 at offset 8
  // IFD0: 1 entry
  u16(1);
  u16(0x8825); // GPSInfoIFDPointer
  u16(4); // LONG
  u32(1);
  u32(8 + 2 + 12 + 4); // GPS IFD right after IFD0
  u32(0); // next IFD
  // GPS IFD: 1 entry, GPSLatitudeRef = "N"
  u16(1);
  u16(0x0001);
  u16(2); // ASCII
  u32(2);
  tiff.add('N\u0000\u0000\u0000'.codeUnits);
  u32(0);
  final body = [...'Exif\u0000\u0000'.codeUnits, ...tiff.toBytes()];
  final len = body.length + 2;
  return Uint8List.fromList([0xFF, 0xE1, len >> 8, len & 0xFF, ...body]);
}

Uint8List _withExif(Uint8List jpeg) =>
    Uint8List.fromList([0xFF, 0xD8, ..._exifApp1(), ...jpeg.sublist(2)]);

Message _img(String id, {String sender = 'them', int secs = 0, bool deleted = false, String? reply, bool forwarded = false, String? caption}) =>
    Message.fromJson({
      'id': id,
      'conversation_id': 'c1',
      'sender_id': sender,
      'type': 'image',
      'file_name': '$id.jpg',
      'created_at': DateTime.utc(2026, 11, 8, 10, 0, secs).toIso8601String(),
      'seq': secs,
      'deleted_at': deleted ? '2026-11-08T10:05:00Z' : null,
      'reply_to_id': reply,
      'forwarded': forwarded,
      'caption': caption,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('ImageMetadata', () {
    final fixture = File('test/fixtures/pixel.jpg').readAsBytesSync();

    test('a real JPEG with a GPS APP1 block loses it and still decodes', () async {
      final tagged = _withExif(fixture);
      expect(ImageMetadata.hasExif(tagged), isTrue);
      // The GPS pointer tag is in there before.
      expect(_contains(tagged, [0x25, 0x88]), isTrue);

      final clean = ImageMetadata.strip(tagged);
      expect(ImageMetadata.hasExif(clean), isFalse);
      expect(_contains(clean, 'Exif'.codeUnits), isFalse);
      expect(clean.length, lessThan(tagged.length));
      expect(clean.sublist(0, 2), [0xFF, 0xD8]);
      expect(clean.sublist(clean.length - 2), [0xFF, 0xD9]);

      final image = await decodeImageFromList(clean);
      expect(image.width, 64);
      expect(image.height, 48);
    });

    test('a JPEG without metadata comes back byte-identical in pixels', () {
      final clean = ImageMetadata.strip(fixture);
      expect(ImageMetadata.hasExif(clean), isFalse);
      // The fixture has only APP0/DQT/SOF/DHT/SOS: nothing to drop but the
      // frame bytes from SOS on are copied verbatim.
      final sosIn = _indexOf(fixture, [0xFF, 0xDA]);
      final sosOut = _indexOf(clean, [0xFF, 0xDA]);
      expect(clean.sublist(sosOut), fixture.sublist(sosIn));
    });

    test('garbage never throws', () {
      expect(ImageMetadata.strip(Uint8List.fromList([1, 2, 3])), [1, 2, 3]);
      expect(ImageMetadata.strip(Uint8List(0)), isEmpty);
      expect(ImageMetadata.strip(Uint8List.fromList([0xFF, 0xD8, 0xFF])), isNotNull);
    });

    test('PNG text and eXIf chunks are dropped, IHDR/IDAT/IEND kept', () {
      Uint8List chunk(String type, List<int> data) {
        final len = data.length;
        return Uint8List.fromList([
          len >> 24, (len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF,
          ...type.codeUnits, ...data, 0, 0, 0, 0,
        ]);
      }
      final sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      final png = Uint8List.fromList([
        ...sig,
        ...chunk('IHDR', List.filled(13, 0)),
        ...chunk('tEXt', 'GPS=here'.codeUnits),
        ...chunk('eXIf', [1, 2, 3]),
        ...chunk('IDAT', [9, 9]),
        ...chunk('IEND', []),
      ]);
      final out = ImageMetadata.strip(png);
      expect(_contains(out, 'tEXt'.codeUnits), isFalse);
      expect(_contains(out, 'eXIf'.codeUnits), isFalse);
      expect(_contains(out, 'IHDR'.codeUnits), isTrue);
      expect(_contains(out, 'IDAT'.codeUnits), isTrue);
      expect(_contains(out, 'IEND'.codeUnits), isTrue);
    });
  });

  group('groupIntoAlbums', () {
    test('consecutive photos from one sender within a minute fold into one row', () {
      final msgs = [
        _img('p4', secs: 40),
        _img('p3', secs: 30),
        _img('p2', secs: 20),
        _img('p1', secs: 10),
      ];
      final rows = groupIntoAlbums(msgs);
      expect(rows, hasLength(1));
      expect(rows.single.isAlbum, isTrue);
      expect(rows.single.first.id, 'p4');
      expect(rows.single.last.id, 'p1');
      expect(rows.single.id, 'p4');
    });

    test('a different sender, a gap, a reply, a forward or a deletion breaks the run', () {
      final msgs = [
        _img('p6', secs: 200), // alone: gap after p5
        _img('p5', secs: 100, sender: 'me'),
        _img('p4', secs: 95, sender: 'me'),
        _img('p3', secs: 90, forwarded: true), // forwards never join
        _img('p2', secs: 85, deleted: true), // tombstones never join
        _img('p1', secs: 80),
        _img('p0', secs: 75),
      ];
      final rows = groupIntoAlbums(msgs);
      expect(rows.map((r) => r.messages.map((m) => m.id).join(',')).toList(), [
        'p6',
        'p5,p4',
        'p3',
        'p2',
        'p1,p0',
      ]);
    });

    test('text in between and a custom window', () {
      final text = Message.fromJson({
        'id': 't',
        'conversation_id': 'c1',
        'sender_id': 'them',
        'type': 'text',
        'content': 'hi',
        'created_at': '2026-11-08T10:00:15Z',
      });
      final rows = groupIntoAlbums([_img('b', secs: 20), text, _img('a', secs: 10)]);
      expect(rows, hasLength(3));
      expect(rows.every((r) => !r.isAlbum), isTrue);
      final tight = groupIntoAlbums([_img('b', secs: 20), _img('a', secs: 10)], window: const Duration(seconds: 5));
      expect(tight, hasLength(2));
    });
  });

  group('Waveform', () {
    test('encodes any number of samples into 64 bytes, peak per slot', () {
      final levels = List<double>.generate(640, (i) => i % 10 == 9 ? 1.0 : 0.1);
      final w = Waveform.encode(levels);
      expect(w, hasLength(64));
      expect(w.every((b) => b == 255), isTrue, reason: 'every slot of 10 samples holds one peak');
      final short = Waveform.encode([0.0, 0.5, 1.0]);
      expect(short, hasLength(64));
      expect(short.last, 255);
      expect(short.first, 0);
      expect(Waveform.encode(const []), hasLength(64));
    });

    test('bars are normalised into 0.08–1.0 and a missing waveform is a stable placeholder', () {
      final bars = Waveform.bars(Waveform.encode([0.2, 0.9, 0.4]));
      expect(bars, hasLength(40));
      expect(bars.every((b) => b >= 0.08 && b <= 1.0), isTrue);
      expect(bars.reduce((a, b) => a > b ? a : b), closeTo(1.0, 1e-9));
      final a = Waveform.bars(null, seed: 'm1');
      final b = Waveform.bars(null, seed: 'm1');
      final c = Waveform.bars(null, seed: 'm2');
      expect(a, b);
      expect(a, isNot(c));
    });

    test('fromDb maps the recorder range', () {
      expect(Waveform.fromDb(-60), 0);
      expect(Waveform.fromDb(0), 1);
      expect(Waveform.fromDb(-30), closeTo(0.5, 1e-9));
      expect(Waveform.fromDb(-100), 0);
    });
  });

  group('models', () {
    test('Message carries caption, thumb key, waveform, dimensions and poll', () {
      final m = Message.fromJson({
        'id': 'v1',
        'conversation_id': 'c1',
        'sender_id': 'me',
        'type': 'video',
        'file_name': 'clip.mp4',
        'voice_duration_sec': 12,
        'caption': 'Look',
        'thumb_key': 'files/o/v1/poster.jpg',
        'waveform': 'AAD/',
        'media_width': 320,
        'media_height': 240,
        'seq': 7,
        'created_at': '2026-11-08T10:00:00Z',
      });
      expect(m.caption, 'Look');
      expect(m.thumbKey, endsWith('poster.jpg'));
      expect(m.waveform, [0, 0, 255]);
      expect(m.mediaWidth, 320);
      expect(m.mediaHeight, 240);
      expect(m.hasMedia, isTrue);
      expect(m.canForward, isTrue);
      final back = Message.fromJson(m.toJson());
      expect(back.caption, 'Look');
      expect(back.waveform, [0, 0, 255]);
      expect(back.mediaWidth, 320);
      expect(ReplyPreview.previewFor(m), 'Look');
    });

    test('PollData: counts, my picks, optimistic withVotes, not forwardable', () {
      final m = Message.fromJson({
        'id': 'q1',
        'conversation_id': 'c1',
        'sender_id': 'them',
        'type': 'poll',
        'created_at': '2026-11-08T10:00:00Z',
        'poll': {
          'question': 'Lunch?',
          'multiple': false,
          'options': [
            {'id': 'o2', 'position': 1, 'text': 'Sushi', 'voter_ids': ['a']},
            {'id': 'o1', 'position': 0, 'text': 'Pizza', 'voter_ids': ['a', 'b']},
          ],
        },
      });
      final p = m.poll!;
      expect(p.options.map((o) => o.id), ['o1', 'o2'], reason: 'sorted by position');
      expect(p.voterCount, 2);
      expect(p.options.first.voteCount, 2);
      expect(p.myOptionIds('a'), ['o1', 'o2']);
      expect(p.hasVoted('c'), isFalse);
      final mine = p.withVotes('c', ['o2']);
      expect(mine.options[1].voterIds, contains('c'));
      expect(mine.voterCount, 3);
      final unvoted = mine.withVotes('c', const []);
      expect(unvoted.hasVoted('c'), isFalse);
      expect(m.canForward, isFalse);
      expect(ReplyPreview.previewFor(m), 'Lunch?');
      expect(PollData.fromJson(p.toJson()).options.map((o) => o.text), ['Pizza', 'Sushi']);
    });

    test('UploadIntent: single vs multipart vs replay', () {
      final single = UploadIntent.fromJson({'intent_id': 'i', 'key': 'k', 'part_size': 8, 'expires_in': 1, 'put_url': 'https://put'});
      expect(single.isMultipart, isFalse);
      final multi = UploadIntent.fromJson({
        'intent_id': 'i',
        'key': 'k',
        'part_size': 8388608,
        'expires_in': 1,
        'upload_id': 'u',
        'part_urls': [
          {'part_number': 1, 'url': 'https://p1'},
          {'part_number': 2, 'url': 'https://p2'},
        ],
        'thumb_put_url': 'https://t',
      });
      expect(multi.isMultipart, isTrue);
      expect(multi.partUrls.map((p) => p.partNumber), [1, 2]);
      expect(multi.thumbPutUrl, 'https://t');
      final replay = UploadIntent.fromJson({
        'intent_id': 'i',
        'key': 'k',
        'part_size': 8,
        'expires_in': 1,
        'message': {'id': 'm9', 'conversation_id': 'c1', 'sender_id': 'me', 'type': 'file', 'created_at': '2026-11-08T10:00:00Z'},
      });
      expect(replay.message?.id, 'm9');
    });

    test('Conversation.media_export_allowed defaults off and round-trips', () {
      final c = Conversation.fromJson({
        'id': 'c1',
        'type': 'direct',
        'member_ids': ['me', 'them'],
        'created_at': '2026-11-01T00:00:00Z',
        'updated_at': '2026-11-08T10:00:00Z',
      });
      expect(c.mediaExportAllowed, isFalse);
      final on = Conversation.fromJson({...c.toJson(), 'media_export_allowed': true});
      expect(on.mediaExportAllowed, isTrue);
      expect(Conversation.fromJson(on.toJson()).mediaExportAllowed, isTrue);
    });
  });

  group('MediaSettings', () {
    test('defaults: photos on Wi-Fi only, everything else waits for a tap', () {
      const s = MediaSettings.defaults;
      expect(s.uploadQuality, UploadQuality.standard);
      expect(s.shouldAutoDownload(MediaDownloadKind.photos, NetworkType.wifi), isTrue);
      expect(s.shouldAutoDownload(MediaDownloadKind.photos, NetworkType.cellular), isFalse);
      for (final k in [MediaDownloadKind.video, MediaDownloadKind.voice, MediaDownloadKind.documents]) {
        expect(s.shouldAutoDownload(k, NetworkType.wifi), isFalse, reason: k.name);
      }
    });

    test('rules, quality sides and the JSON round trip', () {
      expect(UploadQuality.standard.maxSide, 1600);
      expect(UploadQuality.hd.maxSide, 2560);
      expect(UploadQuality.original.maxSide, isNull);
      expect(AutoDownloadRule.always.allowsOn(NetworkType.cellular), isTrue);
      expect(AutoDownloadRule.always.allowsOn(NetworkType.none), isFalse);
      expect(AutoDownloadRule.wifi.allowsOn(NetworkType.cellular), isFalse);
      final s = MediaSettings.defaults
          .copyWith(uploadQuality: UploadQuality.hd)
          .withRule(MediaDownloadKind.video, AutoDownloadRule.always);
      final back = MediaSettings.fromJson(s.toJson());
      expect(back.uploadQuality, UploadQuality.hd);
      expect(back.ruleFor(MediaDownloadKind.video), AutoDownloadRule.always);
      expect(back.ruleFor(MediaDownloadKind.photos), AutoDownloadRule.wifi);
      expect(MediaSettings.fromJson(null).uploadQuality, UploadQuality.standard);
      expect(UploadQuality.fromWire('bogus'), UploadQuality.standard);
    });
  });

  group('NetworkUsage', () {
    test('counts, persists through the store, resets with a fresh since', () {
      final store = _MemStore();
      final u = NetworkUsage(store: store);
      var notified = 0;
      u.addListener(() => notified++);
      u.addSent(1500);
      u.addReceived(2 * 1024 * 1024);
      expect(u.bytesSent, 1500);
      expect(u.bytesReceived, 2 * 1024 * 1024);
      expect(notified, 2);
      expect(store.saved?.$1, 1500);
      final again = NetworkUsage(store: store);
      expect(again.bytesReceived, 2 * 1024 * 1024, reason: 'loads what was saved');
      u.reset();
      expect(u.bytesSent, 0);
      expect(u.since, isNotNull);
      expect(NetworkUsage.format(512), '512 B');
      expect(NetworkUsage.format(2048), '2 KB');
      expect(NetworkUsage.format(3 * 1024 * 1024), '3.0 MB');
    });
  });
}

class _MemStore implements NetworkUsageStore {
  (int, int, DateTime?)? saved;
  @override
  (int, int, DateTime?)? load() => saved;
  @override
  void save(int sent, int received, DateTime? since) => saved = (sent, received, since);
}

bool _contains(Uint8List hay, List<int> needle) => _indexOf(hay, needle) >= 0;

int _indexOf(Uint8List hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

