import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/websocket_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/services/app_badge.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/data/services/chat_document_store.dart';
import 'package:doqto_app/data/services/chat_media_cache.dart';
import 'package:doqto_app/data/services/outbox.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_media_backend.dart';
import 'support/fake_socket.dart';

/// Batch 4 state: optimistic star with rollback and in-flight coalescing,
/// the private `message_starred` echo, optimistic pin / unpin with rollback,
/// `message_pinned` / `message_unpinned` fan-outs, replies through the
/// outbox, ensureLoaded paging and jump-to-date gap filling.
Map<String, dynamic> _json(String id, int seq, {String created = '2026-11-08T10:00:00.000Z', bool starred = false}) =>
    {
      'id': id,
      'conversation_id': 'c1',
      'sender_id': 'them',
      'type': 'text',
      'content': id,
      'seq': seq,
      'created_at': created,
      'starred': starred,
    };

Conversation _conv({String? pinned, String? until}) => Conversation.fromJson({
      'id': 'c1',
      'type': 'direct',
      'member_ids': ['me', 'them'],
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': '2026-11-08T10:00:00Z',
      'pinned_message_id': pinned,
      'pinned_until': until,
    });

class _Repo extends ChatRepository {
  _Repo() : super(ApiClient());

  /// Full history, newest first; pages are cut from it.
  List<Message> history = [];
  final starCalls = <(String, bool)>[];
  final pinCalls = <String>[];
  final sent = <Map<String, dynamic>>[];
  final beforeDates = <DateTime>[];
  bool failStar = false;

  /// Sends fail as if offline: the entry stays in the outbox.
  bool failSend = false;
  final hidden = <List<String>>[];
  final deleted = <String>[];

  @override
  Future<void> hideMessages(List<String> messageIds) async => hidden.add(messageIds);

  @override
  Future<Message> deleteMessage(String messageId) async {
    deleted.add(messageId);
    return Message.fromJson({
      ..._json(messageId, 99),
      'sender_id': 'me',
      'content': null,
      'deleted_at': '2026-11-08T10:01:00.000Z',
    });
  }
  bool failPin = false;

  /// Older-page and jump-to-date fetches fail as if offline.
  bool failOlder = false;
  Completer<void>? gate;
  int pageSize = 50;

  @override
  Future<List<Conversation>> listConversations() async => [_conv()];

  @override
  Future<List<Message>> listMessages(String conversationId,
      {DateTime? before, int? afterSeq, DateTime? changedSince, DateTime? beforeDate}) async {
    if (changedSince != null || afterSeq != null) return const [];
    if (failOlder && (before != null || beforeDate != null)) {
      throw ApiException('connection error');
    }
    Iterable<Message> src = history;
    if (before != null) src = src.where((m) => m.createdAt.isBefore(before));
    if (beforeDate != null) {
      beforeDates.add(beforeDate);
      final end = DateTime.utc(beforeDate.year, beforeDate.month, beforeDate.day, 23, 59, 59);
      src = src.where((m) => !m.createdAt.isAfter(end));
    }
    return src.take(pageSize).toList();
  }

  @override
  Future<Message> setStarred(String messageId, bool starred) async {
    starCalls.add((messageId, starred));
    if (gate != null) await gate!.future;
    if (failStar) throw ApiException('rate_limited', status: 429);
    final m = history.where((x) => x.id == messageId).firstOrNull ??
        Message.fromJson(_json(messageId, 0));
    return m.copyWith(starred: starred);
  }

  @override
  Future<Conversation> pinMessage(String conversationId, String messageId, int durationSec) async {
    pinCalls.add('pin $messageId $durationSec');
    if (failPin) throw ApiException('not_authorized', status: 403);
    return _conv(pinned: messageId, until: '2026-12-08T10:00:00Z');
  }

  @override
  Future<Conversation> unpinMessage(String conversationId) async {
    pinCalls.add('unpin');
    if (failPin) throw ApiException('not_authorized', status: 403);
    return _conv();
  }

