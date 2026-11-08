
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/chat_repository.dart';
import 'package:doqto_app/data/repositories/network_repository.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/data/services/notification_service.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/state/notification_state.dart';

import 'support/fake_socket.dart';

/// Batch 3: the in-app message banner honours a muted chat and a muted person.
class _Notifications extends NotificationService {
  final shown = <String>[];
  @override
  Future<void> init({required void Function(String payload) onTap}) async {}
  @override
  Future<void> showMessage({
    required String conversationId,
    required String title,
    required String body,
    String channelId = 'messages',
    bool showPreview = true,
  }) async =>
      shown.add(conversationId);
}

Conversation _conv(String id, {Map<String, dynamic>? prefs}) => Conversation.fromJson({
      'id': id,
      'type': 'direct',
      'display_name': 'Peer $id',
      'member_ids': ['me', 'them'],
      'created_at': '2026-11-01T00:00:00Z',
      'updated_at': '2026-11-08T10:00:00Z',
      'prefs': ?prefs,
    });

class _Chat extends ChatRepository {
  _Chat() : super(ApiClient());
  List<Conversation> convs = [];
  @override
  Future<List<Conversation>> listConversations() async => List.of(convs);
  @override
  Future<void> markConversationDelivered(String conversationId) async {}
}

class _Net extends NetworkRepository {
  _Net() : super(ApiClient());
  List<String> mutes = [];
  @override
  Future<List<String>> listMutes() async => mutes;
  @override
  Future<void> mute(String userId) async => mutes.add(userId);
  @override
  Future<void> unmute(String userId) async => mutes.remove(userId);
}

class _NoCache extends ChatCache {
  @override
  List<Conversation>? conversations() => null;
  @override
  Future<void> putConversations(List<Conversation> list) async {}
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

void main() {
  // The listener reads WidgetsBinding.instance.lifecycleState.
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Notifications notifications;
  late FakeSocket socket;
  late _Chat chat;
  late _Net net;
  late ProviderContainer c;

  setUp(() async {
    notifications = _Notifications();
    socket = FakeSocket();
    chat = _Chat()
      ..convs = [
        _conv('open'),
        _conv('muted', prefs: {'muted_until': '9999-12-31T00:00:00Z'}),
        _conv('lapsed', prefs: {'muted_until': '2020-01-01T00:00:00Z'}),
      ];
    net = _Net();
    c = ProviderContainer(overrides: [
      notificationServiceProvider.overrideWithValue(notifications),
      websocketClientProvider.overrideWithValue(socket),
      chatRepositoryProvider.overrideWithValue(chat),
      networkRepositoryProvider.overrideWithValue(net),
      chatCacheProvider.overrideWithValue(_NoCache()),
      authProvider.overrideWith(_Auth.new),
    ]);
    c.read(notificationListenerProvider);
    await c.read(conversationsProvider.future);
    await c.read(mutedUsersProvider.future);
  });
  tearDown(() => c.dispose());

  void incoming(String conv, {String sender = 'them'}) => socket.emit(
        WsEventServer.newMessage,
        {'conversation_id': conv, 'sender_id': sender, 'type': 'text', 'content': 'hi'},
      );

  test('a muted chat shows no banner; a lapsed mute does', () async {
    incoming('muted');
    incoming('lapsed');
    incoming('open');
    await settle();
    expect(notifications.shown, ['lapsed', 'open']);
  });

  test('a muted person shows no banner in any chat', () async {
    await c.read(mutedUsersProvider.notifier).setMuted('them', true);
    expect(net.mutes, ['them']);
    incoming('open');
    await settle();
    expect(notifications.shown, isEmpty);
    await c.read(mutedUsersProvider.notifier).setMuted('them', false);
    incoming('open');
    await settle();
    expect(notifications.shown, ['open']);
  });
}
