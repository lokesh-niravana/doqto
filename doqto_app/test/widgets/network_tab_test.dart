import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/models/network_profile.dart';
import 'package:doqto_app/state/network_state.dart';
import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/ui/screens/network/network_tab_screen.dart';
import 'package:doqto_app/ui/widgets/app_skeleton.dart';

/// No received invitations and no connections — the state a doctor is in right
/// after sending their first request.
class _NoInvitations extends InvitationsNotifier {
  @override
  Future<List<Invitation>> build() async => const [];
}

class _NoConnections extends ConnectionsNotifier {
  @override
  Future<List<PersonCard>> build() async => const [];
}

/// Fails until [connectionsFail] is cleared, like a dropped connection.
bool connectionsFail = false;

class _FlakyConnections extends ConnectionsNotifier {
  @override
  Future<List<PersonCard>> build() async {
    if (connectionsFail) throw Exception('offline');
    return const [];
  }
}

class _NoSuggestions extends SuggestionsNotifier {
  @override
  Future<List<PersonCard>> build() async => const [];
}

/// Answers only when the test says so.
Completer<List<PersonCard>> slowConnections = Completer();

class _SlowConnections extends ConnectionsNotifier {
  @override
  Future<List<PersonCard>> build() => slowConnections.future;
}

String? lastRoute;

Widget _app({bool flaky = false, bool slow = false}) => ProviderScope(
      overrides: [
        invitationsProvider.overrideWith(_NoInvitations.new),
        connectionsProvider.overrideWith(slow
            ? _SlowConnections.new
            : flaky
                ? _FlakyConnections.new
                : _NoConnections.new),
        if (flaky || slow) suggestionsProvider.overrideWith(_NoSuggestions.new),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/network',
          routes: [
            GoRoute(
              path: '/network',
              builder: (_, _) => const NetworkTabScreen(),
            ),
            GoRoute(
              path: AppRoutes.networkInvitations,
              builder: (_, _) {
                lastRoute = AppRoutes.networkInvitations;
                return const Scaffold(body: Text('INBOX'));
              },
            ),
            GoRoute(
              path: AppRoutes.peopleSearch,
              builder: (_, _) => const Scaffold(body: Text('SEARCH')),
            ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('the invitations inbox is reachable with zero received requests',
      (tester) async {
    lastRoute = null;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Sent requests live in that inbox; without this entry they were
    // unreachable and could never be withdrawn.
    final action = find.byIcon(Icons.person_add_alt_1_outlined);
    expect(action, findsOneWidget);

    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('INBOX'), findsOneWidget);
    expect(lastRoute, AppRoutes.networkInvitations);
  });

  testWidgets('a failed load shows an error with Retry, not the empty pane',
      (tester) async {
    connectionsFail = true;
    addTearDown(() => connectionsFail = false);
    await tester.pumpWidget(_app(flaky: true));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('network-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('network-retry')), findsOneWidget);

    connectionsFail = false;
    await tester.tap(find.byKey(const ValueKey('network-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('network-error')), findsNothing);
  });

  testWidgets('one answer in, one pending: still loading, not an empty network',
      (tester) async {
    slowConnections = Completer();
    await tester.pumpWidget(_app(slow: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // Invitations answered (none); connections have not.
    expect(find.byType(SkeletonList), findsOneWidget);
    expect(find.text(Strings.netEmptyConnections), findsNothing);
    expect(find.byKey(const ValueKey('network-error')), findsNothing);

    slowConnections.complete(const []);
    await tester.pumpAndSettle();
    expect(find.byType(SkeletonList), findsNothing);
  });
}
