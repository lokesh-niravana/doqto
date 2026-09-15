import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/models/user.dart';
import '../data/services/auth_broker.dart';
import '../data/repositories/user_repository.dart';
import 'org_state.dart';

enum AuthStage {
  unknown,
  signedOut,
  needsRegistration,
  /// Straight after registration: pick a plan. Only ever set by
  /// [AuthNotifier.completeRegistration] — there is no server-side record of a
  /// plan yet, so a returning user is never sent back here.
  needsPayment,
  needsOrg,
  pendingVerification,
  signedIn,
}

class AuthState {
  final AuthStage stage;
  final User? user;
  const AuthState(this.stage, this.user);

  AuthState copyWith({AuthStage? stage, User? user}) =>
      AuthState(stage ?? this.stage, user ?? this.user);
}

class AuthNotifier extends Notifier<AuthState> {
  StreamSubscription<String>? _tokenRefreshSub;

  @override
  AuthState build() {
    ref.onDispose(() => _tokenRefreshSub?.cancel());
    // When the API client detects the session is unrecoverable (refresh
    // token expired, revoked, or backend returns session_revoked), drop
    // straight to signedOut. The router redirect fires automatically.
    ref.read(apiClientProvider).onSessionEnded = _onSessionEnded;
    return const AuthState(AuthStage.unknown, null);
  }

  void _onSessionEnded() {
    // Runs on the interceptor's future — mutate state on the next tick to
    // avoid reassigning while a build may be in flight.
    Future.microtask(() async {
      state = const AuthState(AuthStage.signedOut, null);
      await _wipeLocalPhi();
    });
  }

  /// H2: no cached PHI survives the end of a session — chat cache, queued
  /// outbox entries, and persisted attachments. Best-effort: a failure here
  /// must never block sign-out.
  Future<void> _wipeLocalPhi() async {
    try {
      await ref.read(chatCacheProvider).clear();
    } catch (_) {}
    try {
      await ref.read(outboxProvider).clear();
    } catch (_) {}
    try {
      await ref.read(outboxMediaStoreProvider).deleteAll();
    } catch (_) {}
  }

  Future<void> bootstrap() async {
    final tokens = ref.read(tokenStorageProvider);
    final access = await tokens.accessToken;
    final refresh = await tokens.refreshToken;
    if ((access == null || access.isEmpty) &&
        (refresh == null || refresh.isEmpty)) {
      state = const AuthState(AuthStage.signedOut, null);
      return;
    }
    try {
      // `/users/me` goes through the Dio interceptor: if `access` is expired
      // but `refresh` is still valid, the interceptor silently refreshes and
      // the call succeeds. If both are dead, we'll catch below.
      final me = await ref.read(authRepositoryProvider).me();
      final registered = me.fullName.isNotEmpty && !me.npiNumber.startsWith('PENDING');
      if (!registered) {
        state = AuthState(AuthStage.needsRegistration, me);
        return;
      }
      state = AuthState(await _resolveStageForRegisteredUser(), me);
    } catch (_) {
      await tokens.clear();
      state = const AuthState(AuthStage.signedOut, null);
    }
  }

  /// For a fully-registered user, decide if they need onboarding (no orgs)
  /// or can go straight to chats. Also hydrates [orgProvider] as a side effect
  /// so downstream screens have the active org available.
  Future<AuthStage> _resolveStageForRegisteredUser() async {
    try {
      final orgs = await ref.read(orgRepositoryProvider).listMine();
      // No org is no longer a blocker: onboarding ends at the plan picker and
      // chats loads without one. Joining an org later comes back through here
      // and connects the socket then.
      if (orgs.isEmpty) return AuthStage.signedIn;
      // Pick the most recently created org as "current". Users with multiple
      // orgs can switch in a later release.
      final org = orgs.first;
      ref.read(orgProvider.notifier).setCurrent(org);
      final stage = switch (org.status) {
        OrgStatus.active => AuthStage.signedIn,
        OrgStatus.pending || OrgStatus.suspended => AuthStage.pendingVerification,
      };
      if (stage == AuthStage.signedIn) {
        await _connectWs(org.id);
        // Fire-and-forget: push registration must never block sign-in.
        unawaited(_syncPushToken());
      }
      return stage;
    } catch (_) {
      // If we can't reach the backend right now, assume needs-org so the user
      // isn't stuck on a broken chats screen.
      return AuthStage.needsOrg;
    }
  }

  /// Re-fetches `/orgs/mine` and flips auth stage between `pendingVerification`
  /// and `signedIn` based on the freshest org status. Called by the pending
  /// screen on its timer tick and on the "Check verification" button.
  Future<void> refreshOrgStatus() async {
    final user = state.user;
    if (user == null) return;
    final nextStage = await _resolveStageForRegisteredUser();
    state = AuthState(nextStage, user);
  }

