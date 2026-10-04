import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/repositories/org_repository.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/ui/screens/org/create_org_screen.dart';
import 'package:doqto_app/ui/widgets/app_text_field.dart';
import 'package:doqto_app/ui/widgets/primary_button.dart';

// Create an organization: the router lets a signed-in doctor in (it used to
// bounce them to chats), and the flow goes find → details → review → created.

class _SignedIn extends AuthNotifier {
  int refreshes = 0;
  @override
  AuthState build() => const AuthState(AuthStage.signedIn, null);
  @override
  Future<void> refreshOrgStatus() async => refreshes++;
}

class _FakeConvs extends ConversationsNotifier {
  @override
  Future<List<Conversation>> build() async => const [];
}

class _FakeInvites extends InvitationsNotifier {
  @override
  Future<List<Invitation>> build() async => const [];
}

const _mine = DirectoryEntry(
  source: 'cms_group',
  sourceId: '3577476894',
  name: 'Saint Lukes Physician Group',
  city: 'Kansas City',
  state: 'MO',
  practiceType: PracticeType.specialtyGroup,
  memberCount: 1233,
  youAreListed: true,
);

const _taken = DirectoryEntry(
  source: 'cms_group',
  sourceId: '8224348529',
  name: 'Saint Lukes Neighborhood Clinics',
  city: 'Kansas City',
  state: 'MO',
  practiceType: PracticeType.specialtyGroup,
  memberCount: 7,
  doqtoOrgId: 'org-2',
  doqtoOrgName: 'Saint Lukes Neighborhood Clinics',
);

class _FakeOrgs extends OrgRepository {
  _FakeOrgs() : super(ApiClient());
  final created = <(String, PracticeType?, String?, DirectoryEntry?)>[];

  @override
  Future<List<DirectoryEntry>> suggestedDirectory() async => [_mine];

  @override
  Future<List<DirectoryEntry>> searchDirectory(String query, {String? state}) async =>
      [_mine, _taken];

  @override
  Future<List<Organization>> listMine() async => const [];

  @override
  Future<Organization> create({
    required String name,
    String? address,
    String? city,
    String? state,
    PracticeType? practiceType,
    DirectoryEntry? from,
  }) async {
    created.add((name, practiceType, state, from));
    return Organization(
      id: 'org-1',
      name: name,
      address: null,
      city: city,
      state: state,
      practiceType: practiceType?.wire,
      inviteCode: 'SLPG·1233',
      status: from?.youAreListed == true ? OrgStatus.active : OrgStatus.pending,
      reviewNotes: null,
      verifiedAt: null,
      createdAt: DateTime.now(),
      memberCount: 1,
    );
  }
}

void main() {
  group('router', () {
    Future<String> land(WidgetTester tester, String path) async {
      final container = ProviderContainer(overrides: [
        authProvider.overrideWith(_SignedIn.new),
        orgRepositoryProvider.overrideWithValue(_FakeOrgs()),
        conversationsProvider.overrideWith(_FakeConvs.new),
        invitationsProvider.overrideWith(_FakeInvites.new),
      ]);
      addTearDown(container.dispose);
      final router = container.read(routerProvider);
      router.go(path);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pump();
      final landed = router.routerDelegate.currentConfiguration.uri.path;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
      return landed;
    }

    testWidgets('a signed-in doctor can open create and join', (tester) async {
      expect(await land(tester, AppRoutes.createOrg), AppRoutes.createOrg);
      expect(await land(tester, AppRoutes.joinOrg), AppRoutes.joinOrg);
    });

    testWidgets('the pending screen no longer holds a signed-in doctor',
        (tester) async {
      expect(await land(tester, AppRoutes.pending), AppRoutes.chats);
    });
  });

  group('flow', () {
    late _FakeOrgs orgs;

    Future<void> open(WidgetTester tester) async {
      // A phone-sized screen, so the whole details form is laid out.
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      orgs = _FakeOrgs();
      final router = GoRouter(
        initialLocation: AppRoutes.createOrg,
        routes: [
          GoRoute(
              path: AppRoutes.createOrg,
              builder: (_, _) => const CreateOrgScreen()),
          GoRoute(
              path: AppRoutes.myOrg,
              builder: (_, _) => const Text('MY ORG')),
          GoRoute(
              path: AppRoutes.joinOrg,
              builder: (_, _) => const Text('JOIN')),
        ],
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          authProvider.overrideWith(_SignedIn.new),
          orgRepositoryProvider.overrideWithValue(orgs),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('pick your suggested practice, review, create', (tester) async {
      await open(tester);

      expect(find.text('SUGGESTED FOR YOU'), findsOneWidget);
      expect(find.text("You're listed"), findsOneWidget);
      await tester.tap(find.text('Saint Lukes Physician Group'));
      await tester.pumpAndSettle();

      // Details came from the directory.
      expect(find.text('STEP 1 OF 2'), findsOneWidget);
      expect(find.widgetWithText(AppTextField, 'Saint Lukes Physician Group'),
          findsOneWidget);
      expect(find.widgetWithText(AppTextField, 'Kansas City'), findsOneWidget);

      await tester.tap(find.widgetWithText(AppButton, 'Continue').first);
      await tester.pumpAndSettle();
      expect(find.text('Verified right away'), findsOneWidget);

      await tester.tap(find.widgetWithText(AppButton, 'Create organization').first);
      await tester.pumpAndSettle();

      expect(orgs.created.single.$1, 'Saint Lukes Physician Group');
      expect(orgs.created.single.$2, PracticeType.specialtyGroup);
      expect(orgs.created.single.$3, 'MO');
      expect(orgs.created.single.$4?.sourceId, '3577476894');
      expect(find.text('Organization created'), findsOneWidget);
      expect(find.textContaining('is verified'), findsOneWidget);

      await tester.tap(find.widgetWithText(AppButton, 'Done').first);
      await tester.pumpAndSettle();
      expect(find.text('MY ORG'), findsOneWidget);
    });

    testWidgets('enter it yourself needs a practice type and starts pending',
        (tester) async {
      await open(tester);

      await tester.tap(find.text("Can't find it? Enter it yourself"));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Riverside Cardiology');
      await tester.tap(find.widgetWithText(AppButton, 'Continue').first);
      await tester.pumpAndSettle();
      expect(find.text('Choose a practice type.'), findsOneWidget);

      await tester.tap(find.text('Independent practice'));
      await tester.tap(find.widgetWithText(AppButton, 'Continue').first);
      await tester.pumpAndSettle();
      expect(find.text('It starts as pending'), findsOneWidget);

      await tester.tap(find.widgetWithText(AppButton, 'Create organization').first);
      await tester.pumpAndSettle();
      expect(orgs.created.single.$4, isNull);
      expect(find.textContaining('waiting for verification'), findsOneWidget);
    });

    testWidgets('a practice already on Doqto offers joining, not creating',
        (tester) async {
      await open(tester);

      await tester.enterText(find.byType(TextField).first, 'saint lukes');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('On Doqto'), findsOneWidget);

      await tester.tap(find.text('Saint Lukes Neighborhood Clinics'));
      await tester.pumpAndSettle();
      expect(find.text('Ask a member for the invite code to join.'), findsOneWidget);

      await tester.tap(find.widgetWithText(AppButton, 'Enter an invite code').first);
      await tester.pumpAndSettle();
      expect(find.text('JOIN'), findsOneWidget);
      expect(orgs.created, isEmpty);
    });
  });
}
