import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/ui/screens/settings/linked_devices_screen.dart';

import '../sessions_state_test.dart' show FakeSettingsRepo, session;
import '../support/fake_socket.dart';

void main() {
  late FakeSettingsRepo repo;

  setUp(() => repo = FakeSettingsRepo());

  Widget app() => ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repo),
          websocketClientProvider.overrideWithValue(FakeSocket()),
        ],
        child: const MaterialApp(home: LinkedDevicesScreen()),
      );

  testWidgets('this device on top, others below with a Sign out each', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('THIS DEVICE'), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-row-me')), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-revoke-me')), findsNothing,
        reason: 'no sign-out on the device you are holding');
    expect(find.byKey(const ValueKey('devices-revoke-s2')), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-revoke-s3')), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-revoke-others')), findsOneWidget);
  });

  testWidgets('Sign out confirms, then removes the row', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('devices-revoke-s2')));
    await tester.pumpAndSettle();
    expect(find.text('Sign out of Device s2?'), findsOneWidget);
    expect(repo.revoked, isEmpty, reason: 'nothing until confirmed');

    await tester.tap(find.byKey(const ValueKey('devices-confirm')));
    await tester.pumpAndSettle();
    expect(repo.revoked, ['s2']);
    expect(find.byKey(const ValueKey('devices-row-s2')), findsNothing);
    expect(find.byKey(const ValueKey('devices-row-s3')), findsOneWidget);
  });

  testWidgets('Sign out of all other devices → count toast, empty state', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('devices-revoke-others')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('devices-confirm')));
    await tester.pumpAndSettle();
    expect(repo.revokeOthersCalls, 1);
    expect(find.text('Signed out of 2 devices'), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-revoke-others')), findsNothing);
  });

  testWidgets('only this device: empty state, no bulk button', (tester) async {
    repo.sessions = [session('me', current: true)];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('devices-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('devices-revoke-others')), findsNothing);
  });
}
