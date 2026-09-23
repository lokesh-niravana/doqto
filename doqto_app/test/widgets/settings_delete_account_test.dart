import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/billing.dart';
import 'package:doqto_app/data/repositories/billing_repository.dart';
import 'package:doqto_app/data/repositories/user_repository.dart';
import 'package:doqto_app/ui/screens/settings/settings_screen.dart';

/// App Store 5.1.1(v): deletion must be reachable in-app, and it is
/// irreversible — so the guard matters as much as the call itself.
class _SpyUserRepo implements UserRepository {
  int deleteCalls = 0;

  @override
  Future<void> deleteAccount() async => deleteCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not stubbed');
}

/// Settings shows the subscription row; keep it off the network.
class _Billing extends BillingRepository {
  _Billing() : super(ApiClient());
  @override
  Future<Billing> status() async => const Billing(
        entitled: true,
        reason: 'trial',
        monthlyCents: 899,
        yearlyCents: 8000,
      );
}

late _SpyUserRepo _repo;

Widget _app() => ProviderScope(
      overrides: [
        userRepositoryProvider.overrideWithValue(_repo),
        billingRepositoryProvider.overrideWithValue(_Billing()),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    );

void main() {
  setUp(() => _repo = _SpyUserRepo());

  testWidgets('Delete account is reachable from Settings', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('Delete account'), findsOneWidget);
  });

  testWidgets('confirm stays disabled until DELETE is typed exactly',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    final confirm = find.widgetWithText(TextButton, 'Delete');
    expect(tester.widget<TextButton>(confirm).onPressed, isNull,
        reason: 'must not be armed before the word is typed');

    await tester.enterText(find.byType(TextField), 'delete');
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(confirm).onPressed, isNull,
        reason: 'lowercase must not arm it');

    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(confirm).onPressed, isNotNull);
  });

  testWidgets('cancelling never calls the API', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(_repo.deleteCalls, 0);
  });
}