  /// Open the realtime socket for the signed-in user's org. Drives instant
  /// message delivery, read receipts, and typing indicators.
  Future<void> _connectWs(String orgId) async {
    // Token is read per reconnect attempt, so a token refreshed by the Dio
    // interceptor is picked up automatically instead of fail-looping.
    await ref.read(websocketClientProvider).connect(
          orgId: orgId,
          tokenProvider: () => ref.read(tokenStorageProvider).accessToken,
        );
  }

  DevicePlatform get _devicePlatform =>
      Platform.isIOS ? DevicePlatform.ios : DevicePlatform.android;

  /// Register this device's push token (no-op while the provider is stubbed)
  /// and keep it registered across platform token rotations. Called after
  /// login and on every authed app start; the backend upsert is idempotent.
  Future<void> _syncPushToken() async {
    final provider = ref.read(pushTokenProviderProvider);
    try {
      final token = await provider.getToken();
      if (token != null && token.isNotEmpty) {
        await ref
            .read(userRepositoryProvider)
            .registerPushToken(token: token, platform: _devicePlatform);
      }
    } catch (_) {
      // Best-effort — retried on next app start / login.
    }
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = provider.onTokenRefresh.listen((token) async {
      try {
        await ref
            .read(userRepositoryProvider)
            .registerPushToken(token: token, platform: _devicePlatform);
      } catch (_) {}
    });
  }

  /// Start phone verification. Firebase sends the SMS; the returned challenge
  /// goes to the OTP screen and comes back to [confirmPhoneCode].
  Future<PhoneChallenge> startPhoneSignIn(String phone) =>
      ref.read(authBrokerProvider).startPhoneSignIn(phone);

  Future<void> confirmPhoneCode(PhoneChallenge challenge, String code) async {
    final idToken =
        await ref.read(authBrokerProvider).confirmPhoneCode(challenge, code);
    await _exchange(idToken);
  }

  /// Google / Facebook / Apple. A null token means the user dismissed the
  /// provider sheet — a normal outcome, so nothing changes and nothing throws.
  Future<void> signInWith(SocialProvider provider) async {
    final idToken = await ref.read(authBrokerProvider).signInWithSocial(provider);
    if (idToken == null) return;
    await _exchange(idToken);
  }

  /// The one place a Firebase ID token becomes a Doqto session. Every sign-in
  /// method funnels through here, so the stage machine has a single entry.
  Future<void> _exchange(String idToken) async {
    final pair = await ref.read(authRepositoryProvider).signInWithFirebase(idToken);
    final me = await ref.read(authRepositoryProvider).me();
    if (!pair.isRegistered) {
      state = AuthState(AuthStage.needsRegistration, me);
      return;
    }
    state = AuthState(await _resolveStageForRegisteredUser(), me);
  }

  Future<void> completeRegistration({
    required String fullName,
    String? specialty,
    required String npiNumber,
    String? city,
    // Named `practiceState` here: `state` is the notifier's own field.
    String? practiceState,
  }) async {
    var user = await ref.read(authRepositoryProvider).register(
          fullName: fullName,
          specialty: specialty,
          npiNumber: npiNumber,
        );
    // `register` has no city/state (and silently ignores extras), so the
    // practice location from the NPI registry goes on through the profile
    // endpoint. Best-effort: a registered user must never be bounced back to
    // the form because a location didn't save.
    if ((city ?? '').isNotEmpty || (practiceState ?? '').isNotEmpty) {
      try {
        user = await ref
            .read(userRepositoryProvider)
            .updateMe(UserPatchBody(city: city, state: practiceState));
      } catch (_) {}
    }
    // Details are in — next stop is the plan picker.
    state = AuthState(AuthStage.needsPayment, user);
  }

  /// Leaves the plan picker, whether they chose a plan or skipped. Nothing is
  /// charged or persisted yet — see docs/payments.md.
  Future<void> completePayment() async {
    final user = state.user;
    if (user == null) return;
    state = AuthState(await _resolveStageForRegisteredUser(), user);
  }

  /// Replace the cached user (e.g. after a profile update). Keeps the current
  /// auth stage — callers can't change auth stage via this method.
  void setUser(User user) {
    state = state.copyWith(user: user);
  }

  Future<void> signOut() async {
    // Best-effort: stop pushes to this device before the session dies. Must
    // run while the access token is still valid; never blocks sign-out.
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
    try {
      final token = await ref.read(pushTokenProviderProvider).getToken();
      if (token != null && token.isNotEmpty) {
        await ref.read(userRepositoryProvider).unregisterPushToken(token: token);
      }
    } catch (_) {}
    await ref.read(authRepositoryProvider).logout();
    await ref.read(websocketClientProvider).close();
    await _wipeLocalPhi();
    ref.read(orgProvider.notifier).clear();
    state = const AuthState(AuthStage.signedOut, null);
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
