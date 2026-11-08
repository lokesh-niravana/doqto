import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/settings_repository.dart';
import 'package:doqto_app/data/services/auth_broker.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/ui/screens/settings/change_number_screen.dart';

User _user(String phone) => User.fromJson({
      'id': 'me',
      'phone': phone,
      'full_name': 'Dr A',
      'npi_number': '1234567893',
      'role': 'doctor',
      'created_at': '2026-09-05T00:00:00Z',
    });

class _SignedIn extends AuthNotifier {
  @override
  AuthState build() => AuthState(AuthStage.signedIn, _user('+16505550199'));
}

class _Repo extends SettingsRepository {
  _Repo() : super(ApiClient());
  final List<String> tokens = [];
  bool inUse = false;

  @override
  Future<User> changePhone(String idToken) async {
    tokens.add(idToken);
    if (inUse) throw ApiException('phone_in_use', status: 409);
    return _user('+16505550123');
  }
}

void main() {
  late _Repo repo;
  late FakeAuthBroker broker;

  setUp(() {
    repo = _Repo();
    broker = FakeAuthBroker(idToken: 'linked-token');
  });

  late ProviderContainer container;

  Widget app() {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                key: const ValueKey('go'),
                onPressed: () => ctx.push('/change'),
                child: const Text('settings home'),
              ),
            ),
          ),
        ),
        GoRoute(path: '/change', builder: (_, _) => const ChangeNumberScreen()),
      ],
    );
    container = ProviderContainer(overrides: [
      settingsRepositoryProvider.overrideWithValue(repo),
      authBrokerProvider.overrideWithValue(broker),
      authProvider.overrideWith(_SignedIn.new),
    ]);
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pumpAndSettle();
  }

  Finder phoneInput() => find.descendant(
      of: find.byKey(const ValueKey('change-number-phone')), matching: find.byType(TextField));
  Finder codeInput() => find.descendant(
      of: find.byKey(const ValueKey('change-number-code')), matching: find.byType(TextField));

  testWidgets('send code → verify → changePhone → user updated → pop + toast', (tester) async {
    await open(tester);
    expect(find.textContaining('+16505550199'), findsOneWidget, reason: 'current number shown');

    await tester.enterText(phoneInput(), '6505550123');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('change-number-send')));
    await tester.pumpAndSettle();
    expect(broker.startedFor, ['+16505550123']);
    expect(find.byKey(const ValueKey('change-number-code')), findsOneWidget);

    await tester.enterText(codeInput(), '123456');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse, reason: '6 digits dismiss the keypad');
    await tester.tap(find.byKey(const ValueKey('change-number-verify')));
    await tester.pumpAndSettle();

    expect(repo.tokens, ['linked-token']);
    expect(container.read(authProvider).user!.phone, '+16505550123');
    expect(find.text('settings home'), findsOneWidget, reason: 'popped back');
    expect(find.text('Your number is now +16505550123'), findsOneWidget);
  });

  testWidgets('a refused swap shows the error and does NOT unlink the phone', (tester) async {
    repo.inUse = true;
    await open(tester);
    await tester.enterText(phoneInput(), '6505550123');
    await tester.tap(find.byKey(const ValueKey('change-number-send')));
    await tester.pumpAndSettle();
    await tester.enterText(codeInput(), '123456');
    await tester.tap(find.byKey(const ValueKey('change-number-verify')));
    await tester.pumpAndSettle();

    expect(repo.tokens, ['linked-token']);
    expect(broker.unlinked, 0);
    expect(find.byKey(const ValueKey('change-number-code')), findsOneWidget, reason: 'stays put');
    expect(container.read(authProvider).user!.phone, '+16505550199');
    expect(find.text('settings home'), findsNothing);
  });

  testWidgets('an invalid number never starts verification', (tester) async {
    await open(tester);
    await tester.enterText(phoneInput(), '12');
    await tester.tap(find.byKey(const ValueKey('change-number-send')));
    await tester.pumpAndSettle();
    expect(broker.startedFor, isEmpty);
    expect(find.byKey(const ValueKey('change-number-code')), findsNothing);
  });
}
