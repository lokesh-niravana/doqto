import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/media.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/services/app_badge.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/data/services/outbox.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_socket.dart';

/// Batch 5 state: optimistic poll votes (single / multiple, unvote, rollback,
/// coalescing while a request runs), `poll_updated` fan-out with the
/// changed_at guard and the in-flight echo rule, sendPoll, and the presigned
/// upload flow (single PUT, 8 MB parts with ETags, poster PUT, progress,
/// client_id replay).

Map<String, dynamic> _poll({bool multiple = false, Map<String, List<String>> votes = const {}, String? changed}) => {
      'id': 'q1',
      'conversation_id': 'c1',
      'sender_id': 'them',
      'type': 'poll',
      'seq': 5,
      'created_at': '2026-11-08T10:00:00.000Z',
      'changed_at': changed,
      'poll': {
        'question': 'Lunch?',
        'multiple': multiple,
        'options': [
          {'id': 'o1', 'position': 0, 'text': 'Pizza', 'voter_ids': votes['o1'] ?? []},
          {'id': 'o2', 'position': 1, 'text': 'Sushi', 'voter_ids': votes['o2'] ?? []},
          {'id': 'o3', 'position': 2, 'text': 'Salad', 'voter_ids': votes['o3'] ?? []},
        ],
      },
    };

Conversation _conv() => Conversation.fromJson({
      'id': 'c1',
      'type': 'direct',
      'member_ids': ['me', 'them'],
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': '2026-11-08T10:00:00Z',
      'media_export_allowed': true,
    });

class _Repo extends ChatRepository {
  _Repo() : super(ApiClient());

  List<Message> history = [];
  final voteCalls = <List<String>>[];
  bool failVote = false;
  Completer<void>? gate;
  Map<String, dynamic>? pollReply;

  // Presigned flow bookkeeping.
  final intents = <Map<String, dynamic>>[];
  final puts = <(String url, int bytes, String contentType)>[];
  Map<String, dynamic>? completed;
  int partSize = 8 * 1024 * 1024;
  bool replay = false;
  bool multipart = false;

  @override
  Future<List<Conversation>> listConversations() async => [_conv()];

  @override
  Future<List<Message>> listMessages(String conversationId,
      {DateTime? before, int? afterSeq, DateTime? changedSince, DateTime? beforeDate}) async {
    if (changedSince != null || afterSeq != null) return const [];
    return history;
  }

  @override
  Future<Message> vote(String messageId, List<String> optionIds) async {
    voteCalls.add(List.of(optionIds));
    if (gate != null) await gate!.future;
    if (failVote) throw ApiException('poll_single_choice', status: 422);
    final votes = <String, List<String>>{for (final o in optionIds) o: ['me']};
    return Message.fromJson(pollReply ?? _poll(votes: votes, changed: '2026-11-08T10:01:00.000Z'));
  }

  @override
  Future<Message> sendPoll(String conversationId,
      {required String question, required List<String> options, bool multiple = false, String? clientId, String? replyToId}) async {
    return Message.fromJson({
      ..._poll(multiple: multiple),
      'id': 'q-new',
      'sender_id': 'me',
      'seq': 9,
      'poll': {
        'question': question,
        'multiple': multiple,
        'options': [for (final (i, o) in options.indexed) {'id': 'n$i', 'position': i, 'text': o, 'voter_ids': []}],
      },
    });
  }

  @override
  Future<UploadIntent> uploadIntent(String conversationId,
      {required String fileName, required String contentType, required int sizeBytes, String? clientId, bool withThumb = false}) async {
    intents.add({'file': fileName, 'type': contentType, 'size': sizeBytes, 'client_id': clientId, 'thumb': withThumb});
    if (replay) {
      return UploadIntent.fromJson({
        'intent_id': 'old',
        'key': 'k',
        'part_size': partSize,
        'expires_in': 1,
        'message': {'id': 'already', 'conversation_id': 'c1', 'sender_id': 'me', 'type': 'video', 'seq': 3, 'created_at': '2026-11-08T10:00:00Z'},
      });
    }
    final parts = (sizeBytes / partSize).ceil();
    return UploadIntent.fromJson({
      'intent_id': 'i1',
      'key': 'files/o/x/$fileName',
      'part_size': partSize,
      'expires_in': 3600,
      if (!multipart) 'put_url': 'https://s3/single',
      if (multipart) 'upload_id': 'u1',
      if (multipart) 'part_urls': [for (var p = 1; p <= parts; p++) {'part_number': p, 'url': 'https://s3/part$p'}],
      if (withThumb) 'thumb_put_url': 'https://s3/thumb',
    });
  }

