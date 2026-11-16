import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/state/app_lock_state.dart';
import 'package:doqto_app/state/settings_state.dart';
import 'package:doqto_app/ui/widgets/app_lock_gate.dart';

/// The gate over the whole app: lock screen while locked, opaque cover while
/// in the task switcher, nothing in the way otherwise.
void main() {
  late FakeLocalAuthenticator auth;
  late ProviderContainer c;

  setUp(() {
    auth = FakeLocalAuthenticator(result: false);
    c = ProviderContainer(overrides: [
      localAuthenticatorProvider.overrideWithValue(auth),
    ]);
  });
  tearDown(() => c.dispose());

  Widget app() => UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: AppLockGate(child: Scaffold(body: Text('secret chat'))),
        ),
      );

  testWidgets('lock off: child only', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text('secret chat'), findsOneWidget);
    expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
    expect(find.byKey(const ValueKey('app-lock-cover')), findsNothing);
  });

  testWidgets('lock on: lock screen until Unlock succeeds', (tester) async {
    await c.read(appSettingsProvider.notifier).setAppLock(true);
    await tester.pumpWidget(app());
    await tester.pump(); // cold start prompts once (fails: result false)
    expect(find.byKey(const ValueKey('app-lock-screen')), findsOneWidget);
    expect(find.byKey(const ValueKey('app-lock-unlock')), findsOneWidget);
    expect(auth.prompts, hasLength(1));

    auth.result = true;
    await tester.tap(find.byKey(const ValueKey('app-lock-unlock')));
    await tester.pumpAndSettle();
    expect(auth.prompts, hasLength(2));
    expect(find.byKey(const ValueKey('app-lock-screen')), findsNothing);
    expect(find.text('secret chat'), findsOneWidget);
  });

  testWidgets('leaving the foreground shows the brand cover, returning hides it',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    c.read(appLockProvider.notifier).onLeftForeground();
    await tester.pump();
    expect(find.byKey(const ValueKey('app-lock-cover')), findsOneWidget);
    c.read(appLockProvider.notifier).onResumed();
    await tester.pump();
    expect(find.byKey(const ValueKey('app-lock-cover')), findsNothing);
  });
}
