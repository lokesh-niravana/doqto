import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/chat_theme.dart';
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
import 'package:doqto_app/state/settings_state.dart';
import 'package:doqto_app/ui/screens/settings/chat_theme_picker_screen.dart';

import '../support/fake_socket.dart';
import '../support/settings_test_support.dart';

/// Chat colour picker (batch 6): 12 themes + Default; the default picker
/// writes the device setting, the per-chat picker PATCHes prefs.theme
/// optimistically and rolls back with a toast when the server refuses.
Conversation _conv(String id, {Map<String, dynamic>? prefs}) => Conversation.fromJson({
      'id': id,
      'type': 'direct',
      'display_name': 'Peer $id',
      'member_ids': ['me', 'peer-$id'],
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': '2026-11-08T10:00:00Z',
      'last_message_at': '2026-11-08T10:00:00Z',
      'unread_count': 0,
      'prefs': ?prefs,
    });

class _Repo extends ChatRepository {
  _Repo() : super(ApiClient());
  List<Conversation> convs = [];
  final patches = <(String, Map<String, dynamic>)>[];
  bool fail = false;

  @override
  Future<List<Conversation>> listConversations() async => List.of(convs);

  @override
  Future<ConversationPrefs> updatePrefs(String id, Map<String, dynamic> patch) async {
    patches.add((id, patch));
    if (fail) throw Exception('server said no');
    final cur = convs.firstWhere((c) => c.id == id).prefs;
    final next = cur.copyWith(theme: () => patch['theme'] as String?);
    convs = [for (final c in convs) c.id == id ? c.copyWith(prefs: next) : c];
    return next;
  }

  @override
  Future<List<Message>> listMessages(String conversationId,
          {DateTime? before,
          int? afterSeq,
          DateTime? changedSince,
          DateTime? beforeDate}) async =>
      const [];
}

class _Cache extends ChatCache {
  @override
  List<Conversation>? conversations() => null;
  @override
  Future<void> putConversations(List<Conversation> list) async {}
  @override
  Future<void> putMessages(String convId, List<Message> m) async {}
  @override
  List<Message>? messages(String convId) => null;
  @override
  Map<String, String> drafts() => const {};
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

/// No presence polling in a widget test.
class _NoPresence extends PresenceNotifier {
  @override
  Map<String, PresenceInfo> build() => const {};
  @override
  Future<void> track(Iterable<String> ids) async {}
}

final _hive = TempSettingsStore();
late _Repo _repo;

Widget _app({String? conversationId}) => ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(_hive.store),
        websocketClientProvider.overrideWithValue(FakeSocket()),
        chatRepositoryProvider.overrideWithValue(_repo),
        chatCacheProvider.overrideWithValue(_Cache()),
        authProvider.overrideWith(_Auth.new),
        presenceProvider.overrideWith(_NoPresence.new),
        realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
      ],
      child: MaterialApp(home: ChatThemePickerScreen(conversationId: conversationId)),
    );

Future<void> _open(WidgetTester tester, {String? conversationId}) async {
  // 13 tiles in two columns: a tall surface keeps every tile hit-testable.
  tester.view.physicalSize = const Size(800, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(conversationId: conversationId));
  await tester.pumpAndSettle();
}

Finder _tile(String id) => find.byKey(ValueKey('chat-theme-$id'));

bool _selected(WidgetTester tester, Finder tile) =>
    find.descendant(of: tile, matching: find.byIcon(Icons.check_circle)).evaluate().isNotEmpty;

Future<void> _tapTile(WidgetTester tester, Finder tile) async {
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => _hive.open('chat_theme_picker_test'));
  tearDownAll(() => _hive.close());
  setUp(() async {
    await _hive.fresh();
    _repo = _Repo()..convs = [_conv('c1'), _conv('c2', prefs: {'theme': ChatTheme.all[2].id})];
  });

  testWidgets('shows Default + every theme, Default selected when unset', (tester) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('chat-theme-grid')), findsOneWidget);
    expect(_tile('default'), findsOneWidget);
    expect(_selected(tester, _tile('default')), isTrue);
    for (final t in ChatTheme.all) {
      expect(_tile(t.id), findsOneWidget);
      expect(find.descendant(of: _tile(t.id), matching: find.text(t.name)), findsOneWidget);
    }
  });

  testWidgets('default picker: tapping a theme stores it; Default clears it', (tester) async {
    await _open(tester);
    final t = ChatTheme.all[4];
    await _tapTile(tester, _tile(t.id));
    expect(_hive.store.chatTheme, t.id);
    expect(_selected(tester, _tile(t.id)), isTrue);
    expect(_selected(tester, _tile('default')), isFalse);
    await _tapTile(tester, _tile('default'));
    expect(_hive.store.chatTheme, isNull);
    expect(_selected(tester, _tile('default')), isTrue);
    expect(_repo.patches, isEmpty, reason: 'device default never hits the server');
  });

  testWidgets('per-chat picker: reflects prefs.theme and PATCHes {"theme": id}', (tester) async {
    await _open(tester, conversationId: 'c2');
    expect(_selected(tester, _tile(ChatTheme.all[2].id)), isTrue);
    expect(_selected(tester, _tile('default')), isFalse);
    final t = ChatTheme.all[7];
    await _tapTile(tester, _tile(t.id));
    expect(_repo.patches, hasLength(1));
    expect(_repo.patches.single.$1, 'c2');
    expect(_repo.patches.single.$2, {'theme': t.id});
    expect(_selected(tester, _tile(t.id)), isTrue);
    expect(_hive.store.chatTheme, isNull, reason: 'per-chat pick leaves the device default alone');
    await _tapTile(tester, _tile('default'));
    expect(_repo.patches.last.$2, {'theme': null});
    expect(_selected(tester, _tile('default')), isTrue);
  });

  testWidgets('per-chat picker: server failure rolls back and toasts', (tester) async {
    _repo.fail = true;
    await _open(tester, conversationId: 'c1');
    expect(_selected(tester, _tile('default')), isTrue);
    await _tapTile(tester, _tile(ChatTheme.all[1].id));
    expect(_repo.patches, hasLength(1));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(_selected(tester, _tile('default')), isTrue, reason: 'rolled back');
    expect(_selected(tester, _tile(ChatTheme.all[1].id)), isFalse);
  });
}
