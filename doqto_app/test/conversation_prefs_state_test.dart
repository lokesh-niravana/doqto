
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/conversation_prefs.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/services/app_badge.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_socket.dart';

Conversation _conv(String id, {int unread = 0, Map<String, dynamic>? prefs, String type = 'direct'}) =>
    Conversation.fromJson({
      'id': id,
      'type': type,
      'member_ids': ['me', 'them'],
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': '2026-11-08T10:00:00Z',
      'last_message_at': '2026-11-08T10:00:00Z',
      'last_message_preview': 'hello',
      'last_message_type': 'text',
      'last_message_sender_id': 'them',
      'unread_count': unread,
      'prefs': ?prefs,
    });

class _Repo extends ChatRepository {
  _Repo() : super(ApiClient());
  List<Conversation> convs = [_conv('c1'), _conv('c2', unread: 3)];
  final patches = <(String, Map<String, dynamic>)>[];
  final removed = <(String, String)>[];
  bool fail = false;
  int lists = 0;

  @override
  Future<List<Conversation>> listConversations() async {
    lists++;
    return List.of(convs);
  }

  @override
  Future<ConversationPrefs> updatePrefs(String id, Map<String, dynamic> patch) async {
    patches.add((id, patch));
    if (fail) throw ApiException('pin_limit', status: 409);
    final cur = convs.firstWhere((c) => c.id == id).prefs;
    var next = cur;
    if (patch.containsKey('pinned')) {
      next = next.copyWith(
          pinnedAt: () => patch['pinned'] == true ? DateTime.utc(2026, 11, 8, 12) : null);
    }
    if (patch.containsKey('archived')) next = next.copyWith(archived: patch['archived'] as bool);
    if (patch.containsKey('muted_until')) {
      final v = patch['muted_until'] as String?;
      next = next.copyWith(mutedUntil: () => v == null ? null : DateTime.parse(v));
    }
    if (patch.containsKey('marked_unread')) {
      next = next.copyWith(markedUnread: patch['marked_unread'] as bool);
    }
    if (patch['clear_chat'] == true) next = next.copyWith(clearedBeforeSeq: () => 7);
    if (patch['delete_chat'] == true) {
      next = next.copyWith(clearedBeforeSeq: () => 7, hiddenUntilSeq: () => 7);
    }
    convs = [for (final c in convs) c.id == id ? c.copyWith(prefs: next) : c];
    return next;
  }

  @override
  Future<void> removeMember(String conversationId, String userId) async {
    removed.add((conversationId, userId));
  }

  @override
  Future<List<Message>> listMessages(String conversationId,
      {DateTime? before, int? afterSeq, DateTime? changedSince}) async => const [];
}

/// In-memory stand-in: no Hive box in unit tests.
class _Cache extends ChatCache {
  List<Conversation>? stored;
  final drafts_ = <String, String>{};
  final msgs = <String, List<Message>>{};
  bool keep = true;
  @override
  List<Conversation>? conversations() => stored;
  @override
  Future<void> putConversations(List<Conversation> list) async => stored = list;
  @override
  Future<void> putMessages(String convId, List<Message> m) async => msgs[convId] = m;
  @override
  List<Message>? messages(String convId) => msgs[convId];
  @override
  String? draft(String convId) => drafts_[convId];
  @override
  Future<void> putDraft(String convId, String? text) async {
    if (text == null) {
      drafts_.remove(convId);
    } else {
      drafts_[convId] = text;
    }
  }
  @override
  Map<String, String> drafts() => Map.of(drafts_);
  @override
  bool keepArchived() => keep;
  @override
  Future<void> setKeepArchived(bool value) async => keep = value;
}

class _Badge extends AppBadge {
  final values = <int>[];
  @override
  Future<void> set(int count) async => values.add(count);
}

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState(
        AuthStage.signedIn,
        User.fromJson({
          'id': 'me',
          'phone': '+15550000101',
          'full_name': 'Dr A',
          'npi_number': '1234567893',
          'role': 'doctor',
          'created_at': '2026-09-05T00:00:00Z',
        }),
      );
  void signOutLocally() => state = const AuthState(AuthStage.signedOut, null);
}

