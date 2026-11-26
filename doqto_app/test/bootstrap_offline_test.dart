import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/api/api_client.dart';
import 'package:doqto_app/data/api/token_storage.dart';
import 'package:doqto_app/data/models/organization.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/data/repositories/auth_repository.dart';
import 'package:doqto_app/data/repositories/org_repository.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/ui/screens/splash/splash_screen.dart';

// Launching with no connection used to delete the tokens and show the login
// screen. Only the server can end a session: these pin which answers do.

class _Tokens extends TokenStorage {
  String? access = 'access';
  String? refresh = 'refresh';
  int clears = 0;

  @override
  Future<String?> get accessToken async => access;
  @override
  Future<String?> get refreshToken async => refresh;
  @override
  Future<void> saveTokens({required String access, required String refresh}) async {
    this.access = access;
    this.refresh = refresh;
  }

  @override
  Future<void> clear() async {
    clears++;
    access = null;
    refresh = null;
  }
}

class _Auth extends AuthRepository {
  _Auth(this.failure) : super(ApiClient(), TokenStorage());

  /// Thrown by `/users/me`; null answers with a registered doctor.
  Object? failure;
  int calls = 0;
  Completer<void>? gate;

  @override
  Future<User> me() async {
    calls++;
    if (gate != null) await gate!.future;
    final f = failure;
    if (f != null) throw f;
    return User.fromJson({
      'id': 'u1',
      'phone': '+15555550100',
      'full_name': 'Dr Test',
      'npi_number': '1851408082',
      'role': 'doctor',
      'created_at': '2026-09-05T00:00:00Z',
    });
  }
}

class _Orgs extends OrgRepository {
  _Orgs() : super(ApiClient());
  @override
  Future<List<Organization>> listMine() async => [];
}