  @override
  Future<Message> sendText(String conversationId, String content, {String? clientId, String? replyToId}) async {
    sent.add({'content': content, 'client_id': clientId, 'reply_to_id': replyToId});
    if (gate != null) await gate!.future;
    if (failSend) throw ApiException('connection error');
    return Message.fromJson({
      ..._json('srv-$clientId', 99),
      'sender_id': 'me',
      'content': content,
      'client_id': clientId,
      'reply_to_id': replyToId,
      'reply_to': replyToId == null
          ? null
          : {'id': replyToId, 'sender_id': 'them', 'type': 'text', 'preview': replyToId},
    });
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
      // hide() evicts the hidden rows' media and documents: keep both off
      // the real cache manager and path_provider.
      chatMediaCacheProvider.overrideWithValue(ChatMediaCache(FakeMediaBackend())),
      chatDocumentStoreProvider.overrideWithValue(
        ChatDocumentStore(root: () async => Directory.systemTemp.createTemp('docs_')),
      ),
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

  group('star', () {
    setUp(() => repo.history = [Message.fromJson(_json('m2', 2)), Message.fromJson(_json('m1', 1))]);

    test('optimistic on, confirmed by the server, one call', () async {
      await load();
      final f = c.read(messagesProvider('c1').notifier).star('m1', true);
      expect(byId('m1').starred, isTrue, reason: 'flips before the server answers');
      await f;
      expect(byId('m1').starred, isTrue);
      expect(repo.starCalls, [('m1', true)]);
    });

    test('rollback on failure and rethrow', () async {
      await load();
      repo.failStar = true;
      await expectLater(c.read(messagesProvider('c1').notifier).star('m1', true), throwsA(isA<ApiException>()));
      expect(byId('m1').starred, isFalse);
    });

    test('taps while a request runs collapse into the latest wanted state', () async {
      await load();
      repo.gate = Completer<void>();
      final n = c.read(messagesProvider('c1').notifier);
      final first = n.star('m1', true);
      unawaited(n.star('m1', false));
      unawaited(n.star('m1', true));
      expect(byId('m1').starred, isTrue);
      repo.gate!.complete();
      repo.gate = null;
      await first;
      await settle();
      expect(repo.starCalls.first, ('m1', true));
      expect(repo.starCalls.length, lessThanOrEqualTo(2));
      expect(byId('m1').starred, isTrue);
    });

    test('message_starred from my other device patches the row', () async {
      await load();
      socket.emit(WsEventServer.messageStarred, {'conversation_id': 'c1', 'message_id': 'm2', 'starred': true});
      await settle();
      expect(byId('m2').starred, isTrue);
      socket.emit(WsEventServer.messageStarred, {'conversation_id': 'other', 'message_id': 'm2', 'starred': false});
      await settle();
      expect(byId('m2').starred, isTrue, reason: 'another conversation is ignored');
    });

    test('a fanned-out edit (starred=false) keeps my star', () async {
      await load();
      await c.read(messagesProvider('c1').notifier).star('m1', true);
      socket.emit(WsEventServer.messageEdited, {..._json('m1', 1), 'content': 'edited', 'edited_at': '2026-11-08T10:05:00Z'});
      await settle();
      expect(byId('m1').content, 'edited');
      expect(byId('m1').starred, isTrue);
    });
  });

  group('star: a message the thread has not loaded (gallery / viewer)', () {
    setUp(() => repo.history = [Message.fromJson(_json('m2', 2))]);

    test('goes to the server instead of returning as if it had worked', () async {
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      expect(n.messageById('old'), isNull);
      await n.star('old', true);
      expect(repo.starCalls, [('old', true)]);
      await n.star('old', false);
      expect(repo.starCalls.last, ('old', false));
    });

    test('a server failure throws, so the caller cannot toast "Starred"', () async {
      await load();
      repo.failStar = true;
      await expectLater(
        c.read(messagesProvider('c1').notifier).star('old', true),
        throwsA(isA<ApiException>()),
      );
    });

    test('a loaded message that cannot be starred throws message_not_starrable', () async {
      repo.history = [
        Message.fromJson({..._json('gone', 3), 'deleted_at': '2026-11-08T10:01:00.000Z'}),
      ];
      await load();
      await expectLater(
        c.read(messagesProvider('c1').notifier).star('gone', true),
        throwsA(isA<ApiException>().having((e) => e.detail, 'detail', 'message_not_starrable')),
      );
      expect(repo.starCalls, isEmpty);
    });
  });

  group('deleting an unsent message', () {
    List<OutboxEntry> queued() => c.read(outboxProvider).pending();

    /// One message that failed to send: a failed bubble, still in the outbox.
    Future<String> failedSend() async {
      repo.history = [Message.fromJson(_json('m1', 1))];
      await load();
      repo.failSend = true;
      await c.read(messagesProvider('c1').notifier).sendText('do not send');
      repo.failSend = false;
      final row = c.read(messagesProvider('c1')).value!.first;
      expect(row.status, MessageStatus.failed);
      expect(row.id, row.clientId, reason: 'an unsent row is keyed by its client id');
      expect(queued().single.clientId, row.clientId);
      repo.sent.clear();
      return row.id;
    }

    Future<void> drain() async {
      c.read(outboxDrainerProvider); // drains once when first read
      await settle();
      socket.emitState(WsConnState.connected); // and on every reconnect
      await settle();
    }

    test('hide (delete for me) discards the outbox entry: drain sends nothing', () async {
      final id = await failedSend();
      await c.read(messagesProvider('c1').notifier).hide([id]);
      expect(queued(), isEmpty);
      expect(repo.hidden, isEmpty, reason: 'the server knows nothing of a client id');
      expect(c.read(messagesProvider('c1')).value!.map((m) => m.id), ['m1']);
      await drain();
      expect(repo.sent, isEmpty);
    });

    test('hide of a mix: the unsent one is discarded, the sent one hidden on the server', () async {
      final id = await failedSend();
      await c.read(messagesProvider('c1').notifier).hide([id, 'm1']);
      expect(queued(), isEmpty);
      expect(repo.hidden, [
        ['m1'],
      ]);
      expect(c.read(messagesProvider('c1')).value, isEmpty);
      await drain();
      expect(repo.sent, isEmpty);
    });

    test('delete for everyone discards the outbox entry: drain sends nothing', () async {
      final id = await failedSend();
      await c.read(messagesProvider('c1').notifier).delete(id);
      expect(queued(), isEmpty);
      expect(repo.deleted, isEmpty);
      expect(c.read(messagesProvider('c1')).value!.map((m) => m.id), ['m1']);
      await drain();
      expect(repo.sent, isEmpty);
    });

    test('without the discard the drain does send it (the test can fail)', () async {
      await failedSend();
      await drain();
      expect(repo.sent.single['content'], 'do not send');
    });

    test('discarded while the request is on the wire: withdrawn once it lands', () async {
      repo.history = [Message.fromJson(_json('m1', 1))];
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      repo.gate = Completer<void>();
      final f = n.sendText('too late');
      await settle();
      final pending = c.read(messagesProvider('c1')).value!.first;
      expect(pending.status, MessageStatus.sending);
      await n.hide([pending.id]);
      expect(queued(), isEmpty);
      repo.gate!.complete();
      repo.gate = null;
      await f;
      expect(repo.deleted, ['srv-${pending.clientId}']);
      expect(
        c.read(messagesProvider('c1')).value!.where((m) => m.content == 'too late'),
        isEmpty,
        reason: 'never left readable after the user deleted it',
      );
    });
  });

  group('pin', () {
    test('optimistic pin then the server conversation; unpin; rollback', () async {
      await c.read(conversationsProvider.future);
      c.listen(conversationsProvider, (_, _) {});
      final n = c.read(conversationsProvider.notifier);
      final f = n.pinMessage('c1', 'm7', 86400);
      expect(n.conversation('c1')!.pinnedMessageId, 'm7');
      expect(n.conversation('c1')!.pinnedUntil!.difference(DateTime.now().toUtc()).inHours, inInclusiveRange(23, 24));
      await f;
      expect(n.conversation('c1')!.pinnedUntil, DateTime.utc(2026, 12, 8, 10));
      expect(repo.pinCalls, ['pin m7 86400']);

      await n.unpinMessage('c1');
      expect(n.conversation('c1')!.pinnedMessageId, isNull);

      repo.failPin = true;
      await expectLater(n.pinMessage('c1', 'm8', 604800), throwsA(isA<ApiException>()));
      expect(n.conversation('c1')!.pinnedMessageId, isNull, reason: 'rolled back');
    });

    test('message_pinned / message_unpinned events patch in place without a refetch', () async {
      await c.read(conversationsProvider.future);
      c.listen(conversationsProvider, (_, _) {});
      final n = c.read(conversationsProvider.notifier);
      socket.emit(WsEventServer.messagePinned, {
        'conversation_id': 'c1',
        'message_id': 'm3',
        'pinned_until': '2026-11-15T10:00:00Z',
        'actor_id': 'them',
      });
      await settle();
      expect(n.conversation('c1')!.pinnedMessageId, 'm3');
      expect(n.conversation('c1')!.activePinnedMessageId(DateTime.utc(2026, 11, 9)), 'm3');
      expect(n.conversation('c1')!.activePinnedMessageId(DateTime.utc(2026, 11, 16)), isNull, reason: 'lapsed');
      socket.emit(WsEventServer.messageUnpinned, {
        'conversation_id': 'c1',
        'message_id': 'm3',
        'pinned_until': null,
        'actor_id': null,
      });
      await settle();
      expect(n.conversation('c1')!.pinnedMessageId, isNull);
    });
  });

  group('reply', () {
    test('sendText with a quote: pending bubble shows it, the wire carries reply_to_id', () async {
      repo.history = [Message.fromJson(_json('m1', 1))];
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      repo.gate = Completer<void>();
      final f = n.sendText('re: m1', replyTo: ReplyPreview.of(byId('m1')));
      await settle();
      final pending = c.read(messagesProvider('c1')).value!.first;
      expect(pending.status, MessageStatus.sending);
      expect(pending.replyTo!.id, 'm1');
      repo.gate!.complete();
      repo.gate = null;
      await f;
      expect(repo.sent.single['reply_to_id'], 'm1');
      final srv = c.read(messagesProvider('c1')).value!.first;
      expect(srv.status, MessageStatus.sent);
      expect(srv.replyTo!.preview, 'm1');
    });
  });

  group('history paging', () {
    // ps*2+10 messages, one per hour from Nov 1 00:00 UTC; newest first.
    const ps = AppConstants.messagesPageSize;
    const total = ps * 2 + 10;
    final base = DateTime.utc(2026, 11, 1);
    String idAt(int i) => 'm$i';

    setUp(() {
      repo.pageSize = ps;
      repo.history = [
        for (var i = total; i >= 1; i--)
          Message.fromJson(_json(idAt(i), i, created: base.add(Duration(hours: i)).toIso8601String())),
      ];
    });

    test('ensureLoaded pages back until the message is held; false when history ends', () async {
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      expect(n.messageById('m5'), isNull);
      expect(await n.ensureLoaded('m5'), isTrue);
      expect(n.messageById('m5'), isNotNull);
      expect(await n.ensureLoaded('nope'), isFalse);
      expect(n.hasMore, isFalse);
    });

    test('loadOlderWhile stops when the predicate is satisfied', () async {
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      final want = idAt(ps + 5); // on the second page
      final ok = await n.loadOlderWhile((loaded) => !loaded.any((m) => m.id == want));
      expect(ok, isTrue);
      expect(n.messageById(want), isNotNull);
      expect(n.messageById('m1'), isNull, reason: 'did not page further than needed');
    });

    test('jumpToDate fetches before_date and fills the gap so the list stays continuous', () async {
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      // Newest message on Nov 2 is hour 47 — well below the first page.
      final id = await n.jumpToDate(DateTime.utc(2026, 11, 2));
      expect(id, 'm47');
      expect(repo.beforeDates.single, DateTime.utc(2026, 11, 2));
      final ids = c.read(messagesProvider('c1')).value!.map((m) => m.id).toList();
      expect(ids, [for (var i = total; i >= 1; i--) idAt(i)], reason: 'gap filled, no holes, no dupes');
      expect(n.hasMore, isFalse);
      // Already loaded → answered locally, no second fetch.
      expect(await n.jumpToDate(DateTime.utc(2026, 11, 3)), 'm71');
      expect(repo.beforeDates.length, 1);
      // Before the first message → nothing.
      expect(await n.jumpToDate(DateTime.utc(2026, 10, 1)), isNull);
    });

    // A fetch that fails is not "history ran out": each helper must say so,
    // or the screen tells the user a message is gone / there are no matches
    // / nothing happened that day.
    test('a failed older page is kept as an error, not as the end of history', () async {
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      final held = c.read(messagesProvider('c1')).value!.length;
      repo.failOlder = true;
      await n.loadOlder();
      expect(n.olderLoadError, isA<ApiException>());
      expect(n.hasMore, isTrue);
      expect(n.loadingOlder, isFalse);
      expect(c.read(messagesProvider('c1')).value!.length, held);

      // Retry once the connection is back: the error clears, the page lands.
      repo.failOlder = false;
      await n.loadOlder();
      expect(n.olderLoadError, isNull);
      expect(c.read(messagesProvider('c1')).value!.length, greaterThan(held));
    });

    test('Retry notifies at once: loadingOlder set and the error cleared before the page lands', () async {
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      repo.failOlder = true;
      await n.loadOlder();
      expect(n.olderLoadError, isNotNull);

      repo.failOlder = false;
      // What each listener saw when it was notified: (loading, has error).
      final seen = <(bool, bool)>[];
      final sub = c.listen(
        messagesProvider('c1'),
        (_, _) => seen.add((n.loadingOlder, n.olderLoadError != null)),
      );
      final pending = n.loadOlder();
      // Synchronously, before the response: spinner row, no Retry row.
      expect(seen, [(true, false)]);
      await pending;
      sub.close();
      expect(seen.last, (false, false));
    });

    test('ensureLoaded throws when a page fails instead of answering "not found"', () async {
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      repo.failOlder = true;
      await expectLater(n.ensureLoaded('m5'), throwsA(isA<ApiException>()));
      expect(n.hasMore, isTrue);
      repo.failOlder = false;
      expect(await n.ensureLoaded('m5'), isTrue);
    });

    test('loadOlderWhile throws when a page fails instead of answering "exhausted"', () async {
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      repo.failOlder = true;
      await expectLater(
        n.loadOlderWhile((loaded) => !loaded.any((m) => m.id == 'm1')),
        throwsA(isA<ApiException>()),
      );
      expect(n.loadingOlder, isFalse);
    });

    test('jumpToDate throws when the fetch fails instead of answering "nothing that day"', () async {
      await load();
      final n = c.read(messagesProvider('c1').notifier);
      repo.failOlder = true;
      await expectLater(
        n.jumpToDate(DateTime.utc(2026, 11, 2)),
        throwsA(isA<ApiException>()),
      );
      expect(n.loadingOlder, isFalse, reason: 'busy flag reset in finally');
      repo.failOlder = false;
      expect(await n.jumpToDate(DateTime.utc(2026, 11, 2)), 'm47');
    });
  });
}
