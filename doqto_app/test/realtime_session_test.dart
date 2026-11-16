import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/models/user.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/realtime_state.dart';

import 'support/fake_socket.dart';

/// Auth whose stage a test sets directly.
class _Auth extends AuthNotifier {
  @override
  AuthState build() => const AuthState(AuthStage.unknown, null);
  void set(AuthStage stage, [User? user]) => state = AuthState(stage, user);
}

User _user() => User.fromJson({
      'id': 'me',
      'phone': '+15550000101',
      'full_name': 'Dr A',
      'npi_number': '1234567893',
      'role': 'doctor',
      'created_at': '2026-09-05T00:00:00Z',
    });

void main() {
  late FakeSocket socket;
  late ProviderContainer container;
  late _Auth auth;

  setUp(() {
    socket = FakeSocket();
    container = ProviderContainer(overrides: [
      websocketClientProvider.overrideWithValue(socket),
      authProvider.overrideWith(_Auth.new),
    ]);
    container.read(realtimeSessionProvider); // activate
    auth = container.read(authProvider.notifier) as _Auth;
  });
  tearDown(() => container.dispose());

  test('nothing happens before auth resolves', () async {
    await settle();
    expect(socket.connectCalls, 0);
    expect(socket.closeCalls, 0);
  });

  test('a signed-in doctor WITHOUT an org gets a socket', () async {
    // This is the regression: the socket used to open only inside the
    // org branch of sign-in, so org-less accounts had no realtime at all.
    auth.set(AuthStage.signedIn, _user());
    await settle();
    expect(socket.connectCalls, 1);
    expect(socket.lastTokenProvider, isNotNull);
  });

  test('waiting on org verification still gets a socket', () async {
    auth.set(AuthStage.pendingVerification, _user());
    await settle();
    expect(socket.connectCalls, 1);
  });

  test('needsOrg (backend unreachable at sign-in) still tries', () async {
    auth.set(AuthStage.needsOrg, _user());
    await settle();
    expect(socket.connectCalls, 1);
  });

  test('an unregistered session does not open a socket', () async {
    auth.set(AuthStage.needsRegistration, _user());
    await settle();
    expect(socket.connectCalls, 0);
  });

  test('sign-out closes the socket', () async {
    auth.set(AuthStage.signedIn, _user());
    await settle();
    auth.set(AuthStage.signedOut);
    await settle();
    expect(socket.closeCalls, 1);
  });

  test('wantsRealtimeSocket needs a user', () {
    expect(wantsRealtimeSocket(const AuthState(AuthStage.signedIn, null)), isFalse);
    expect(wantsRealtimeSocket(AuthState(AuthStage.signedIn, _user())), isTrue);
  });
}
