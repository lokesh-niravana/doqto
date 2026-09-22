import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/repositories/user_repository.dart';
import 'package:doqto_app/data/services/auth_broker.dart';
import 'package:doqto_app/data/services/npi_lookup.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/ui/screens/auth/registration_screen.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

// Your details, after the sign-up rework:
//  * required fields carry a `*`, the optional phone does not, no helper texts
//  * specialty is required
//  * people who signed up without a phone (social) may add one — optional, but
//    a typed number must be verified by OTP before Continue accepts it
//  * nobody reaches this screen without a verified session

User _user({String phone = '+15555550100', String? email}) => User.fromJson({
      'id': 'u1',
      'phone': phone,
      'email': email,
      'full_name': '',
      'npi_number': 'PENDING',
      'role': 'doctor',
      'created_at': DateTime.now().toIso8601String(),
    });

const _goodCode = '123456';
const _number = '2015550123'; // libphonenumber's own US example — always valid

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : super(ApiClient(), TokenStorage());
  final List<String> registered = [];

  @override
  Future<void> logout() async {}

  @override
  Future<User> register({
    required String fullName,
    required String? specialty,
    required String npiNumber,
  }) async {
    registered.add('$fullName|$specialty|$npiNumber');
    return _user();
  }
}

class _FakeUserRepository extends UserRepository {
  _FakeUserRepository() : super(ApiClient());
  final List<String> verified = [];

  @override
  Future<User> linkPhone(String idToken) async {
    // The broker only mints a token once Firebase accepted the code, so
    // reaching here at all means the number is proved.
    verified.add(idToken);
    return _user(phone: idToken.replaceFirst('token-for-', ''));
  }
}

/// Firebase sends the SMS and checks the code. A wrong code never produces a
/// token, so the backend is never called — the same shape as production.
class _PhoneBroker extends FakeAuthBroker {
  final List<String> codesSentTo = [];

  @override
  Future<PhoneChallenge> startPhoneSignIn(String phone) async {
    codesSentTo.add(phone);
    return PhoneChallenge('vid', phone);
  }

  @override
  Future<String> linkPhone(PhoneChallenge challenge, String code) async {
    if (code != _goodCode) {
      throw ApiException('That code is not right.', status: 400);
    }
    return 'token-for-${challenge.phone}';
  }
}

