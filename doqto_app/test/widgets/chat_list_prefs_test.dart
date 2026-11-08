import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/conversation_prefs.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/presence.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/presence_state.dart';
import 'package:doqto_app/state/realtime_state.dart';
import 'package:doqto_app/ui/screens/chat/chat_list_screen.dart';

import '../support/fake_socket.dart';

/// Chat list preferences (batch 3): filter chips, pinned-first order with the
/// pin / mute icons and unread dot, the Archived (n) row, swipe actions, the
/// More sheet (pin, mute → duration sheet, clear / delete confirms), the
/// draft preview and the multi-select bar.
Conversation _conv(
  String id,
  String name, {
  String type = 'direct',
  int unread = 0,
  Map<String, dynamic>? prefs,
  String lastAt = '2026-11-08T10:00:00Z',
}) =>
    Conversation.fromJson({
      'id': id,
      'type': type,
      'name': type == 'group' ? name : null,
      'display_name': type == 'direct' ? name : null,
      'member_ids': ['me', 'peer-$id'],
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': lastAt,
      'last_message_at': lastAt,
      'last_message_preview': 'last line in $name',
      'last_message_type': 'text',
      'last_message_sender_id': 'peer-$id',
      'unread_count': unread,
      'prefs': ?prefs,
    });

class _Repo extends ChatRepository {
  _Repo() : super(ApiClient());
  List<Conversation> convs = [];
  final patches = <(String, Map<String, dynamic>)>[];
  final removed = <String>[];

  @override
  Future<List<Conversation>> listConversations() async => List.of(convs);

  @override
  Future<ConversationPrefs> updatePrefs(String id, Map<String, dynamic> patch) async {
    patches.add((id, patch));
    final cur = convs.firstWhere((c) => c.id == id).prefs;
    var next = cur;
    if (patch.containsKey('pinned')) {
      next = next.copyWith(pinnedAt: () => patch['pinned'] == true ? DateTime.now().toUtc() : null);
    }
    if (patch.containsKey('archived')) next = next.copyWith(archived: patch['archived'] as bool);
    if (patch.containsKey('muted_until')) {
      final v = patch['muted_until'] as String?;
      next = next.copyWith(mutedUntil: () => v == null ? null : DateTime.parse(v));
    }
    if (patch.containsKey('marked_unread')) {
      next = next.copyWith(markedUnread: patch['marked_unread'] as bool);
    }
    if (patch['clear_chat'] == true) next = next.copyWith(clearedBeforeSeq: () => 9);
    if (patch['delete_chat'] == true) {
      next = next.copyWith(clearedBeforeSeq: () => 9, hiddenUntilSeq: () => 9);
    }
    convs = [for (final c in convs) c.id == id ? c.copyWith(prefs: next) : c];
    return next;
  }

  @override
  Future<void> removeMember(String conversationId, String userId) async =>
      removed.add(conversationId);

  @override
  Future<List<Message>> listMessages(String conversationId,
      {DateTime? before, int? afterSeq, DateTime? changedSince}) async => const [];
}

class _Cache extends ChatCache {
  final drafts_ = <String, String>{};
  @override
  List<Conversation>? conversations() => null;
  @override
  Future<void> putConversations(List<Conversation> list) async {}
  @override
  Future<void> putMessages(String convId, List<Message> m) async {}
  @override
  List<Message>? messages(String convId) => null;
  @override
  String? draft(String convId) => drafts_[convId];
  @override
  Future<void> putDraft(String convId, String? text) async {}
  @override
  Map<String, String> drafts() => Map.of(drafts_);
  @override
  bool keepArchived() => true;
  @override
  Future<void> setKeepArchived(bool value) async {}
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
}

/// No presence fetches in a widget test.
class _NoPresence extends PresenceNotifier {
  @override
  Map<String, PresenceInfo> build() => const {};
  @override
  Future<void> track(Iterable<String> ids) async {}
}

// ignore: library_private_types_in_public_api
late _Repo repo;
// ignore: library_private_types_in_public_api
late _Cache cache;

Widget app() => ProviderScope(
      overrides: [
        websocketClientProvider.overrideWithValue(FakeSocket()),
        chatRepositoryProvider.overrideWithValue(repo),
        chatCacheProvider.overrideWithValue(cache),
        authProvider.overrideWith(_Auth.new),
        presenceProvider.overrideWith(_NoPresence.new),
        realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
      ],
      child: const MaterialApp(home: ChatListScreen()),
    );

