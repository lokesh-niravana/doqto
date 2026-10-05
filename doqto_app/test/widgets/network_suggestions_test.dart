import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/repositories/network_repository.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/ui/screens/network/network_tab_screen.dart';

// Network tab → "Recommended for you": why each doctor is suggested, a See all
// link past five, and × hides a card for good.

PersonCard _p(String id, String name, String? reason, {int mutual = 0}) =>
    PersonCard(
      id: id,
      fullName: name,
      headline: null,
      specialty: 'Cardiology',
      locationLabel: 'Leawood, KS',
      avatarColor: null,
      avatarUrl: null,
      avatarPresignedUrl: null,
      degree: mutual > 0 ? ConnectionDegree.second : ConnectionDegree.out,
      mutualCount: mutual,
      reason: reason,
    );

final _suggested = [
  _p('a', 'Dr Colleague', 'colleague'),
  _p('b', 'Dr Mutual', 'mutual', mutual: 3),
  _p('c', 'Dr Nearby Cardiologist', 'specialty_nearby'),
  _p('d', 'Dr Same Specialty', 'specialty'),
  _p('e', 'Dr New', 'new_member'),
  _p('f', 'Dr Sixth', 'nearby'),
];

class _NoInvitations extends InvitationsNotifier {
  @override
  Future<List<Invitation>> build() async => const [];
}

class _OneConnection extends ConnectionsNotifier {
  @override
  Future<List<PersonCard>> build() async => [_p('z', 'Dr Friend', null)];
}

class _Repo extends NetworkRepository {
  _Repo() : super(ApiClient());
  final dismissed = <String>[];
  @override
  Future<CursorPage<PersonCard>> suggestions({String? cursor, int? limit}) async =>
      CursorPage(List.of(_suggested), null);
  @override
  Future<void> dismissSuggestion(String userId) async => dismissed.add(userId);
}

void main() {
  testWidgets('recommended for you: reasons, see all, dismiss', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final repo = _Repo();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        invitationsProvider.overrideWith(_NoInvitations.new),
        connectionsProvider.overrideWith(_OneConnection.new),
        networkRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/network',
          routes: [
            GoRoute(path: '/network', builder: (_, _) => const NetworkTabScreen()),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('RECOMMENDED FOR YOU'), findsOneWidget);
    expect(find.text('In your organization'), findsOneWidget);
    expect(find.text('3 mutual connections'), findsOneWidget);
    expect(find.text('Cardiology · Leawood, KS'), findsOneWidget);
    expect(find.text('New to Doqto'), findsOneWidget);
    // Five shown; the sixth is behind See all.
    expect(find.text('Dr Sixth'), findsNothing);
    // One Connect pill per shown card.
    expect(find.text('Connect'), findsNWidgets(5));
    expect(find.text('See all'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide Dr Colleague'));
    await tester.pumpAndSettle();
    expect(repo.dismissed, ['a']);
    expect(find.text('Dr Colleague'), findsNothing);
    // The sixth moves up; with five left there's nothing behind See all.
    expect(find.text('Dr Sixth'), findsOneWidget);
    expect(find.text('See all'), findsNothing);
  });
}