void main() {
  late _FakeAuthRepository auth;
  late _FakeUserRepository users;
  late _PhoneBroker broker;

  setUp(() {
    auth = _FakeAuthRepository();
    users = _FakeUserRepository();
    broker = _PhoneBroker();
  });

  /// [phone] is the phone on the signed-in account: set for phone sign-up,
  /// empty for social sign-up.
  Future<void> pump(WidgetTester tester,
      {String phone = '+15555550100', String? email}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(overrides: [
      authRepositoryProvider.overrideWithValue(auth),
      userRepositoryProvider.overrideWithValue(users),
      npiLookupProvider.overrideWithValue(_NoLookup()),
      authBrokerProvider.overrideWithValue(broker),
    ]);
    addTearDown(container.dispose);
    container.read(authProvider.notifier).setUser(_user(phone: phone, email: email));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: RegistrationScreen()),
    ));
    await tester.pumpAndSettle();
  }

  // Screen order: first, last, specialty, NPI, [phone], [code].
  final first = find.byType(TextField).at(0);
  final last = find.byType(TextField).at(1);
  final specialty = find.byType(TextField).at(2);
  final npi = find.byType(TextField).at(3);
  final phone = find.byType(TextField).at(4);
  final code = find.byType(TextField).at(5);
  final continueButton = find.widgetWithText(AppButton, Strings.regContinue).first;

  Future<void> fillRequired(WidgetTester tester) async {
    await tester.enterText(first, 'Vimal');
    await tester.enterText(last, 'Nanavati');
    await tester.enterText(specialty, 'Cardiology');
    await tester.enterText(npi, '1851408082');
    await tester.pumpAndSettle();
  }

  Future<void> tapContinue(WidgetTester tester) async {
    await tester.tap(continueButton);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  group('identity', () {
    testWidgets('says who is signed in — by email', (tester) async {
      await pump(tester, phone: '', email: 'vimal@example.com');
      expect(find.text(Strings.regSignedInAs('vimal@example.com')), findsOneWidget);
    });

    testWidgets('says who is signed in — by phone when there is no email',
        (tester) async {
      await pump(tester);
      expect(find.text(Strings.regSignedInAs('+15555550100')), findsOneWidget);
    });

    testWidgets('falls back to the provider email when the account has none',
        (tester) async {
      broker.profile = (name: null, email: 'from-google@example.com');
      await pump(tester, phone: '');
      expect(find.text(Strings.regSignedInAs('from-google@example.com')),
          findsOneWidget);
    });

    testWidgets('prefills the name Google/Apple gave us', (tester) async {
      broker.profile = (name: 'Vimal Kumar Nanavati', email: null);
      await pump(tester, phone: '');
      expect(tester.widget<TextField>(first).controller!.text, 'Vimal');
      expect(tester.widget<TextField>(last).controller!.text, 'Kumar Nanavati');
    });

    testWidgets('"Not you? Sign out" ends the session, Firebase included',
        (tester) async {
      await pump(tester);
      await tester.tap(find.text(Strings.regSignOut));
      await tester.pumpAndSettle();
      expect(broker.signedOut, 1);
    });
  });

  group('labels', () {
    testWidgets('required fields carry a *, and there are no helper texts',
        (tester) async {
      await pump(tester, phone: '');

      for (final label in [
        Strings.regFirstName,
        Strings.regLastName,
        Strings.regSpecialty,
        Strings.regNpi,
      ]) {
        expect(find.text('$label *'), findsOneWidget, reason: label);
      }
      // The optional phone is the one field without one.
      expect(find.text(Strings.regPhone), findsOneWidget);
      expect(find.text('${Strings.regPhone} *'), findsNothing);

      // The old helpers are gone.
      expect(find.textContaining('Optional'), findsNothing);
      expect(find.textContaining('NPI registry'), findsNothing);
    });
  });

  group('specialty', () {
    testWidgets('is required', (tester) async {
      await pump(tester);
      await tester.enterText(first, 'Vimal');
      await tester.enterText(last, 'Nanavati');
      await tester.enterText(npi, '1851408082');
      await tester.pumpAndSettle();

      await tapContinue(tester);

      expect(find.text('Please enter your specialty.'), findsOneWidget);
      expect(auth.registered, isEmpty);
    });

    testWidgets('the error clears as soon as they type', (tester) async {
      await pump(tester);
      await tapContinue(tester);
      expect(find.text('Please enter your specialty.'), findsOneWidget);

      await tester.enterText(specialty, 'Card');
      await tester.pumpAndSettle();
      expect(find.text('Please enter your specialty.'), findsNothing);
    });
  });

  group('phone, for people who signed up without one', () {
    testWidgets('is not asked of someone who signed up by phone', (tester) async {
      await pump(tester);
      expect(find.text(Strings.regPhone), findsNothing);
    });

    testWidgets('can be left empty', (tester) async {
      await pump(tester, phone: '');
      await fillRequired(tester);

      await tapContinue(tester);

      expect(auth.registered, ['Vimal Nanavati|Cardiology|1851408082']);
      expect(broker.codesSentTo, isEmpty);
    });

    testWidgets('a typed but unverified number blocks Continue', (tester) async {
      await pump(tester, phone: '');
      await fillRequired(tester);
      await tester.enterText(phone, _number);
      await tester.pumpAndSettle();

      await tapContinue(tester);

      expect(find.text(Strings.regPhoneUnverified), findsOneWidget);
      expect(auth.registered, isEmpty);
    });

    testWidgets('a half-typed number offers no Send code', (tester) async {
      await pump(tester, phone: '');
      await tester.enterText(phone, '20155');
      await tester.pumpAndSettle();

      expect(find.text(Strings.regPhoneSendCode), findsNothing);
    });

    testWidgets('verify by OTP, then Continue goes through', (tester) async {
      await pump(tester, phone: '');
      await fillRequired(tester);
      await tester.enterText(phone, _number);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(AppButton, Strings.regPhoneSendCode).first);
      await tester.pumpAndSettle();
      expect(broker.codesSentTo, ['+1$_number']);
      expect(find.text(Strings.regPhoneCode), findsOneWidget);

      await tester.enterText(code, _goodCode);
      await tester.pumpAndSettle();
      expect(users.verified, ['token-for-+1$_number']);
      expect(find.text(Strings.regPhoneVerified), findsOneWidget);

      await tapContinue(tester);
      expect(auth.registered, hasLength(1));
      expect(find.text(Strings.regPhoneUnverified), findsNothing);
    });

    testWidgets('a wrong code shows the error and stays unverified',
        (tester) async {
      await pump(tester, phone: '');
      await fillRequired(tester);
      await tester.enterText(phone, _number);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppButton, Strings.regPhoneSendCode).first);
      await tester.pumpAndSettle();

      await tester.enterText(code, '000000');
      await tester.pumpAndSettle();

      expect(find.text(Strings.regPhoneVerified), findsNothing);
      expect(users.verified, isEmpty);
      await tapContinue(tester);
      expect(auth.registered, isEmpty);
    });

    testWidgets('changing the number after verifying starts over',
        (tester) async {
      await pump(tester, phone: '');
      await tester.enterText(phone, _number);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppButton, Strings.regPhoneSendCode).first);
      await tester.pumpAndSettle();
      await tester.enterText(code, _goodCode);
      await tester.pumpAndSettle();
      expect(find.text(Strings.regPhoneVerified), findsOneWidget);

      await tester.enterText(phone, '2015550124');
      await tester.pumpAndSettle();

      expect(find.text(Strings.regPhoneVerified), findsNothing);
      expect(find.text(Strings.regPhoneSendCode), findsWidgets);
    });

    testWidgets('clearing the number makes it optional again', (tester) async {
      await pump(tester, phone: '');
      await fillRequired(tester);
      await tester.enterText(phone, _number);
      await tester.pumpAndSettle();
      await tapContinue(tester);
      expect(auth.registered, isEmpty);

      await tester.enterText(phone, '');
      await tester.pumpAndSettle();
      await tapContinue(tester);

      expect(auth.registered, hasLength(1));
    });
  });

  group('access', () {
    testWidgets('a signed-out user cannot open Your details', (tester) async {
      final container = ProviderContainer(
        overrides: [authProvider.overrideWith(_SignedOut.new)],
      );
      addTearDown(container.dispose);
      final router = container.read(routerProvider);

      router.go(AppRoutes.registration);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      // Settle, so the login screen's entrance animations finish before teardown.
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        AppRoutes.login,
      );
    });
  });
}

class _SignedOut extends AuthNotifier {
  @override
  AuthState build() => const AuthState(AuthStage.signedOut, null);
}

class _NoLookup extends NpiLookup {
  @override
  Future<NpiLookupResult> byName(String first, String last) async =>
      const NpiLookupResult.none();

  @override
  Future<NpiLookupResult> byNumber(String npi) async => const NpiLookupResult.none();
}
