import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/conversation_prefs.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/notification_settings.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/repositories/settings_repository.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/data/services/tone_player.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/realtime_state.dart';
import 'package:doqto_app/ui/screens/settings/tone_picker_screen.dart';

import '../support/fake_socket.dart';

/// Tone picker (batch 6): tapping a tone previews it and saves it — to the
/// global messages/groups tone, or to a conversation's custom_tone pref.
class _Settings extends SettingsRepository {
  _Settings() : super(ApiClient());
  NotificationSettings server = const NotificationSettings(messagesTone: 'chime');
  final patches = <Map<String, dynamic>>[];

  @override
  Future<NotificationSettings> getNotifications() async => server;

  @override
  Future<NotificationSettings> patchNotifications(
    Map<String, dynamic> patch,
  ) async {
    patches.add(patch);
    server = NotificationSettings.fromJson({...server.toJson(), ...patch});
    return server;
  }
}

Conversation _conv(String id, {Map<String, dynamic>? prefs}) =>
    Conversation.fromJson({
      'id': id,
      'type': 'direct',
      'display_name': 'Dr B',
      'member_ids': ['me', 'peer'],
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': '2026-11-08T10:00:00Z',
      'unread_count': 0,
      'prefs': ?prefs,
    });

class _Chat extends ChatRepository {
  _Chat() : super(ApiClient());
  List<Conversation> convs = [_conv('c1', prefs: {'custom_tone': 'bell'})];
  final patches = <(String, Map<String, dynamic>)>[];

  @override
  Future<List<Conversation>> listConversations() async => List.of(convs);

  @override
  Future<ConversationPrefs> updatePrefs(
    String id,
    Map<String, dynamic> patch,
  ) async {
    patches.add((id, patch));
    final cur = convs.firstWhere((c) => c.id == id).prefs;
    var next = cur;
    if (patch.containsKey('custom_tone')) {
      next = next.copyWith(customTone: () => patch['custom_tone'] as String?);
    }
    convs = [for (final c in convs) c.id == id ? c.copyWith(prefs: next) : c];
    return next;
  }

  @override
  Future<List<Message>> listMessages(
    String conversationId, {
    DateTime? before,
    int? afterSeq,
    DateTime? changedSince,
    DateTime? beforeDate,
  }) async =>
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
  String? draft(String convId) => null;
  @override
  Future<void> putDraft(String convId, String? text) async {}
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

// ignore: library_private_types_in_public_api
late _Settings settings;
// ignore: library_private_types_in_public_api
late _Chat chat;
late FakeTonePlayer player;

Widget app(String target) => ProviderScope(
      overrides: [
        websocketClientProvider.overrideWithValue(FakeSocket()),
        settingsRepositoryProvider.overrideWithValue(settings),
        chatRepositoryProvider.overrideWithValue(chat),
        chatCacheProvider.overrideWithValue(_Cache()),
        authProvider.overrideWith(_Auth.new),
        tonePlayerProvider.overrideWithValue(player),
        realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
      ],
      child: MaterialApp(home: TonePickerScreen(target: target)),
    );

Icon? _trailing(WidgetTester tester, String tone) =>
    tester.widget<ListTile>(find.byKey(ValueKey('tone-$tone'))).trailing
        as Icon?;

void main() {
  setUp(() {
    settings = _Settings();
    chat = _Chat();
    player = FakeTonePlayer();
  });

  Future<void> pump(WidgetTester tester, String target) async {
    // Tall enough that every tone row is built.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(target));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every tone with a check on the current one',
      (tester) async {
    await pump(tester, 'messages');
    for (final t in NotificationTones.all) {
      expect(find.byKey(ValueKey('tone-$t')), findsOneWidget);
    }
    expect(_trailing(tester, 'chime'), isNotNull);
    expect(_trailing(tester, 'default'), isNull);
  });

  testWidgets('tapping a tone previews it and PATCHes messages_tone',
      (tester) async {
    await pump(tester, 'messages');
    await tester.tap(find.byKey(const ValueKey('tone-glass')));
    await tester.pumpAndSettle();
    expect(player.played, ['glass']);
    expect(settings.patches, [
      {'messages_tone': 'glass'}
    ]);
    expect(_trailing(tester, 'glass'), isNotNull);
    expect(_trailing(tester, 'chime'), isNull);
  });

  testWidgets('groups target PATCHes groups_tone', (tester) async {
    await pump(tester, 'groups');
    await tester.tap(find.byKey(const ValueKey('tone-none')));
    await tester.pumpAndSettle();
    expect(player.played, ['none']);
    expect(settings.patches, [
      {'groups_tone': 'none'}
    ]);
  });

  testWidgets('conversation target PATCHes the chat custom_tone pref',
      (tester) async {
    await pump(tester, 'c1');
    expect(_trailing(tester, 'bell'), isNotNull);

    await tester.tap(find.byKey(const ValueKey('tone-pop')));
    await tester.pumpAndSettle();
    expect(chat.patches.single.$1, 'c1');
    expect(chat.patches.single.$2, {'custom_tone': 'pop'});
    expect(settings.patches, isEmpty);
    expect(_trailing(tester, 'pop'), isNotNull);

    // Default clears the override.
    await tester.tap(find.byKey(const ValueKey('tone-default')));
    await tester.pumpAndSettle();
    expect(chat.patches.last.$2, {'custom_tone': null});
    expect(_trailing(tester, 'default'), isNotNull);
  });

  testWidgets('leaving the screen stops playback', (tester) async {
    await pump(tester, 'messages');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    expect(player.stops, 1);
  });
}
