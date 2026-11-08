import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/settings_repository.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/ui/screens/profile/status_screen.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

/// Status under the name (batch 6): presets and custom text are exclusive,
/// the expiry sheet maps to seconds, Save sends one PATCH and lands the
/// result on the cached user, Clear sends `{}`, failures toast and stay.
class _Repo extends SettingsRepository {
  _Repo() : super(ApiClient());
  final calls = <({StatusPreset? preset, String? text, int? expiresInSec})>[];
  bool fail = false;

  @override
  Future<({StatusPreset? preset, String? text, DateTime? expiresAt})> setStatus({
    StatusPreset? preset,
    String? text,
    int? expiresInSec,
  }) async {
    calls.add((preset: preset, text: text, expiresInSec: expiresInSec));
    if (fail) throw Exception('nope');
    return (
      preset: preset,
      text: text,
      expiresAt: expiresInSec == null
          ? null
          : DateTime.utc(2026, 11, 8, 12).add(Duration(seconds: expiresInSec)),
    );
  }
}

User _user({String? preset, String? text}) => User.fromJson({
      'id': 'me',
      'phone': '+15550000101',
      'full_name': 'Dr A',
      'npi_number': '1234567893',
      'role': 'doctor',
      'created_at': '2026-09-05T00:00:00Z',
      'status_preset': ?preset,
      'status_text': ?text,
    });

class _Auth extends AuthNotifier {
  final User initial;
  _Auth(this.initial);
  @override
  AuthState build() => AuthState(AuthStage.signedIn, initial);
}

late _Repo _repo;

Widget _app(User user) => ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(_repo),
        authProvider.overrideWith(() => _Auth(user)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('go'),
                onPressed: () => Navigator.of(ctx)
                    .push(MaterialPageRoute<void>(builder: (_) => const StatusScreen())),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );

Future<ProviderContainer> _open(WidgetTester tester, {User? user}) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(user ?? _user()));
  final container = ProviderScope.containerOf(tester.element(find.byKey(const ValueKey('go'))));
  await tester.tap(find.byKey(const ValueKey('go')));
  await tester.pumpAndSettle();
  return container;
}

Finder _save() => find.byKey(const ValueKey('status-save'));

/// The surface is tall enough for the whole form; this only guards against
/// a tile sitting under the keyboard inset.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await _reveal(tester, f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}
bool _saveEnabled(WidgetTester tester) => tester.widget<AppButton>(_save()).onPressed != null;

void main() {
  setUp(() => _repo = _Repo());

  testWidgets('lists every preset, custom field, expiry row; Save disabled when empty',
      (tester) async {
    await _open(tester);
    for (final p in StatusPreset.values) {
      expect(find.byKey(ValueKey('status-preset-${p.wire}')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('status-custom')), findsOneWidget);
    await _reveal(tester, find.byKey(const ValueKey('status-expiry-never')));
    for (final k in ['3600', '28800', '86400', 'never']) {
      expect(find.byKey(ValueKey('status-expiry-$k')), findsOneWidget);
    }
    await _reveal(tester, _save());
    expect(_saveEnabled(tester), isFalse);
    expect(find.byKey(const ValueKey('status-clear')), findsNothing,
        reason: 'nothing to clear yet');
  });

  testWidgets('preset + 8h → one PATCH, user updated, screen pops', (tester) async {
    final container = await _open(tester);
    await _tap(tester, find.byKey(const ValueKey('status-preset-in_surgery')));
    await _tap(tester, find.byKey(const ValueKey('status-expiry-28800')));
    await _reveal(tester, _save());
    expect(_saveEnabled(tester), isTrue);
    await _tap(tester, _save());
    expect(_repo.calls, [
      (preset: StatusPreset.inSurgery, text: null, expiresInSec: 28800),
    ]);
    final u = container.read(authProvider).user!;
    expect(u.statusPreset, StatusPreset.inSurgery);
    expect(u.statusText, isNull);
    expect(u.statusExpiresAt, DateTime.utc(2026, 11, 8, 20));
    expect(find.byKey(const ValueKey('status-list')), findsNothing, reason: 'popped');
  });

  testWidgets('custom text clears the preset and is sent trimmed', (tester) async {
    final container = await _open(tester);
    await tester.tap(find.byKey(const ValueKey('status-preset-on_call')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byKey(const ValueKey('status-custom')), matching: find.byType(TextField)),
        '  Back at 4  ');
    await tester.pumpAndSettle();
    // Typing custom text deselects the preset.
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('status-preset-on_call')),
          matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    await _tap(tester, _save());
    expect(_repo.calls.single, (preset: null, text: 'Back at 4', expiresInSec: null));
    expect(container.read(authProvider).user!.statusText, 'Back at 4');
  });

  testWidgets('picking a preset clears typed custom text', (tester) async {
    await _open(tester);
    await tester.enterText(
        find.descendant(
            of: find.byKey(const ValueKey('status-custom')), matching: find.byType(TextField)),
        'Rounds');
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const ValueKey('status-preset-off_duty')));
    expect(find.text('Rounds'), findsNothing);
    await _tap(tester, _save());
    expect(_repo.calls.single.preset, StatusPreset.offDuty);
    expect(_repo.calls.single.text, isNull);
  });

  testWidgets('custom field caps at 40 characters', (tester) async {
    await _open(tester);
    final field = find.descendant(
        of: find.byKey(const ValueKey('status-custom')), matching: find.byType(TextField));
    await tester.enterText(field, 'x' * 60);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text.length, 40);
  });

  testWidgets('expiry chips: Never by default, picking 1h sends 3600', (tester) async {
    await _open(tester);
    await _reveal(tester, find.byKey(const ValueKey('status-expiry-never')));
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('status-expiry-never'))).selected,
        isTrue);
    await _tap(tester, find.byKey(const ValueKey('status-expiry-3600')));
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('status-expiry-3600'))).selected,
        isTrue);
    await _tap(tester, find.byKey(const ValueKey('status-preset-available')));
    await _tap(tester, _save());
    expect(_repo.calls.single.expiresInSec, 3600);
  });

  testWidgets('existing status: preset preselected, Clear sends {} and clears the user',
      (tester) async {
    final container = await _open(tester, user: _user(preset: 'in_clinic'));
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('status-preset-in_clinic')),
          matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    await _reveal(tester, find.byKey(const ValueKey('status-clear')));
    await _tap(tester, find.byKey(const ValueKey('status-clear')));
    expect(_repo.calls.single, (preset: null, text: null, expiresInSec: null));
    final u = container.read(authProvider).user!;
    expect(u.statusPreset, isNull);
    expect(u.statusText, isNull);
    expect(u.statusLabel(), isNull);
  });

  testWidgets('server failure toasts and keeps the screen and the old user', (tester) async {
    _repo.fail = true;
    final container = await _open(tester, user: _user(text: 'Old'));
    await _tap(tester, find.byKey(const ValueKey('status-preset-available')));
    await _tap(tester, _save());
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byKey(const ValueKey('status-list')), findsOneWidget);
    expect(container.read(authProvider).user!.statusText, 'Old');
  });

  testWidgets('tapping outside the custom field dismisses the keyboard', (tester) async {
    await _open(tester);
    final field = find.descendant(
        of: find.byKey(const ValueKey('status-custom')), matching: find.byType(TextField));
    await _tap(tester, field);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.byKey(const ValueKey('status-expiry-never')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });
}
