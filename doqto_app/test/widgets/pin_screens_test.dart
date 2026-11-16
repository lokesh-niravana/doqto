import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/settings_repository.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/ui/screens/auth/pin_gate_screen.dart';
import 'package:doqto_app/ui/screens/settings/two_step_pin_screen.dart';

User _user({bool pinEnabled = false}) => User.fromJson({
      'id': 'me',
      'phone': '+16505550199',
      'full_name': 'Dr A',
      'npi_number': '1234567893',
      'role': 'doctor',
      'created_at': '2026-09-05T00:00:00Z',
      'pin_enabled': pinEnabled,
    });

class _SignedIn extends AuthNotifier {
  _SignedIn(this.pinEnabled);
  final bool pinEnabled;
  @override
  AuthState build() => AuthState(AuthStage.signedIn, _user(pinEnabled: pinEnabled));
}

class _Repo extends SettingsRepository {
  _Repo() : super(ApiClient());
  final List<(String, String?)> set = [];
  final List<String> disabled = [];
  bool reject = false;

  @override
  Future<void> setPin(String pin, {String? currentPin}) async {
    if (reject) throw ApiException('pin_invalid', status: 400);
    set.add((pin, currentPin));
  }

  @override
  Future<void> disablePin(String pin) async {
    if (reject) throw ApiException('pin_invalid', status: 400);
    disabled.add(pin);
  }
}

/// Gate: a stub notifier that records verify attempts and resolves the stage.
class _Gated extends AuthNotifier {
  final List<String> verified = [];
  bool wrong = false;
  int resets = 0;

  @override
  AuthState build() => const AuthState(AuthStage.pinRequired, null);

  @override
  Future<void> verifyPin(String pin) async {
    verified.add(pin);
    if (wrong) throw ApiException('pin_invalid', status: 400);
    state = AuthState(AuthStage.signedIn, _user());
  }

  @override
  Future<DateTime?> requestPinReset() async {
    resets++;
    final at = DateTime.utc(2026, 11, 15, 12);
    state = state.copyWith(pinClearsAt: at);
    return at;
  }
}

void main() {
  group('TwoStepPinScreen', () {
    late _Repo repo;
    setUp(() => repo = _Repo());

    Widget app({bool pinEnabled = false}) => ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(repo),
            authProvider.overrideWith(() => _SignedIn(pinEnabled)),
          ],
          child: const MaterialApp(home: TwoStepPinScreen()),
        );

    testWidgets('turn on: 6 digits dismiss the keypad; save sets the PIN', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pin-turn-on')));
      await tester.pumpAndSettle();

      final newPin = find.descendant(
          of: find.byKey(const ValueKey('pin-new')), matching: find.byType(TextField));
      await tester.tap(newPin);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.enterText(newPin, '12345');
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue, reason: 'short: keypad stays');
      await tester.enterText(newPin, '123456');
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse, reason: 'complete: keypad goes');

      final confirm = find.descendant(
          of: find.byKey(const ValueKey('pin-confirm')), matching: find.byType(TextField));
      await tester.enterText(confirm, '123456');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pin-save')));
      await tester.pumpAndSettle();

      expect(repo.set, [('123456', null)]);
      expect(find.text('Two-step verification is on.'), findsOneWidget);
      // The user flipped to pinEnabled: Change / Turn off now offered.
      expect(find.byKey(const ValueKey('pin-change')), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-off')), findsOneWidget);
    });

    testWidgets('mismatched PINs never reach the server', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pin-turn-on')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(of: find.byKey(const ValueKey('pin-new')), matching: find.byType(TextField)),
          '123456');
      await tester.enterText(
          find.descendant(of: find.byKey(const ValueKey('pin-confirm')), matching: find.byType(TextField)),
          '654321');
      await tester.tap(find.byKey(const ValueKey('pin-save')));
      await tester.pumpAndSettle();
      expect(repo.set, isEmpty);
      expect(find.text("The PINs don't match."), findsOneWidget);
    });

    testWidgets('change: current + new; turn off: current only', (tester) async {
      await tester.pumpWidget(app(pinEnabled: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pin-change')));
      await tester.pumpAndSettle();
      TextField fieldIn(String key) => tester.widget<TextField>(
          find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField)));
      await tester.enterText(find.byWidget(fieldIn('pin-current')), '111111');
      await tester.enterText(find.byWidget(fieldIn('pin-new')), '222222');
      await tester.enterText(find.byWidget(fieldIn('pin-confirm')), '222222');
      await tester.tap(find.byKey(const ValueKey('pin-save')));
      await tester.pumpAndSettle();
      expect(repo.set, [('222222', '111111')]);

      await tester.tap(find.byKey(const ValueKey('pin-off')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pin-new')), findsNothing);
      await tester.enterText(find.byWidget(fieldIn('pin-current')), '222222');
      await tester.tap(find.byKey(const ValueKey('pin-save')));
      await tester.pumpAndSettle();
      expect(repo.disabled, ['222222']);
      expect(find.byKey(const ValueKey('pin-turn-on')), findsOneWidget);
    });
  });

  group('PinGateScreen', () {
    late _Gated auth;
    setUp(() => auth = _Gated());

    Widget app() {
      final router = GoRouter(
        initialLocation: AppRoutes.pinGate,
        routes: [
          GoRoute(path: AppRoutes.pinGate, builder: (_, _) => const PinGateScreen()),
          GoRoute(
              path: AppRoutes.chats,
              builder: (_, _) => const Scaffold(body: Text('chats home'))),
        ],
      );
      return ProviderScope(
        overrides: [authProvider.overrideWith(() => auth)],
        child: MaterialApp.router(routerConfig: router),
      );
    }

    Finder input() => find.descendant(
        of: find.byKey(const ValueKey('pin-gate-input')), matching: find.byType(TextField));

    testWidgets('six digits verify and route by the resolved stage', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('Enter your PIN'), findsWidgets);
      await tester.enterText(input(), '123456');
      await tester.pumpAndSettle();
      expect(auth.verified, ['123456']);
      expect(find.text('chats home'), findsOneWidget);
    });

    testWidgets('a wrong PIN shows the mapped error and clears the field', (tester) async {
      auth.wrong = true;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.enterText(input(), '000000');
      await tester.pumpAndSettle();
      expect(auth.verified, ['000000']);
      expect(find.text('chats home'), findsNothing);
      expect(tester.widget<TextField>(input()).controller!.text, isEmpty);
      expect(find.textContaining('PIN'), findsWidgets);
    });

    testWidgets('Forgot PIN → confirm → 7-day message', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pin-gate-forgot')));
      await tester.pumpAndSettle();
      expect(auth.resets, 0, reason: 'a dialog first');
      await tester.tap(find.byKey(const ValueKey('pin-gate-forgot-confirm')));
      await tester.pumpAndSettle();
      expect(auth.resets, 1);
      expect(find.byKey(const ValueKey('pin-gate-pending')), findsOneWidget);
      expect(find.textContaining('Nov 15, 2026'), findsOneWidget);
      expect(find.textContaining('Enter it before then to cancel'), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-gate-forgot')), findsNothing);
    });

    testWidgets('Sign out is offered', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pin-gate-sign-out')), findsOneWidget);
    });
  });
}