void main() {
  late _Tokens tokens;

  ProviderContainer boot(_Auth auth) {
    tokens = _Tokens();
    final c = ProviderContainer(overrides: [
      tokenStorageProvider.overrideWithValue(tokens),
      authRepositoryProvider.overrideWithValue(auth),
      orgRepositoryProvider.overrideWithValue(_Orgs()),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  group('bootstrap', () {
    test('a network failure keeps the tokens and never signs out', () async {
      // What ApiClient throws for a connection failure or timeout.
      final c = boot(_Auth(ApiException('connection error')));
      await c.read(authProvider.notifier).bootstrap();

      expect(tokens.clears, 0);
      expect(tokens.access, 'access');
      expect(tokens.refresh, 'refresh');
      expect(c.read(authProvider).stage, AuthStage.unreachable);
      expect(c.read(authProvider).stage, isNot(AuthStage.signedOut));
    });

    test('a server error or a non-API exception keeps the tokens too', () async {
      for (final failure in <Object>[
        ApiException('', status: 503),
        ApiException('', status: 500),
        TimeoutException('slow'),
        const FormatException('bad json'),
      ]) {
        final c = boot(_Auth(failure));
        await c.read(authProvider.notifier).bootstrap();
        expect(tokens.clears, 0, reason: '$failure');
        expect(c.read(authProvider).stage, AuthStage.unreachable, reason: '$failure');
      }
    });

    test('a 401 clears the tokens and signs out', () async {
      final c = boot(_Auth(ApiException('invalid_token', status: 401)));
      await c.read(authProvider.notifier).bootstrap();

      expect(tokens.clears, greaterThanOrEqualTo(1));
      expect(tokens.access, isNull);
      expect(tokens.refresh, isNull);
      expect(c.read(authProvider).stage, AuthStage.signedOut);
    });

    test('a terminal session code signs out', () async {
      for (final code in sessionTerminalCodes) {
        final c = boot(_Auth(ApiException(code, status: 401)));
        await c.read(authProvider.notifier).bootstrap();
        expect(tokens.access, isNull, reason: code);
        expect(c.read(authProvider).stage, AuthStage.signedOut, reason: code);
      }
    });

    test('pin_required still routes to the PIN gate and keeps the tokens', () async {
      final c = boot(_Auth(ApiException('pin_required', status: 403)));
      await c.read(authProvider.notifier).bootstrap();

      expect(tokens.clears, 0);
      expect(c.read(authProvider).stage, AuthStage.pinRequired);
    });

    test('no tokens at all is signed out without asking the server', () async {
      final auth = _Auth(null);
      final c = boot(auth);
      tokens
        ..access = null
        ..refresh = null;
      await c.read(authProvider.notifier).bootstrap();
      expect(auth.calls, 0);
      expect(c.read(authProvider).stage, AuthStage.signedOut);
    });

    test('retrying after the connection returns signs in with the same tokens', () async {
      final auth = _Auth(ApiException('connection error'));
      final c = boot(auth);
      final n = c.read(authProvider.notifier);
      await n.bootstrap();
      expect(c.read(authProvider).stage, AuthStage.unreachable);

      auth.failure = null;
      await n.bootstrap();
      expect(c.read(authProvider).stage, AuthStage.signedIn);
      expect(c.read(authProvider).user?.id, 'u1');
      expect(tokens.clears, 0);
    });

    test('app resume re-runs the launch check while unreachable', () async {
      final auth = _Auth(ApiException('connection error'));
      final c = boot(auth);
      final n = c.read(authProvider.notifier);
      await n.bootstrap();
      expect(auth.calls, 1);

      auth.failure = null;
      n.onAppResumed();
      await n.bootstrap(); // joins the run the resume started
      expect(auth.calls, 2, reason: 'one shared round-trip, not two');
      expect(c.read(authProvider).stage, AuthStage.signedIn);
    });
  });

  test('a refresh that never got an answer is not a rejected refresh token', () {
    expect(ApiClient.refreshFailureIsTransient(null), isTrue);
    expect(ApiClient.refreshFailureIsTransient(500), isTrue);
    expect(ApiClient.refreshFailureIsTransient(503), isTrue);
    expect(ApiClient.refreshFailureIsTransient(408), isTrue);
    expect(ApiClient.refreshFailureIsTransient(429), isTrue);
    expect(ApiClient.refreshFailureIsTransient(401), isFalse);
    expect(ApiClient.refreshFailureIsTransient(403), isFalse);
    expect(ApiClient.refreshFailureIsTransient(400), isFalse);
  });

  group('splash', () {
    testWidgets('while the launch check runs it is named Loading, and a slow '
        'one gets a spinner', (tester) async {
      final semantics = tester.ensureSemantics();
      final auth = _Auth(ApiException('connection error'))
        ..gate = Completer<void>();
      tokens = _Tokens();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          tokenStorageProvider.overrideWithValue(tokens),
          authRepositoryProvider.overrideWithValue(auth),
          orgRepositoryProvider.overrideWithValue(_Orgs()),
        ],
        child: const MaterialApp(home: SplashScreen()),
      ));
      await tester.pump();

      // Stage is still unknown: logo only, but VoiceOver has something.
      expect(find.bySemanticsLabel(RegExp('^Loading')), findsOneWidget);
      final node = tester.getSemantics(
        find.byKey(const ValueKey('splash-loading')),
      );
      expect(node.label, startsWith('Loading'));
      expect(node.flagsCollection.isLiveRegion, isTrue);
      // A warm start never sees a spinner…
      expect(find.byKey(const ValueKey('splash-spinner')), findsNothing);
      // …a launch that takes over a second does: small, white, under the logo.
      await tester.pump(const Duration(milliseconds: 1100));
      final spinner = tester.widget<CircularProgressIndicator>(
        find.byKey(const ValueKey('splash-spinner')),
      );
      expect(spinner.color, Colors.white);
      expect(spinner.strokeWidth, 2);
      expect(
        tester.getSize(find.byKey(const ValueKey('splash-spinner'))),
        const Size(20, 20),
      );

      // The check ends (offline): the Retry pane replaces it.
      auth.gate!.complete();
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('splash-loading')), findsNothing);
      expect(find.byKey(const ValueKey('load-failed-retry')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('offline shows the pane with Retry, and Retry shows progress',
        (tester) async {
      final auth = _Auth(ApiException('connection error'));
      tokens = _Tokens();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          tokenStorageProvider.overrideWithValue(tokens),
          authRepositoryProvider.overrideWithValue(auth),
          orgRepositoryProvider.overrideWithValue(_Orgs()),
        ],
        child: const MaterialApp(home: SplashScreen()),
      ));
      await tester.pumpAndSettle();

      expect(
        find.text("Can't reach Doqto. Check your connection and try again."),
        findsOneWidget,
      );
      final retry = find.byKey(const ValueKey('load-failed-retry'));
      expect(retry, findsOneWidget);
      expect(tester.getSize(retry).height, greaterThanOrEqualTo(44));
      expect(auth.calls, 1);

      // Retry while still offline: the button spins, then the pane is back.
      auth.gate = Completer<void>();
      await tester.tap(retry);
      await tester.pump();
      expect(auth.calls, 2);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      auth.gate!.complete();
      auth.gate = null;
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(retry, findsOneWidget);
      expect(tokens.clears, 0);
    });
  });
}
