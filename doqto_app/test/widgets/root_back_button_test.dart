import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/data/repositories/network_repository.dart';
import 'package:doqto_app/ui/screens/people/person_profile_screen.dart';

import '../support/fake_socket.dart';

// A screen opened from a link is the only route on the stack (go_router
// replaces the stack on a platform deep link). It must still have a way out.

class _Repo extends NetworkRepository {
  _Repo() : super(ApiClient());

  @override
  Future<NetworkProfile> getProfile(String userId) async =>
      NetworkProfile.fromJson({
        'id': userId,
        'full_name': 'Dr One',
        'degree': 'out',
        'connection_state': 'none',
        'can_message': 'denied',
      });
}

GoRouter _router(String initial) => GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(
          path: AppRoutes.chats,
          builder: (_, s) => Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => context.push(AppRoutes.person('u1')),
                  child: const Text('chats-home'),
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/people/:userId',
          builder: (_, s) =>
              PersonProfileScreen(userId: s.pathParameters['userId']!),
        ),
      ],
    );

Widget _app(GoRouter router) => ProviderScope(
      overrides: [
        networkRepositoryProvider.overrideWithValue(_Repo()),
        websocketClientProvider.overrideWithValue(FakeSocket()),
      ],
      child: MaterialApp.router(routerConfig: router),
    );

void main() {
  testWidgets('a profile opened from a link has a back button that goes to chats',
      (tester) async {
    final router = _router(AppRoutes.person('u1'));
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();

    // The only route: nothing to pop, so a stock AppBar would draw nothing.
    expect(router.canPop(), isFalse);
    final back = find.byKey(const ValueKey('root-back-home'));
    expect(back, findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(tester.getSize(back).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(back).height, greaterThanOrEqualTo(44));

    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('chats-home'), findsOneWidget);
    expect(find.byType(PersonProfileScreen), findsNothing);
  });

  testWidgets('pushed over another screen it is the ordinary back button',
      (tester) async {
    final router = _router(AppRoutes.chats);
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('chats-home'));
    await tester.pumpAndSettle();

    expect(find.byType(PersonProfileScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('root-back-home')), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('chats-home'), findsOneWidget);
    expect(find.byType(PersonProfileScreen), findsNothing);
  });
}
