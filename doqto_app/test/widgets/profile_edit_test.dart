import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/tokens/colors.dart';
import 'package:doqto_app/core/utils/error_messages.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/user_repository.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/ui/screens/profile/profile_edit_screen.dart';
import 'package:doqto_app/ui/widgets/app_text_field.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

/// Edit profile: a bad email is caught on the form (not sent for a 422), a
/// skill typed but not added is saved, and leaving with edits asks first.
final _user = User.fromJson({
  'id': 'me',
  'phone': '+15550000101',
  'full_name': 'Dr A',
  'npi_number': '1234567893',
  'role': 'doctor',
  'skills': ['Echo'],
  'created_at': '2026-09-05T00:00:00Z',
});

/// What the form opens with; each test starts from [_user].
User _current = _user;

class _Auth extends AuthNotifier {
  @override
  AuthState build() => AuthState(AuthStage.signedIn, _current);
}

class _Users extends UserRepository {
  _Users() : super(ApiClient());
  final patches = <UserPatchBody>[];
  @override
  Future<User> updateMe(UserPatchBody patch) async {
    patches.add(patch);
    return _user;
  }
}

void main() {
  late _Users users;
  setUp(() {
    users = _Users();
    _current = _user;
  });

  Future<void> open(WidgetTester tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/edit'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        GoRoute(path: '/edit', builder: (_, _) => const ProfileEditScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authProvider.overrideWith(_Auth.new),
        userRepositoryProvider.overrideWithValue(users),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditScreen), findsOneWidget);
  }

  Finder field(String label) => find.descendant(
        of: find.byWidgetPredicate((w) => w is AppTextField && w.label == label),
        matching: find.byType(TextField),
      );

  Future<void> toBottom(WidgetTester tester) async {
    // A focused field scrolls itself back into view; let go of it first.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await toBottom(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Save changes').first);
    await tester.pumpAndSettle();
  }

  testWidgets('an invalid email stops the save and shows on the field', (tester) async {
    await open(tester);
    await tester.enterText(field('Email'), 'not-an-email');
    await tapSave(tester);
    expect(users.patches, isEmpty, reason: 'never sent for the server to refuse');
    // Scrolled back to the field, with its own message.
    expect(find.text("That doesn't look like an email address."), findsOneWidget);
    expect(find.byType(ProfileEditScreen), findsOneWidget);

    // Empty is allowed: the address is optional.
    await tester.enterText(field('Email'), '');
    await tapSave(tester);
    expect(users.patches, hasLength(1));
    expect(users.patches.single.email, isNull);
    expect(find.byType(ProfileEditScreen), findsNothing);
  });

  // PATCH /users/me keeps a field that is left out. An emptied Email or
  // Years of experience must go as an explicit null, or the save is reported
  // as done with the old value still there.
  testWidgets('emptying Email and Years of experience clears them on the server', (tester) async {
    _current = User.fromJson({
      'id': 'me',
      'phone': '+15550000101',
      'email': 'a@clinic.com',
      'full_name': 'Dr A',
      'role': 'doctor',
      'years_of_experience': 12,
      'created_at': '2026-09-05T00:00:00Z',
    });
    await open(tester);
    await tester.enterText(field('Email'), '');
    await tester.enterText(field('Years of experience'), '');
    await tapSave(tester);
    final json = users.patches.single.toJson();
    expect(json.containsKey('email'), isTrue);
    expect(json['email'], isNull);
    expect(json.containsKey('years_of_experience'), isTrue);
    expect(json['years_of_experience'], isNull);
    expect(find.byType(ProfileEditScreen), findsNothing);
  });

  testWidgets('fields that were already empty are not sent as nulls', (tester) async {
    await open(tester);
    await tester.enterText(field('Full name'), 'Dr B');
    await tapSave(tester);
    final json = users.patches.single.toJson();
    expect(json.containsKey('email'), isFalse);
    expect(json.containsKey('years_of_experience'), isFalse);
  });

  // The server keeps phone-or-email: an account with no phone cannot lose
  // its email. Stopped on the field, with the form still open.
  testWidgets('an account with no phone cannot remove its email', (tester) async {
    _current = User.fromJson({
      'id': 'me',
      'email': 'a@clinic.com',
      'full_name': 'Dr A',
      'role': 'doctor',
      'created_at': '2026-09-05T00:00:00Z',
    });
    await open(tester);
    await tester.enterText(field('Email'), '');
    await tapSave(tester);
    expect(users.patches, isEmpty);
    expect(find.text(Strings.profileEmailCannotClear), findsOneWidget);
    expect(find.byType(ProfileEditScreen), findsOneWidget);
  });

  testWidgets('a skill typed but not added is saved, not dropped', (tester) async {
    await open(tester);
    await toBottom(tester);
    final skill = find.bySemanticsLabel(Strings.a11ySkillField).first;
    await tester.enterText(skill, 'Cath lab');
    await tapSave(tester);
    expect(users.patches.single.skills, ['Echo', 'Cath lab']);
  });

  testWidgets('leaving with edits asks; Keep editing stays, Discard leaves', (tester) async {
    await open(tester);
    await tester.enterText(field('Full name'), 'Dr B');
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text(Strings.profileDiscardTitle), findsOneWidget);
    await tester.tap(find.text(Strings.keepEditing));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditScreen), findsOneWidget);
    expect(find.text('Dr B'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    final discard = find.byKey(const ValueKey('profile-discard-confirm'));
    expect(tester.widget<TextButton>(discard).style!.foregroundColor!.resolve({}), AppColors.red);
    await tester.tap(discard);
    await tester.pumpAndSettle();
    expect(find.byType(ProfileEditScreen), findsNothing);
    expect(users.patches, isEmpty);
  });

  testWidgets('an untouched form leaves without asking', (tester) async {
    await open(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text(Strings.profileDiscardTitle), findsNothing);
    expect(find.byType(ProfileEditScreen), findsNothing);
  });

  test('a 422 reads as a rejected detail, not "Something went wrong"', () {
    final shown = ErrorMessages.forApi(ApiException('validation', status: 422));
    expect(shown, contains("weren't accepted"));
  });
}