  @override
  Future<String> putPresigned(String url, List<int> bytes, {required String contentType, void Function(int sent, int total)? onProgress}) async {
    puts.add((url, bytes.length, contentType));
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    onProgress?.call(bytes.length, bytes.length);
    return 'etag-${puts.length}';
  }

  @override
  Future<Message> uploadComplete(String conversationId,
      {required String intentId, List<(int, String)> parts = const [], String? caption, int? durationSec, int? width, int? height, bool hasThumb = false}) async {
    completed = {
      'intent': intentId,
      'parts': [for (final (n, e) in parts) '$n:$e'],
      'caption': caption,
      'duration': durationSec,
      'width': width,
      'height': height,
      'thumb': hasThumb,
    };
    return Message.fromJson({'id': 'v-done', 'conversation_id': 'c1', 'sender_id': 'me', 'type': 'video', 'seq': 10, 'created_at': '2026-11-08T10:00:00Z', 'caption': caption});
  }
}

class _Cache extends ChatCache {
  final msgs = <String, List<Message>>{};
  List<Conversation>? convs;
  @override
  List<Message>? messages(String convId) => msgs[convId];
  @override
  Future<void> putMessages(String convId, List<Message> list) async => msgs[convId] = list;
  @override
  List<Conversation>? conversations() => convs;
  @override
  Future<void> putConversations(List<Conversation> list) async => convs = list;
  @override
  bool keepArchived() => true;
}

class _Outbox extends Outbox {
  final entries = <OutboxEntry>[];
  @override
  Future<void> add(OutboxEntry e) async => entries.add(e);
  @override
  Future<void> remove(String clientId) async => entries.removeWhere((e) => e.clientId == clientId);
  @override
  List<OutboxEntry> pending({String? conversationId}) =>
      [for (final e in entries) if (conversationId == null || e.conversationId == conversationId) e];
}

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        AuthStage.signedIn,
        User.fromJson({
          'id': 'me',
          'phone': '+15550000101',
          'full_name': 'Dr Me',
          'npi_number': '1234567893',
          'role': 'doctor',
          'created_at': '2026-09-05T00:00:00Z',
        }),
      );
}

class _NoBadge extends AppBadge {
  @override
  Future<void> set(int count) async {}
}

