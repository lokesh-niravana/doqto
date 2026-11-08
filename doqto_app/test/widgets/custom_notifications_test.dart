import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/conversation_prefs.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/realtime_state.dart';
import 'package:doqto_app/ui/screens/settings/custom_notifications_screen.dart';

import '../support/fake_socket.dart';

/// Chat → Custom notifications (batch 6): the switch turns the per-chat
/// override on/off, vibrate PATCHes custom_vibrate, mute goes through the
/// chat list's mute sheet.
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
  List<Conversation> convs = [_conv('c1')];
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
    if (patch.containsKey('custom_vibrate')) {
      next = next.copyWith(
          customVibrate: () => patch['custom_vibrate'] as String?);
    }
    if (patch.containsKey('muted_until')) {
      final v = patch['muted_until'] as String?;
      next = next.copyWith(
          mutedUntil: () => v == null ? null : DateTime.parse(v));
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
late _Chat chat;

Widget app() => ProviderScope(
      overrides: [
        websocketClientProvider.overrideWithValue(FakeSocket()),
        chatRepositoryProvider.overrideWithValue(chat),
        chatCacheProvider.overrideWithValue(_Cache()),
        authProvider.overrideWith(_Auth.new),
        realtimeRefreshDebounceProvider.overrideWithValue(Duration.zero),
      ],
      child: const MaterialApp(
        home: CustomNotificationsScreen(conversationId: 'c1'),
      ),
    );

bool _switchOn(WidgetTester tester) => tester
    .widget<SwitchListTile>(
        find.byKey(const ValueKey('chatnotif-switch-use_custom')))
    .value;

void main() {
  setUp(() {
    chat = _Chat();
  });

  testWidgets('off by default; tone row disabled; mute shows Not muted',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isFalse);
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('chatnotif-row-tone')))
          .enabled,
      isFalse,
    );
    expect(find.byKey(const ValueKey('chatnotif-row-vibrate')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('chatnotif-value-mute')))
          .data,
      'Not muted',
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('turning custom on, picking vibrate, then off', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chatnotif-switch-use_custom')));
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isTrue);
    expect(chat.patches.last.$1, 'c1');
    expect(chat.patches.last.$2, {'custom_vibrate': 'default'});
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('chatnotif-row-tone')))
          .enabled,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('chatnotif-row-vibrate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatnotif-opt-vibrate-short')));
    await tester.pumpAndSettle();
    expect(chat.patches.last.$2, {'custom_vibrate': 'short'});
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('chatnotif-value-vibrate')))
          .data,
      'Short',
    );

    await tester.tap(find.byKey(const ValueKey('chatnotif-switch-use_custom')));
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isFalse);
    expect(chat.patches.last.$2,
        {'custom_tone': null, 'custom_vibrate': null});
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('shows the stored custom tone', (tester) async {
    chat.convs = [_conv('c1', prefs: {'custom_tone': 'glass'})];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(_switchOn(tester), isTrue);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('chatnotif-value-tone')))
          .data,
      'Glass',
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('mute row opens the duration sheet and mutes', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chatnotif-row-mute')));
    await tester.pumpAndSettle();
    final always = find.byKey(const ValueKey('chat-opt-mute-always'));
    expect(always, findsOneWidget);
    await tester.tap(always);
    await tester.pumpAndSettle();
    expect(chat.patches.last.$2.keys, ['muted_until']);
    expect(chat.patches.last.$2['muted_until'], isNotNull);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('chatnotif-value-mute')))
          .data,
      'Muted',
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('iOS: vibrate row disabled with footer', (tester) async {
    chat.convs = [_conv('c1', prefs: {'custom_tone': 'glass'})];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatnotif-row-vibrate')), findsOneWidget);
    expect(find.textContaining('Vibration follows'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
}
