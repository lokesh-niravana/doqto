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

// The login screen offers four ways in. Phone OTP is the only one wired to the
// backend; the rest must still be visible and must say so when tapped.
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

  testWidgets('all four sign-in methods are on screen', (tester) async {
    await pump(tester);

    // Phone is the default tab.
    expect(find.byType(PhoneField), findsOneWidget);

    // No separate sign-up: the number decides — known means sign in, new
    // means sign up.
    expect(find.text('Create an account'), findsNothing);
    expect(find.text('New to Doqto?'), findsNothing);
    expect(find.text(Strings.authSendOtp), findsWidgets);

    // All three providers are offered regardless of the selected tab.
    expect(
      find.byType(SocialButton),
      findsNWidgets(kFacebookSignInEnabled ? 3 : 2),
    );
    expect(find.text(Strings.loginGoogle), findsOneWidget);
    expect(
      find.text(Strings.loginFacebook),
      kFacebookSignInEnabled ? findsOneWidget : findsNothing,
    );

    // Switching to Email swaps the form, not the rest of the screen.
    await tap(tester, find.text(Strings.loginTabEmail));

    expect(find.byType(PhoneField), findsNothing);
    // The tab and the field share a label, so match the field by its hint.
    expect(find.text(Strings.loginIdentifierHint), findsOneWidget);
    expect(find.text(Strings.loginPassword), findsOneWidget);
    expect(find.text(Strings.loginForgotPassword), findsOneWidget);
    expect(find.text(Strings.loginSignIn), findsWidgets);
    expect(
      find.byType(SocialButton),
      findsNWidgets(kFacebookSignInEnabled ? 3 : 2),
    );
  });

  testWidgets('password sign-in takes a username or an email', (tester) async {
    await pump(tester);
    await tap(tester, find.text(Strings.loginTabEmail));

    final fields = find.byType(TextField);

    // An @ means they meant an email, so they get the email error.
    await tester.enterText(fields.at(0), 'not-an-email@');
    await tester.enterText(fields.at(1), 'hunter2hunter2');
    await tap(tester, find.text(Strings.loginSignIn).first);

    expect(
      find.text('That doesn\'t look like an email address.'),
      findsOneWidget,
    );
    expect(find.text(Strings.loginComingSoon), findsNothing);

    // No @ means a username, judged by username rules.
    await tester.enterText(fields.at(0), 'dr alex');
    await tap(tester, find.text(Strings.loginSignIn).first);

    expect(
      find.text('Usernames use letters, digits, dot, dash or underscore.'),
      findsOneWidget,
    );
    expect(find.text(Strings.loginComingSoon), findsNothing);

    // Short password — same deal.
    await tester.enterText(fields.at(0), 'dr.alex');
    await tester.enterText(fields.at(1), 'short');
    await tap(tester, find.text(Strings.loginSignIn).first);

    expect(find.text('Passwords are at least 8 characters.'), findsOneWidget);
    expect(find.text(Strings.loginComingSoon), findsNothing);

    // A plain username with a long enough password gets through validation;
    // the screen then admits the endpoint isn't live yet.
    await tester.enterText(fields.at(1), 'hunter2hunter2');
    await tap(tester, find.text(Strings.loginSignIn).first);

    expect(find.text(Strings.loginComingSoon), findsOneWidget);

    // So does an email address in the same field.
    await tester.enterText(fields.at(0), 'doc@hospital.org');
    await tap(tester, find.text(Strings.loginSignIn).first);

    expect(find.text(Strings.loginComingSoon), findsOneWidget);
  });

  testWidgets('tapping a provider signs in through the broker', (tester) async {
    final auth = _Auth();
    final broker = FakeAuthBroker(idToken: 'google-tok');
    await pump(tester, auth: auth, broker: broker);

    await tap(tester, find.text(Strings.loginGoogle));

    // It reaches the backend rather than apologising.
    expect(auth.exchanged, ['google-tok']);
    expect(find.text(Strings.loginComingSoon), findsNothing);
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
    expect(find.text(Strings.loginComingSoon), findsNothing);
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
