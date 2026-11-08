import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/notification_settings.dart';
import 'package:doqto_app/data/repositories/settings_repository.dart';
import 'package:doqto_app/state/notification_settings_state.dart';

import 'support/fake_socket.dart';

/// Notification settings (batch 6): model round-trip, tone catalogue, and the
/// optimistic PATCH with rollback.
class _Repo extends SettingsRepository {
  _Repo() : super(ApiClient());
  NotificationSettings server = const NotificationSettings(
    messagesTone: 'chime',
    messagesShowPreview: false,
    groupsVibrate: VibratePattern.short,
    haptics: false,
  );
  final patches = <Map<String, dynamic>>[];
  bool fail = false;
  int resets = 0;

  @override
  Future<NotificationSettings> getNotifications() async => server;

  @override
  Future<NotificationSettings> patchNotifications(
    Map<String, dynamic> patch,
  ) async {
    patches.add(patch);
    if (fail) throw Exception('boom');
    server = NotificationSettings.fromJson({...server.toJson(), ...patch});
    return server;
  }

  @override
  Future<NotificationSettings> resetNotifications() async {
    resets++;
    server = NotificationSettings.defaults;
    return server;
  }
}

void main() {
  group('NotificationSettings model', () {
    test('round-trips through json', () {
      const s = NotificationSettings(
        messagesTone: 'bell',
        messagesVibrate: VibratePattern.long,
        messagesShowPreview: false,
        messagesHighPriority: false,
        groupsTone: 'none',
        groupsVibrate: VibratePattern.off,
        groupsShowPreview: true,
        groupsHighPriority: false,
        reactionNotifications: false,
        conversationTones: false,
        haptics: true,
      );
      final back = NotificationSettings.fromJson(s.toJson());
      expect(back, s);
      expect(s.toJson()['messages_vibrate'], 'long');
      expect(s.toJson()['groups_vibrate'], 'off');
    });

    test('defaults match the server defaults', () {
      final d = NotificationSettings.fromJson(const {});
      expect(d, NotificationSettings.defaults);
      expect(d.messagesTone, 'default');
      expect(d.messagesShowPreview, isTrue);
      expect(d.haptics, isTrue);
    });

    test('NotificationTones catalogue', () {
      expect(NotificationTones.all.first, 'default');
      expect(NotificationTones.all.last, 'none');
      expect(NotificationTones.all.length, NotificationTones.bundled.length + 2);
      expect(NotificationTones.isValid('chime'), isTrue);
      expect(NotificationTones.isValid('default'), isTrue);
      expect(NotificationTones.isValid('none'), isTrue);
      expect(NotificationTones.isValid('airhorn'), isFalse);
      expect(NotificationTones.isValid(null), isFalse);
      expect(NotificationTones.assetFor('pop'), 'assets/tones/pop.wav');
      expect(NotificationTones.assetFor('default'), isNull);
      expect(NotificationTones.assetFor('none'), isNull);
      expect(NotificationTones.label('chime'), 'Chime');
      expect(NotificationTones.label('default'), 'Default');
      expect(NotificationTones.label('none'), 'None');
    });
  });

  group('notificationSettingsProvider', () {
    late _Repo repo;
    late FakeSocket socket;
    late ProviderContainer container;

    setUp(() {
      repo = _Repo();
      socket = FakeSocket();
      container = ProviderContainer(overrides: [
        settingsRepositoryProvider.overrideWithValue(repo),
        websocketClientProvider.overrideWithValue(socket),
      ]);
      addTearDown(container.dispose);
    });

    test('loads from the repository', () async {
      final s = await container.read(notificationSettingsProvider.future);
      expect(s.messagesTone, 'chime');
      expect(s.messagesShowPreview, isFalse);
      expect(s.groupsVibrate, VibratePattern.short);
    });

    test('change is optimistic and sends a one-field PATCH', () async {
      await container.read(notificationSettingsProvider.future);
      final f = container.read(notificationSettingsProvider.notifier).change(
            apply: (s) => s.copyWith(haptics: true),
            patch: {'haptics': true},
          );
      // Flipped before the server answers.
      expect(container.read(notificationSettingsProvider).value!.haptics, isTrue);
      await f;
      expect(repo.patches, [
        {'haptics': true}
      ]);
      expect(container.read(notificationSettingsProvider).value!.haptics, isTrue);
    });

    test('change rolls back and rethrows when the PATCH fails', () async {
      await container.read(notificationSettingsProvider.future);
      repo.fail = true;
      await expectLater(
        container.read(notificationSettingsProvider.notifier).change(
              apply: (s) => s.copyWith(messagesTone: 'bell'),
              patch: {'messages_tone': 'bell'},
            ),
        throwsException,
      );
      expect(
        container.read(notificationSettingsProvider).value!.messagesTone,
        'chime',
      );
    });

    test('reset replaces the state with the server defaults', () async {
      await container.read(notificationSettingsProvider.future);
      await container.read(notificationSettingsProvider.notifier).reset();
      expect(repo.resets, 1);
      expect(
        container.read(notificationSettingsProvider).value,
        NotificationSettings.defaults,
      );
    });

    test('WS notification_settings_updated replaces the state', () async {
      await container.read(notificationSettingsProvider.future);
      socket.emit(WsEventServer.notificationSettingsUpdated, {
        ...NotificationSettings.defaults.toJson(),
        'groups_tone': 'glass',
        'conversation_tones': false,
      });
      await Future<void>.delayed(Duration.zero);
      final s = container.read(notificationSettingsProvider).value!;
      expect(s.groupsTone, 'glass');
      expect(s.conversationTones, isFalse);
    });
  });
}
