import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/repositories/user_repository.dart';
import 'package:doqto_app/data/services/auth_broker.dart';
import 'package:doqto_app/data/services/npi_lookup.dart';
import 'package:doqto_app/ui/screens/auth/registration_screen.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

// Registration prefills itself from the CMS NPI registry (docs/npi-lookup.md).
// The rules these tests defend: one match prefills, two or more don't, the
// lookup never blocks Continue, and it never clobbers something the user typed.

const _vimal = NpiMatch(
  npi: '1851408082',
  displayName: 'Vimal Nanavati, M.D.',
  firstName: 'Vimal',
  lastName: 'Nanavati',
  addressLine: '180 Otay Lakes Rd Ste 110',
  cityStateZip: 'Bonita, CA 91902-2444',
  city: 'Bonita',
  state: 'CA',
  taxonomy: 'Internal Medicine, Interventional Cardiology',
);

class _FakeNpiLookup extends NpiLookup {
  final List<String> calls = [];
  NpiLookupResult Function(String first, String last) onName;
  NpiLookupResult Function(String npi) onNumber;
  bool throwOnName = false;

  _FakeNpiLookup()
      : onName = ((_, _) => const NpiLookupResult.none()),
        onNumber = ((_) => const NpiLookupResult.none());

  @override
  Future<NpiLookupResult> byName(String first, String last) async {
    calls.add('name:$first $last');
    if (throwOnName) throw Exception('offline');
    return onName(first, last);
  }

  @override
  Future<NpiLookupResult> byNumber(String npi) async {
    calls.add('npi:$npi');
    return onNumber(npi);
  }
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : super(ApiClient(), TokenStorage());

  final List<Map<String, String?>> registrations = [];

  @override
  Future<User> register({
    required String fullName,
    required String? specialty,
    required String npiNumber,
  }) async {
    registrations.add({
      'full_name': fullName,
      'specialty': specialty,
      'npi_number': npiNumber,
    });
    return User.fromJson({
      'id': 'u1',
      'phone': '+15555550100',
      'full_name': fullName,
      'npi_number': npiNumber,
      'role': 'doctor',
      'created_at': DateTime.now().toIso8601String(),
    });
  }
}

/// `register` has no city/state, so the practice location goes through the
/// profile endpoint afterwards. This records what was sent there.
class _FakeUserRepository extends UserRepository {
  _FakeUserRepository() : super(ApiClient());

  final List<Map<String, dynamic>> patches = [];

  @override
  Future<User> updateMe(UserPatchBody patch) async {
    patches.add(patch.toJson());
    return User.fromJson({
      'id': 'u1',
      'phone': '+15555550100',
      'full_name': 'Vimal Nanavati',
      'npi_number': '1851408082',
      'role': 'doctor',
      'created_at': DateTime.now().toIso8601String(),
    });
  }
}

