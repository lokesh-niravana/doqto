import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/notification_settings.dart';
import 'package:doqto_app/data/repositories/settings_repository.dart';
import 'package:doqto_app/ui/screens/settings/notifications_screen.dart';

import '../support/fake_socket.dart';

/// Settings → Notifications (batch 6): rows render the server values, a
/// switch sends a one-field PATCH, reset confirms then resets, and iOS hides
/// the Android-only priority row.
class _Repo extends SettingsRepository {
  _Repo() : super(ApiClient());
  NotificationSettings server = const NotificationSettings(
    messagesTone: 'chime',
    messagesShowPreview: false,
    groupsTone: 'bell',
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

// ignore: library_private_types_in_public_api
late _Repo repo;

Widget app() => ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(repo),
        websocketClientProvider.overrideWithValue(FakeSocket()),
      ],
      child: const MaterialApp(home: NotificationsScreen()),
    );

Future<void> pumpScreen(WidgetTester tester) async {
  // Tall enough that every section (and the reset button) is built.
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app());
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    repo = _Repo();
  });

  testWidgets('rows render the server values', (tester) async {
    await pumpScreen(tester);

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('notif-value-messages_tone'))).data,
      'Chime',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('notif-value-groups_tone'))).data,
      'Bell',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('notif-value-groups_vibrate'))).data,
      'Short',
    );
    expect(
      tester
          .widget<SwitchListTile>(
              find.byKey(const ValueKey('notif-switch-messages_show_preview')))
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<SwitchListTile>(
              find.byKey(const ValueKey('notif-switch-messages_high_priority')))
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('notif-switch-haptics')))
          .value,
      isFalse,
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('flipping a switch sends a one-field PATCH', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('notif-switch-messages_show_preview')));
    await tester.pumpAndSettle();
    expect(repo.patches, [
      {'messages_show_preview': true}
    ]);
    expect(
      tester
          .widget<SwitchListTile>(
              find.byKey(const ValueKey('notif-switch-messages_show_preview')))
          .value,
      isTrue,
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('vibrate choice sheet PATCHes the wire value', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('notif-row-messages_vibrate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notif-opt-messages_vibrate-long')));
    await tester.pumpAndSettle();
    expect(repo.patches, [
      {'messages_vibrate': 'long'}
    ]);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('notif-value-messages_vibrate'))).data,
      'Long',
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('a failed save rolls the switch back and toasts', (tester) async {
    repo.fail = true;
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('notif-switch-messages_show_preview')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
              find.byKey(const ValueKey('notif-switch-messages_show_preview')))
          .value,
      isFalse,
    );
    expect(find.byType(SnackBar), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('reset asks first, then resets', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('notif-reset')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(repo.resets, 0);
    await tester.tap(find.byKey(const ValueKey('notif-reset-confirm')));
    await tester.pumpAndSettle();
    expect(repo.resets, 1);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('notif-value-messages_tone'))).data,
      'Default',
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('iOS hides high priority and disables vibrate', (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('notif-switch-messages_high_priority')),
        findsNothing);
    expect(find.byKey(const ValueKey('notif-switch-groups_high_priority')),
        findsNothing);
    final vib = tester.widget<ListTile>(
        find.byKey(const ValueKey('notif-row-messages_vibrate')));
    expect(vib.enabled, isFalse);
    expect(find.textContaining('Vibration follows'), findsWidgets);
    // Previews stay editable on iOS.
    expect(find.byKey(const ValueKey('notif-switch-messages_show_preview')),
        findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
}