Future<void> open(WidgetTester tester) async {
  await tester.pumpWidget(app());
  await tester.pumpAndSettle();
}

List<String> titles(WidgetTester tester) => [
      for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
        if (t.title is Text) (t.title as Text).data!,
    ];

void main() {
  setUp(() {
    repo = _Repo()
      ..convs = [
        _conv('n', 'Newest Peer', unread: 2, lastAt: '2026-11-08T10:00:00Z'),
        _conv('p', 'Pinned Peer',
            prefs: {'pinned_at': '2026-11-07T09:00:00Z'}, lastAt: '2026-11-02T00:00:00Z'),
        _conv('g', 'Rounds Group', type: 'group', lastAt: '2026-11-06T10:00:00Z'),
        _conv('a', 'Archived Peer', unread: 1, prefs: {'archived': true}),
        _conv('m', 'Marked Peer',
            prefs: {'marked_unread': true, 'muted_until': '9999-12-31T00:00:00Z'},
            lastAt: '2026-11-05T10:00:00Z'),
      ];
    cache = _Cache();
  });

  testWidgets('pinned first, icons and dot, Archived (1) row at the top', (tester) async {
    await open(tester);
    expect(titles(tester), [
      'Archived (1)',
      'Pinned Peer',
      'Newest Peer',
      'Rounds Group',
      'Marked Peer',
    ]);
    expect(find.byKey(const ValueKey('chat-pinned-p')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-muted-m')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-unread-dot-m')), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'numeric badge on the real unread');
    // Archived chats never show in All.
    expect(find.text('Archived Peer'), findsNothing);
  });

  testWidgets('filter chips: Unread, Groups, Archived; the row opens Archived', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('chat-filter-unread')));
    await tester.pumpAndSettle();
    // No pinned chat leads this view, so the Archived row drops to the bottom.
    expect(titles(tester), ['Newest Peer', 'Marked Peer', 'Archived (1)']);
    await tester.tap(find.byKey(const ValueKey('chat-filter-groups')));
    await tester.pumpAndSettle();
    expect(titles(tester), ['Rounds Group', 'Archived (1)']);
    await tester.tap(find.byKey(const ValueKey('chat-archived-row')));
    await tester.pumpAndSettle();
    expect(titles(tester), ['Archived Peer']);
    expect(find.byKey(const ValueKey('chat-archived-row')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat-filter-all')));
    await tester.pumpAndSettle();
    expect(find.text('Newest Peer'), findsOneWidget);
  });

  testWidgets('no pinned chats → Archived row sits at the bottom', (tester) async {
    repo.convs = [
      _conv('n', 'Newest Peer'),
      _conv('a', 'Archived Peer', prefs: {'archived': true}),
    ];
    await open(tester);
    expect(titles(tester), ['Newest Peer', 'Archived (1)']);
  });

  testWidgets('swipe left reveals Archive and archives the chat', (tester) async {
    await open(tester);
    await tester.drag(find.byKey(const ValueKey('chat-row-n')), const Offset(-140, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-swipe-archive-n')));
    await tester.pumpAndSettle();
    expect(repo.patches.single.$1, 'n');
    expect(repo.patches.single.$2, {'archived': true});
    expect(find.text('Newest Peer'), findsNothing, reason: 'moved under Archived');
    expect(find.text('Archived (2)'), findsOneWidget);
    expect(find.widgetWithText(SnackBar, Strings.chatArchivedToast), findsOneWidget);
  });

  testWidgets('swipe right reveals More; Pin from the sheet', (tester) async {
    await open(tester);
    await tester.drag(find.byKey(const ValueKey('chat-row-n')), const Offset(140, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-swipe-more-n')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-action-pin')), findsOneWidget);
    expect(find.text(Strings.chatPin), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-action-pin')));
    await tester.pumpAndSettle();
    expect(repo.patches.single.$2, {'pinned': true});
    expect(find.byKey(const ValueKey('chat-pinned-n')), findsOneWidget);
    // Two pinned now, the newer pin after the older one.
    expect(titles(tester).sublist(0, 3), ['Archived (1)', 'Pinned Peer', 'Newest Peer']);
  });

  testWidgets('Mute → duration sheet → 8 hours; Unmute afterwards', (tester) async {
    await open(tester);
    await tester.drag(find.byKey(const ValueKey('chat-row-n')), const Offset(140, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-swipe-more-n')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-action-mute')));
    await tester.pumpAndSettle();
    expect(find.text(Strings.chatMuteTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-opt-mute-1w')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-opt-mute-always')), findsOneWidget);
    final before = DateTime.now().toUtc();
    await tester.tap(find.byKey(const ValueKey('chat-opt-mute-8h')));
    await tester.pumpAndSettle();
    final until = DateTime.parse(repo.patches.single.$2['muted_until'] as String);
    expect(until.difference(before).inMinutes, inInclusiveRange(479, 481));
    expect(find.byKey(const ValueKey('chat-muted-n')), findsOneWidget);
    // Sheet now offers Unmute.
    await tester.drag(find.byKey(const ValueKey('chat-row-n')), const Offset(140, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-swipe-more-n')));
    await tester.pumpAndSettle();
    expect(find.text(Strings.chatUnmute), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-action-mute')));
    await tester.pumpAndSettle();
    expect(repo.patches.last.$2, {'muted_until': null});
    expect(find.byKey(const ValueKey('chat-muted-n')), findsNothing);
  });

  testWidgets('Mark unread shows the dot; Clear and Delete ask first', (tester) async {
    await open(tester);
    Future<void> openSheet(String id) async {
      await tester.drag(find.byKey(ValueKey('chat-row-$id')), const Offset(140, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('chat-swipe-more-$id')));
      await tester.pumpAndSettle();
    }

    await openSheet('g');
    await tester.tap(find.byKey(const ValueKey('chat-action-unread')));
    await tester.pumpAndSettle();
    expect(repo.patches.last.$2, {'marked_unread': true});
    expect(find.byKey(const ValueKey('chat-unread-dot-g')), findsOneWidget);

    await openSheet('g');
    await tester.tap(find.byKey(const ValueKey('chat-action-clear')));
    await tester.pumpAndSettle();
    expect(find.text(Strings.chatClearTitle), findsOneWidget);
    await tester.tap(find.text(Strings.cancel));
    await tester.pumpAndSettle();
    expect(repo.patches.where((p) => p.$2.containsKey('clear_chat')), isEmpty);
    await openSheet('g');
    await tester.tap(find.byKey(const ValueKey('chat-action-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-confirm-clear')));
    await tester.pumpAndSettle();
    expect(repo.patches.last.$2, {'clear_chat': true});

    // Delete on a group reads as Leave and calls the leave endpoint.
    await openSheet('g');
    expect(find.text('Leave group'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-action-delete')));
    await tester.pumpAndSettle();
    expect(find.text(Strings.chatLeaveGroupTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-confirm-delete')));
    await tester.pumpAndSettle();
    expect(repo.removed, ['g']);
    expect(find.text('Rounds Group'), findsNothing);

    // Delete on a direct chat goes through prefs.
    await openSheet('n');
    await tester.tap(find.byKey(const ValueKey('chat-action-delete')));
    await tester.pumpAndSettle();
    expect(find.text(Strings.chatDeleteChatTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-confirm-delete')));
    await tester.pumpAndSettle();
    expect(repo.patches.last.$2, {'delete_chat': true});
    expect(find.text('Newest Peer'), findsNothing);
  });

  testWidgets('a draft shows in red instead of the last message', (tester) async {
    cache.drafts_['n'] = 'Will send this later';
    await open(tester);
    final rich = tester.widget<Text>(find.byKey(const ValueKey('chat-draft-n')));
    final span = rich.textSpan! as TextSpan;
    expect(span.children!.length, 2);
    expect((span.children![0] as TextSpan).text, Strings.chatDraftPrefix);
    expect((span.children![1] as TextSpan).text, 'Will send this later');
    expect(find.text('last line in Newest Peer'), findsNothing);
  });

  testWidgets('long-press multi-select: Pin, Mute, Archive, Mark unread, Delete', (tester) async {
    await open(tester);
    await tester.longPress(find.text('Newest Peer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rounds Group'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    for (final k in ['pin', 'mute', 'archive', 'unread', 'delete']) {
      expect(find.byKey(ValueKey('chat-select-$k')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('chat-select-archive')));
    await tester.pumpAndSettle();
    expect(repo.patches.map((p) => p.$1).toSet(), {'n', 'g'});
    expect(repo.patches.every((p) => p.$2['archived'] == true), isTrue);
    expect(find.text('2 selected'), findsNothing, reason: 'selection clears');
    expect(find.text('Archived (3)'), findsOneWidget);
  });
}