void main() {
  late _FakeNpiLookup lookup;
  late _FakeAuthRepository repo;
  late _FakeUserRepository users;

  setUp(() {
    lookup = _FakeNpiLookup();
    repo = _FakeAuthRepository();
    users = _FakeUserRepository();
  });

  Future<void> pump(WidgetTester tester) async {
    // Tall enough that the whole form — including the match card — fits without
    // scrolling, so taps never need ensureVisible.
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          npiLookupProvider.overrideWithValue(lookup),
          authBrokerProvider.overrideWithValue(FakeAuthBroker()),
          authRepositoryProvider.overrideWithValue(repo),
          userRepositoryProvider.overrideWithValue(users),
        ],
        child: const MaterialApp(home: RegistrationScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  // Fields are in screen order: first, last, specialty, NPI. Finders are lazy,
  // so these can be declared before anything is pumped.
  final firstName = find.byType(TextField).at(0);
  final lastName = find.byType(TextField).at(1);
  final specialty = find.byType(TextField).at(2);
  final npi = find.byType(TextField).at(3);

  // The AppBar title: a neutral tap target that moves focus without submitting.
  // (Tapping Continue would also fire validation and hide the helper text.)
  final outside = find.text('Your details');
  final continueButton = find.byType(AppButton);

  String textOf(WidgetTester tester, Finder f) =>
      tester.widget<TextField>(f).controller!.text;

  // The screen scrolls: the match card can push Continue past the viewport.
  Future<void> tapContinue(WidgetTester tester) async {
    await tester.tap(continueButton);
    // Bounded pumps, not pumpAndSettle: the button shows an indeterminate
    // spinner while submitting, and that never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// Types a name and moves focus out of the name block, which is what fires
  /// the lookup.
  Future<void> enterName(WidgetTester tester, String first, String last) async {
    await tester.enterText(firstName, first);
    await tester.pumpAndSettle();
    await tester.enterText(lastName, last);
    await tester.pumpAndSettle();
    await tester.tap(outside);
    await tester.pumpAndSettle();
  }

  testWidgets('a single match prefills the NPI, the specialty and a card',
      (tester) async {
    lookup.onName = (_, _) => const NpiLookupResult.matched(_vimal);
    await pump(tester);

    await enterName(tester, 'Vimal', 'Nanavati');

    expect(lookup.calls, ['name:Vimal Nanavati']);
    expect(find.text(Strings.regMatchTitle), findsOneWidget);
    expect(find.text('Vimal Nanavati, M.D.'), findsOneWidget);
    expect(find.text('NPI 1851408082'), findsOneWidget);
    expect(find.text('180 Otay Lakes Rd Ste 110'), findsOneWidget);
    expect(find.text('Bonita, CA 91902-2444'), findsOneWidget);

    expect(textOf(tester, npi), '1851408082');
    expect(textOf(tester, specialty), 'Internal Medicine, Interventional Cardiology');

    // The name the user typed is theirs — we never rewrite it.
    expect(textOf(tester, firstName), 'Vimal');
    expect(textOf(tester, lastName), 'Nanavati');
  });

  testWidgets('several matches prefill nothing and ask for the NPI',
      (tester) async {
    lookup.onName = (_, _) => const NpiLookupResult.ambiguous();
    await pump(tester);

    await enterName(tester, 'John', 'Smith');

    expect(find.text(Strings.regMatchTitle), findsNothing);
    expect(find.text(Strings.regNpiAmbiguous), findsOneWidget);
    expect(textOf(tester, npi), isEmpty);
    expect(textOf(tester, specialty), isEmpty);
  });

  testWidgets('after an ambiguous name, the NPI fills in the rest',
      (tester) async {
    lookup.onName = (_, _) => const NpiLookupResult.ambiguous();
    lookup.onNumber = (_) => const NpiLookupResult.matched(_vimal);
    await pump(tester);

    await enterName(tester, 'John', 'Smith');
    await tester.enterText(npi, '1851408082');
    await tester.pumpAndSettle();

    expect(lookup.calls, ['name:John Smith', 'npi:1851408082']);
    expect(find.text(Strings.regMatchTitle), findsOneWidget);
    expect(find.text('Vimal Nanavati, M.D.'), findsOneWidget);
    expect(textOf(tester, specialty), 'Internal Medicine, Interventional Cardiology');
    // The ambiguity hint is gone once we know who they are.
    expect(find.text(Strings.regNpiAmbiguous), findsNothing);
  });

  testWidgets('a partial NPI is not looked up', (tester) async {
    await pump(tester);

    await tester.enterText(npi, '18514080');
    await tester.pumpAndSettle();

    expect(lookup.calls, isEmpty);
  });

  testWidgets('a failed lookup is silent and never blocks Continue',
      (tester) async {
    lookup.throwOnName = true;
    await pump(tester);

    await tester.enterText(firstName, 'Vimal');
    await tester.enterText(lastName, 'Nanavati');
    await tester.enterText(specialty, 'Cardiology');
    await tester.enterText(npi, '1851408082');
    await tester.pumpAndSettle();

    expect(find.text(Strings.regMatchTitle), findsNothing);
    expect(find.textContaining('offline'), findsNothing);

    await tapContinue(tester);

    expect(repo.registrations.single['full_name'], 'Vimal Nanavati');
    expect(repo.registrations.single['npi_number'], '1851408082');
    // No match, so no location to save.
    expect(users.patches, isEmpty);
  });

  testWidgets('a match persists the practice city and state', (tester) async {
    lookup.onName = (_, _) => const NpiLookupResult.matched(_vimal);
    await pump(tester);

    await enterName(tester, 'Vimal', 'Nanavati');
    await tapContinue(tester);

    expect(repo.registrations.single, {
      'full_name': 'Vimal Nanavati',
      'specialty': 'Internal Medicine, Interventional Cardiology',
      'npi_number': '1851408082',
    });
    // `register` ignores a location, so it goes on through the profile.
    expect(users.patches.single, {'city': 'Bonita', 'state': 'CA'});
  });

  testWidgets('a specialty the user typed survives a later match',
      (tester) async {
    lookup.onName = (_, _) => const NpiLookupResult.matched(_vimal);
    await pump(tester);

    await tester.enterText(specialty, 'Pediatrics');
    await tester.pumpAndSettle();
    await enterName(tester, 'Vimal', 'Nanavati');

    expect(textOf(tester, specialty), 'Pediatrics');
    // The NPI was empty, so that one still fills.
    expect(textOf(tester, npi), '1851408082');
  });

  testWidgets('an NPI the user typed is never overwritten', (tester) async {
    lookup.onName = (_, _) => const NpiLookupResult.matched(_vimal);
    lookup.onNumber = (_) => const NpiLookupResult.none();
    await pump(tester);

    await tester.enterText(npi, '1234567890');
    await tester.pumpAndSettle();
    await enterName(tester, 'Vimal', 'Nanavati');

    expect(textOf(tester, npi), '1234567890');
  });

  testWidgets('"Use these details" copies the registry record into the form',
      (tester) async {
    lookup.onName = (_, _) => const NpiLookupResult.matched(_vimal);
    await pump(tester);

    // A typo in the name, a wrong specialty: the registry has it right.
    await enterName(tester, 'Vimla', 'Nanavaty');
    await tester.enterText(specialty, 'Dermatology');
    await tester.pumpAndSettle();

    await tester.tap(find.text(Strings.regMatchUse));
    await tester.pumpAndSettle();

    expect(textOf(tester, firstName), 'Vimal');
    expect(textOf(tester, lastName), 'Nanavati');
    expect(textOf(tester, specialty), _vimal.taxonomy);
    expect(textOf(tester, npi), _vimal.npi);
    // The card stays: it is still who they are.
    expect(find.text(Strings.regMatchTitle), findsOneWidget);
  });

  testWidgets('"Not me" clears the card and everything it filled',
      (tester) async {
    lookup.onName = (_, _) => const NpiLookupResult.matched(_vimal);
    await pump(tester);

    await enterName(tester, 'Vimal', 'Nanavati');
    expect(textOf(tester, npi), '1851408082');

    await tester.tap(find.text(Strings.regMatchDismiss));
    await tester.pumpAndSettle();

    expect(find.text(Strings.regMatchTitle), findsNothing);
    expect(textOf(tester, npi), isEmpty);
    expect(textOf(tester, specialty), isEmpty);

    // And the practice address goes with it.
    await tester.enterText(specialty, 'Cardiology');
    await tester.enterText(npi, '1851408082');
    await tapContinue(tester);
    expect(repo.registrations, hasLength(1));
    expect(users.patches, isEmpty);
  });

  testWidgets('an unchanged name is not looked up twice', (tester) async {
    lookup.onName = (_, _) => const NpiLookupResult.matched(_vimal);
    await pump(tester);

    await enterName(tester, 'Vimal', 'Nanavati');
    await tester.tap(firstName);
    await tester.pumpAndSettle();
    await tester.tap(outside);
    await tester.pumpAndSettle();

    expect(lookup.calls, ['name:Vimal Nanavati']);
  });

  testWidgets('a name that found nobody is asked again — CMS may have been down',
      (tester) async {
    // "None" and "the registry was unreachable" look identical from here, so
    // the screen retries. Genuine misses are cached inside the service, so the
    // retry costs no network.
    lookup.onName = (_, _) => const NpiLookupResult.none();
    await pump(tester);

    await enterName(tester, 'Vimal', 'Nanavati');
    await tester.tap(firstName);
    await tester.pumpAndSettle();
    await tester.tap(outside);
    await tester.pumpAndSettle();

    expect(lookup.calls, ['name:Vimal Nanavati', 'name:Vimal Nanavati']);
  });

  testWidgets('moving between the two name fields does not query early',
      (tester) async {
    await pump(tester);

    await tester.enterText(firstName, 'Vimal');
    await tester.pumpAndSettle();
    await tester.enterText(lastName, 'Nanavati');
    await tester.pumpAndSettle();

    // Focus never left the name block, so nothing has been asked yet.
    expect(lookup.calls, isEmpty);
  });

  testWidgets('a one-letter name is never sent to the registry',
      (tester) async {
    await pump(tester);

    await enterName(tester, 'V', 'N');

    expect(lookup.calls, isEmpty);
    expect(find.text('Your first name must be at least 2 characters.'),
        findsOneWidget);
  });

  testWidgets('both name fields dismiss the keyboard on a tap outside',
      (tester) async {
    // Guards the rule in CLAUDE.md for the two fields this feature added.
    await pump(tester);

    for (final f in [firstName, lastName]) {
      await tester.tap(f);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.tap(outside);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
    }
  });

  testWidgets('a complete NPI drops the keypad, which has no return key',
      (tester) async {
    await pump(tester);

    await tester.tap(npi);
    await tester.pumpAndSettle();
    await tester.enterText(npi, '185140808');
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.enterText(npi, '1851408082');
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('submitting an incomplete form validates instead of registering',
      (tester) async {
    await pump(tester);

    await tapContinue(tester);

    expect(repo.registrations, isEmpty);
    expect(find.text('Please enter your first name.'), findsOneWidget);
    expect(find.text('Please enter your last name.'), findsOneWidget);
    expect(find.text('Please enter your NPI number.'), findsOneWidget);
  });
}
