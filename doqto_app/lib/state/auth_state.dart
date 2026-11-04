import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/models/user.dart';
import '../data/services/auth_broker.dart';
import '../data/services/push_token_provider.dart';
import '../data/repositories/user_repository.dart';
import 'org_state.dart';

enum AuthStage {
  unknown,
  signedOut,
  needsRegistration,
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

  /// Waits between push-registration attempts when no token is available yet
  /// or the API call fails. Tests shrink these.
  @visibleForTesting
  static List<Duration> pushRetryDelays = const [
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(minutes: 2),
  ];

  /// After a success, an app resume re-registers at most this often (keeps
  /// last_seen fresh and heals a row the server pruned).
  static const pushResyncInterval = Duration(hours: 6);

  DateTime? _pushSyncedAt;
  bool _pushSyncing = false;

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
    // Chat photos kept on the phone (and, in production, whatever older
    // builds cached by URL in the shared default cache).
    try {
      await ref.read(chatMediaCacheProvider).clear();
    } catch (_) {}
    // Chat documents kept on the phone.
    try {
      await ref.read(chatDocumentStoreProvider).clear();
    } catch (_) {}
    // Decoded bitmaps held in memory.
    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
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
    // Fire-and-forget: push registration must never block sign-in. It runs
    // for every registered doctor, org or not, and before the org lookup so a
    // failure there cannot skip it.
    unawaited(syncPushToken());
    try {
      final orgs = await ref.read(orgRepositoryProvider).listMine();
      // No org is no longer a blocker: onboarding ends at registration and
      // chats loads without one. The realtime socket is owned by
      // realtimeSessionProvider, keyed on the auth stage, so it is live here
      // too (it used to open only inside the org branch below).
      if (orgs.isEmpty) return AuthStage.signedIn;
      // An org adds to an account; it never gates it. A pending org (just
      // created, waiting for review) shows as pending on My Org, and chats
      // and connections keep working. Current org: the newest verified one,
      // else the newest pending one. Users with several orgs can switch in a
      // later release.
      final org = orgs.firstWhere(
        (o) => o.status == OrgStatus.active,
        orElse: () => orgs.firstWhere(
          (o) => o.status == OrgStatus.pending,
          orElse: () => orgs.first,
        ),
      );
      ref.read(orgProvider.notifier).setCurrent(org);
      return AuthStage.signedIn;
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
    // A sign-out (or another doctor signing in) while this was in flight
    // wins.
    if (state.user?.id != user.id || state.stage == AuthStage.signedOut) return;
    state = AuthState(nextStage, user);
  }

  DevicePlatform get _devicePlatform =>
      Platform.isIOS ? DevicePlatform.ios : DevicePlatform.android;

  /// Register this device's push token and keep it registered across
  /// platform token rotations. Runs after sign-in, on every authed app start,
  /// and on resume (see [onAppResumed]); the backend upsert is idempotent.
  ///
  /// A miss is retried on [pushRetryDelays]: on iOS the token is often not
  /// ready in the first seconds after launch. Errors are logged, never thrown.
  Future<void> syncPushToken() async {
    if (_pushSyncing) return;
    _pushSyncing = true;
    try {
      final PushTokenProvider provider;
      try {
        provider = ref.read(pushTokenProviderProvider);
      } catch (_) {
        return; // no Firebase binding (tests, a broken plugin)
      }
      final waits = [Duration.zero, ...pushRetryDelays];
      for (var i = 0; i < waits.length; i++) {
        if (waits[i] > Duration.zero) await Future<void>.delayed(waits[i]);
        if (state.stage == AuthStage.signedOut) return;
        try {
          final token = await provider.getToken();
          if (token != null && token.isNotEmpty) {
            await ref
                .read(userRepositoryProvider)
                .registerPushToken(token: token, platform: _devicePlatform);
            _pushSyncedAt = DateTime.now();
            break;
          }
          debugPrint('push: no device token yet (attempt ${i + 1})');
        } catch (e) {
          debugPrint('push: registration failed (attempt ${i + 1}): $e');
        }
      }
      await _tokenRefreshSub?.cancel();
      try {
        _tokenRefreshSub = provider.onTokenRefresh.listen((token) async {
          try {
            await ref
                .read(userRepositoryProvider)
                .registerPushToken(token: token, platform: _devicePlatform);
            _pushSyncedAt = DateTime.now();
          } catch (e) {
            debugPrint('push: re-registration after rotation failed: $e');
          }
        });
      } catch (_) {}
    } finally {
      _pushSyncing = false;
    }
  }

  /// App came to the foreground: if this device is not known to be
  /// registered (or it has been a while), register again. This is what heals
  /// a phone that missed registration, without waiting for a cold start.
  void onAppResumed() {
    if (state.user == null || state.stage == AuthStage.signedOut) return;
    if (state.stage == AuthStage.needsRegistration) return;
    final last = _pushSyncedAt;
    if (last != null && DateTime.now().difference(last) < pushResyncInterval) {
      return;
    }
    unawaited(syncPushToken());
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
    // Firebase keeps its own session; without this the next social tap would
    // silently reuse the old identity.
    try {
      await ref.read(authBrokerProvider).signOut();
    } catch (_) {}
    await _wipeLocalPhi();
    ref.read(orgProvider.notifier).clear();
    // realtimeSessionProvider closes the socket on this transition.
    state = const AuthState(AuthStage.signedOut, null);
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
