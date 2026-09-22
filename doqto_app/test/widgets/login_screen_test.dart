import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/ui/screens/auth/login_screen.dart';
import 'package:doqto_app/ui/widgets/phone_field.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/services/auth_broker.dart';
import 'package:doqto_app/ui/widgets/inline_error.dart';
import 'package:doqto_app/ui/widgets/social_button.dart';

// The login screen offers phone plus the Firebase providers (Google, Apple,
// Facebook once the Meta app exists). No tabs, no email + password.
class _Auth extends AuthRepository {
  _Auth() : super(ApiClient(), TokenStorage());
  final List<String> exchanged = [];

  @override
  Future<TokenPair> signInWithFirebase(String idToken) async {
    exchanged.add(idToken);
    return TokenPair('access', 'refresh', false);
  }

  @override
  Future<User> me() async => User.fromJson({
    'id': 'u1',
    'phone': '+15555550100',
    'full_name': '',
    'npi_number': 'PENDING01',
    'role': 'doctor',
    'created_at': DateTime.now().toIso8601String(),
  });
}

void main() {
  Future<void> pump(
    WidgetTester tester, {
    AuthRepository? auth,
    AuthBroker? broker,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (auth != null) authRepositoryProvider.overrideWithValue(auth),
        if (broker != null) authBrokerProvider.overrideWithValue(broker),
      ],
      child: const MaterialApp(home: LoginScreen()),
    ),
  );

  // The screen scrolls; error text can push a button below the test viewport.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('phone and the sign-in providers are the only ways in', (tester) async {
    await pump(tester);

    expect(find.byType(PhoneField), findsOneWidget);

    // No separate sign-up: the number decides — known means sign in, new
    // means sign up.
    expect(find.text('Create an account'), findsNothing);
    expect(find.text('New to Doqto?'), findsNothing);
    expect(find.text(Strings.authSendOtp), findsWidgets);

    expect(
      find.byType(SocialButton),
      findsNWidgets(kFacebookSignInEnabled ? 3 : 2),
    );
    expect(find.text(Strings.loginGoogle), findsOneWidget);
    expect(
      find.text(Strings.loginFacebook),
      kFacebookSignInEnabled ? findsOneWidget : findsNothing,
    );

    // Phone and the providers are the only ways in: no tabs, no password.
    expect(find.text('Username / Email'), findsNothing);
    expect(find.text('Password'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.pumpAndSettle(); // let the entrance animations finish
  });

  testWidgets('tapping a provider signs in through the broker', (tester) async {
    final auth = _Auth();
    final broker = FakeAuthBroker(idToken: 'google-tok');
    await pump(tester, auth: auth, broker: broker);

    await tap(tester, find.text(Strings.loginGoogle));

    // It reaches the backend rather than apologising.
    expect(auth.exchanged, ['google-tok']);
  });

  testWidgets('dismissing the provider sheet leaves the screen alone', (
    tester,
  ) async {
    final auth = _Auth();
    // A null token is Firebase reporting a cancelled sheet.
    await pump(tester, auth: auth, broker: FakeAuthBroker(idToken: null));

    await tap(tester, find.text(Strings.loginGoogle));

    expect(auth.exchanged, isEmpty);
    // No error banner: cancelling is a normal thing to do.
    expect(find.byType(InlineError), findsOneWidget);
  });

  testWidgets('Apple is offered alongside Google', (tester) async {
    // App Store guideline 4.8 requires it wherever a social login is offered.
    await pump(tester);
    await tester.pumpAndSettle();

    expect(find.text(Strings.loginApple), findsOneWidget);
    expect(
      find.byType(SocialButton),
      findsNWidgets(kFacebookSignInEnabled ? 3 : 2),
    );
  });
}