void main() {
  late _Repo repo;
  late _Cache cache;
  late FakeSocket socket;
  late _Badge badge;
  late ProviderContainer c;

  setUp(() {
    repo = _Repo();
    cache = _Cache();
    socket = FakeSocket();
    badge = _Badge();
    c = ProviderContainer(overrides: [
      websocketClientProvider.overrideWithValue(socket),
      chatRepositoryProvider.overrideWithValue(repo),
      chatCacheProvider.overrideWithValue(cache),
      appBadgeProvider.overrideWithValue(badge),
      authProvider.overrideWith(_Auth.new),
      realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
    ]);
  });
  tearDown(() => c.dispose());

  ConversationsNotifier n() => c.read(conversationsProvider.notifier);
  Conversation conv(String id) =>
      c.read(conversationsProvider).value!.firstWhere((x) => x.id == id);

  test('pin is optimistic, then confirmed by the server', () async {
    await c.read(conversationsProvider.future);
    final f = n().pin('c1', true);
    expect(conv('c1').prefs.isPinned, isTrue, reason: 'before the network answers');
    await f;
    expect(conv('c1').prefs.pinnedAt, DateTime.utc(2026, 11, 8, 12));
    expect(repo.patches.single.$1, 'c1');
    expect(repo.patches.single.$2, {'pinned': true});
    expect(cache.stored!.firstWhere((x) => x.id == 'c1').prefs.isPinned, isTrue);
  });

  test('a refused patch rolls back and rethrows', () async {
    await c.read(conversationsProvider.future);
    repo.fail = true;
    await expectLater(n().pin('c1', true), throwsA(isA<ApiException>()));
    expect(conv('c1').prefs.isPinned, isFalse);
  });

  test('archive / mute / mark unread send the wire fields', () async {
    await c.read(conversationsProvider.future);
    await n().archive('c1', true);
    final until = DateTime.utc(2026, 11, 9);
    await n().mute('c1', until);
    await n().markUnread('c1', true);
    expect(repo.patches.map((p) => p.$2).toList(), [
      {'archived': true},
      {'muted_until': until.toIso8601String()},
      {'marked_unread': true},
    ]);
    expect(conv('c1').prefs.archived, isTrue);
    expect(conv('c1').prefs.isMuted(DateTime.utc(2026, 11, 8)), isTrue);
    expect(conv('c1').prefs.markedUnread, isTrue);
    await n().mute('c1', null);
    expect(repo.patches.last.$2, {'muted_until': null});
    expect(conv('c1').prefs.mutedUntil, isNull);
  });

  test('conversation_prefs_updated from another device patches in place', () async {
    await c.read(conversationsProvider.future);
    final before = repo.lists;
    socket.emit(WsEventServer.conversationPrefsUpdated, {
      'conversation_id': 'c2',
      'prefs': {'archived': true, 'marked_unread': false},
    });
    await settle();
    expect(conv('c2').prefs.archived, isTrue);
    expect(repo.lists, before, reason: 'no refetch for a prefs frame');
  });

  test('clear chat drops the preview, unread and cached messages', () async {
    await c.read(conversationsProvider.future);
    cache.msgs['c2'] = [];
    await n().clearChat('c2');
    expect(repo.patches.single.$1, 'c2');
    expect(repo.patches.single.$2, {'clear_chat': true});
    expect(conv('c2').unreadCount, 0);
    expect(conv('c2').lastMessagePreview, isNull);
    expect(conv('c2').prefs.clearedBeforeSeq, 7);
    expect(cache.msgs['c2'], isEmpty);
  });

  test('delete chat: direct hides via prefs, group leaves', () async {
    repo.convs = [_conv('d'), _conv('g', type: 'group')];
    await c.read(conversationsProvider.future);
    await n().deleteChat('d');
    expect(repo.patches.single.$1, 'd');
    expect(repo.patches.single.$2, {'delete_chat': true});
    await n().deleteChat('g');
    expect(repo.removed.single.$1, 'g');
    expect(repo.removed.single.$2, 'me');
    expect(c.read(conversationsProvider).value, isEmpty);
  });

  test('keep archived off: an archived chat with unread comes back', () async {
    cache.keep = false;
    repo.convs = [_conv('a', unread: 2, prefs: {'archived': true}), _conv('b', prefs: {'archived': true})];
    await c.read(conversationsProvider.future);
    await settle();
    expect(repo.patches.single.$1, 'a');
    expect(repo.patches.single.$2, {'archived': false});
    expect(conv('a').prefs.archived, isFalse);
    expect(conv('b').prefs.archived, isTrue, reason: 'nothing new in b');
  });

  test('keep archived on (default): archived chats stay put', () async {
    repo.convs = [_conv('a', unread: 2, prefs: {'archived': true})];
    await c.read(conversationsProvider.future);
    await settle();
    expect(repo.patches, isEmpty);
    expect(c.read(keepArchivedProvider), isTrue);
    await c.read(keepArchivedProvider.notifier).set(false);
    expect(cache.keep, isFalse);
    await settle();
    expect(repo.patches.single.$1, 'a');
    expect(repo.patches.single.$2, {'archived': false});
  });

  test('drafts persist through the cache and clear on demand', () async {
    cache.drafts_['c1'] = 'hello there';
    expect(c.read(draftsProvider), {'c1': 'hello there'});
    await c.read(draftsProvider.notifier).set('c2', 'typing…');
    expect(cache.drafts_['c2'], 'typing…');
    await c.read(draftsProvider.notifier).set('c2', '   ');
    expect(c.read(draftsProvider).containsKey('c2'), isFalse);
    expect(cache.drafts_.containsKey('c2'), isFalse);
    await c.read(draftsProvider.notifier).clear('c1');
    expect(c.read(draftsProvider), isEmpty);
  });

  test('badge follows the unread total and clears on sign-out', () async {
    c.read(appBadgeSyncProvider);
    await c.read(conversationsProvider.future);
    await settle();
    expect(c.read(unreadTotalProvider), 3);
    expect(badge.values.last, 3);
    await n().mute('c2', ConversationPrefs.alwaysUntil);
    await settle();
    expect(badge.values.last, 0, reason: 'muted chats do not count');
    await n().mute('c2', null);
    await n().markUnread('c1', true);
    await settle();
    expect(badge.values.last, 4);
    (c.read(authProvider.notifier) as _Auth).signOutLocally();
    await settle();
    expect(badge.values.last, 0);
  });
}