void main() {
  late _Repo repo;
  late FakeSocket socket;
  late ProviderContainer c;

  setUp(() {
    repo = _Repo();
    socket = FakeSocket();
    c = ProviderContainer(overrides: [
      chatRepositoryProvider.overrideWithValue(repo),
      websocketClientProvider.overrideWithValue(socket),
      chatCacheProvider.overrideWithValue(_Cache()),
      outboxProvider.overrideWithValue(_Outbox()),
      appBadgeProvider.overrideWithValue(_NoBadge()),
      authProvider.overrideWith(_Auth.new),
      realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
    ]);
    addTearDown(c.dispose);
  });

  Future<List<Message>> load() async {
    final msgs = await c.read(messagesProvider('c1').future);
    c.listen(messagesProvider('c1'), (_, _) {});
    return msgs;
  }

  Message byId(String id) => c.read(messagesProvider('c1')).value!.firstWhere((m) => m.id == id);
  PollData poll() => byId('q1').poll!;
  MessagesNotifier n() => c.read(messagesProvider('c1').notifier);

  group('vote', () {
    setUp(() => repo.history = [Message.fromJson(_poll())]);

    test('single choice: optimistic tick, server confirms, one PUT', () async {
      await load();
      final f = n().vote('q1', ['o2']);
      expect(poll().myOptionIds('me'), ['o2'], reason: 'ticks before the server answers');
      expect(poll().voterCount, 1);
      await f;
      expect(poll().myOptionIds('me'), ['o2']);
      expect(repo.voteCalls, [['o2']]);
      expect(byId('q1').changedAt, isNotNull);
    });

    test('single choice sends only the first option even if asked for two', () async {
      await load();
      await n().vote('q1', ['o1', 'o3']);
      expect(repo.voteCalls, [['o1']]);
    });

    test('multiple choice keeps every pick; empty list is an unvote (DELETE)', () async {
      repo.history = [Message.fromJson(_poll(multiple: true, votes: {'o1': ['me']}))];
      await load();
      await n().vote('q1', ['o1', 'o3']);
      expect(poll().myOptionIds('me'), ['o1', 'o3']);
      await n().vote('q1', const []);
      expect(repo.voteCalls.last, isEmpty);
      expect(poll().hasVoted('me'), isFalse);
    });

    test('rollback on failure and rethrow', () async {
      await load();
      repo.failVote = true;
      await expectLater(n().vote('q1', ['o1']), throwsA(isA<ApiException>()));
      expect(poll().hasVoted('me'), isFalse);
      expect(poll().voterCount, 0);
    });

    test('taps while a request runs collapse into the latest wanted pick', () async {
      await load();
      repo.gate = Completer<void>();
      final first = n().vote('q1', ['o1']);
      unawaited(n().vote('q1', ['o2']));
      unawaited(n().vote('q1', ['o3']));
      expect(poll().myOptionIds('me'), ['o3'], reason: 'UI follows the last tap at once');
      repo.gate!.complete();
      repo.gate = null;
      await first;
      await settle();
      expect(repo.voteCalls.first, ['o1']);
      expect(repo.voteCalls.last, ['o3']);
      expect(repo.voteCalls.length, lessThanOrEqualTo(2));
      expect(poll().myOptionIds('me'), ['o3']);
    });
  });

  group('poll_updated', () {
    setUp(() => repo.history = [Message.fromJson(_poll(changed: '2026-11-08T10:00:30.000Z'))]);

    test('replaces the tallies for a newer change', () async {
      await load();
      socket.emit(WsEventServer.pollUpdated, {
        'conversation_id': 'c1',
        'message_id': 'q1',
        'actor_id': 'them',
        'changed_at': '2026-11-08T10:02:00.000Z',
        'poll': _poll(votes: {'o1': ['them']})['poll'],
      });
      await settle();
      expect(poll().options.first.voterIds, ['them']);
      expect(poll().voterCount, 1);
    });

    test('a stale event (older changed_at) is dropped', () async {
      await load();
      socket.emit(WsEventServer.pollUpdated, {
        'conversation_id': 'c1',
        'message_id': 'q1',
        'actor_id': 'them',
        'changed_at': '2026-11-08T09:00:00.000Z',
        'poll': _poll(votes: {'o1': ['them']})['poll'],
      });
      await settle();
      expect(poll().voterCount, 0);
    });

    test('while my vote is in flight: my echo is ignored, theirs is applied with my pick on top', () async {
      await load();
      repo.gate = Completer<void>();
      final mine = n().vote('q1', ['o2']);
      // My own echo (actor me) must not clobber the optimistic state.
      socket.emit(WsEventServer.pollUpdated, {
        'conversation_id': 'c1',
        'message_id': 'q1',
        'actor_id': 'me',
        'changed_at': '2026-11-08T10:03:00.000Z',
        'poll': _poll()['poll'],
      });
      await settle();
      expect(poll().myOptionIds('me'), ['o2']);
      // Someone else votes: their tally lands, my pending pick stays.
      socket.emit(WsEventServer.pollUpdated, {
        'conversation_id': 'c1',
        'message_id': 'q1',
        'actor_id': 'them',
        'changed_at': '2026-11-08T10:03:30.000Z',
        'poll': _poll(votes: {'o1': ['them']})['poll'],
      });
      await settle();
      expect(poll().options[0].voterIds, ['them']);
      expect(poll().myOptionIds('me'), ['o2']);
      repo.gate!.complete();
      repo.gate = null;
      await mine;
    });
  });

  test('sendPoll inserts the server row at the top', () async {
    repo.history = [Message.fromJson(_poll())];
    await load();
    final m = await n().sendPoll(question: 'Coffee?', options: ['Yes', 'No'], multiple: true);
    expect(m.id, 'q-new');
    expect(c.read(messagesProvider('c1')).value!.first.id, 'q-new');
    expect(byId('q-new').poll!.multiple, isTrue);
    expect(byId('q-new').poll!.options.map((o) => o.text), ['Yes', 'No']);
  });

  group('deliverPresigned', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('presign_'));
    tearDown(() => dir.deleteSync(recursive: true));

    File write(String name, int bytes) => File('${dir.path}/$name')..writeAsBytesSync(Uint8List(bytes));

    test('small video: one PUT, poster PUT as image/jpeg, complete with duration and size', () async {
      final clip = write('clip.mp4', 1000);
      final poster = write('poster.jpg', 100);
      final progress = <double>[];
      final e = OutboxEntry(
        clientId: 'cid1',
        conversationId: 'c1',
        kind: OutboxKind.video,
        createdAt: DateTime.now(),
        filePath: clip.path,
        fileName: 'clip.mp4',
        mimeType: 'video/mp4',
        durationSec: 3,
        caption: 'hi',
        thumbPath: poster.path,
        width: 320,
        height: 240,
      );
      final m = await deliverPresigned(repo, e, onProgress: progress.add);
      expect(m.id, 'v-done');
      expect(repo.intents.single, {'file': 'clip.mp4', 'type': 'video/mp4', 'size': 1000, 'client_id': 'cid1', 'thumb': true});
      expect(repo.puts.map((p) => p.$1), ['https://s3/single', 'https://s3/thumb']);
      expect(repo.puts[0].$3, 'video/mp4');
      expect(repo.puts[1], ('https://s3/thumb', 100, 'image/jpeg'));
      expect(repo.completed, {
        'intent': 'i1',
        'parts': <String>[],
        'caption': 'hi',
        'duration': 3,
        'width': 320,
        'height': 240,
        'thumb': true,
      });
      expect(progress.last, 1.0);
      expect(progress.first, lessThan(1.0));
    });

    test('a big document goes up in parts with ETags and reports progress across them', () async {
      repo.partSize = 1024; // small parts so the test stays fast
      final doc = write('big.pdf', 2500);
      final progress = <double>[];
      final e = OutboxEntry(
        clientId: 'cid2',
        conversationId: 'c1',
        kind: OutboxKind.media,
        createdAt: DateTime.now(),
        filePath: doc.path,
        fileName: 'big.pdf',
        mimeType: 'application/pdf',
      );
      repo.multipart = true;
      await deliverPresigned(repo, e, onProgress: progress.add);
      expect(repo.puts.map((p) => p.$2), [1024, 1024, 452]);
      expect(repo.puts.every((p) => p.$3 == 'application/pdf'), isTrue);
      expect(repo.completed!['parts'], ['1:etag-1', '2:etag-2', '3:etag-3']);
      expect(repo.completed!['duration'], isNull, reason: 'documents carry no duration');
      expect(progress, isNotEmpty);
      expect(progress.last, closeTo(1.0, 1e-9));
      // Monotonic: every reading is at least the previous one.
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1] - 1e-9));
      }
    });

    test('client_id replay short-circuits: nothing is PUT again', () async {
      repo.replay = true;
      final clip = write('clip.mp4', 500);
      final e = OutboxEntry(
        clientId: 'cid3',
        conversationId: 'c1',
        kind: OutboxKind.video,
        createdAt: DateTime.now(),
        filePath: clip.path,
        mimeType: 'video/mp4',
      );
      final m = await deliverPresigned(repo, e);
      expect(m.id, 'already');
      expect(repo.puts, isEmpty);
      expect(repo.completed, isNull);
    });

    test('a video entry always goes presigned; a voice entry keeps its waveform through the box', () async {
      final clip = write('c.mp4', 10);
      final video = OutboxEntry(clientId: 'a', conversationId: 'c1', kind: OutboxKind.video, createdAt: DateTime.now(), filePath: clip.path, fileName: 'c.mp4', mimeType: 'video/mp4', durationSec: 1);
      await deliverOutboxEntry(repo, video);
      expect(repo.intents.single['size'], 10, reason: 'even a tiny clip takes the intent route');
      final small = write('note.pdf', 10);
      final wave = base64Encode(Uint8List.fromList(List.filled(64, 7)));
      final voice = OutboxEntry(clientId: 'b', conversationId: 'c1', kind: OutboxKind.voice, createdAt: DateTime.now(), filePath: small.path, fileName: 'v.m4a', durationSec: 2, waveform: wave);
      expect(voice.toMap()['waveform'], wave);
      expect(OutboxEntry.fromMap(voice.toMap()).waveform, wave);
    });
  });
}
