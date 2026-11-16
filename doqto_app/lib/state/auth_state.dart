import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/api/api_client.dart';
import '../data/models/user.dart';
import '../data/services/auth_broker.dart';
import '../data/services/push_token_provider.dart';
import '../data/repositories/user_repository.dart';
import 'org_state.dart';
import 'settings_state.dart';

enum AuthStage {
  unknown,
  signedOut,

  /// Batch 6: tokens issued, but this new device owes the two-step PIN.
  /// Every route but `/auth/pin/*` answers 403 until it is entered.
  pinRequired,
  needsRegistration,
  needsOrg,
  pendingVerification,
  signedIn,
}

class AuthState {
  final AuthStage stage;
  final User? user;

  /// When a forgot-PIN wait is running: the instant the PIN clears.
  final DateTime? pinClearsAt;
  const AuthState(this.stage, this.user, {this.pinClearsAt});

  AuthState copyWith({AuthStage? stage, User? user, DateTime? pinClearsAt}) =>
      AuthState(stage ?? this.stage, user ?? this.user,
          pinClearsAt: pinClearsAt ?? this.pinClearsAt);
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
    ref.read(apiClientProvider).onPinRequired = _onPinRequired;
    return const AuthState(AuthStage.unknown, null);
  }

  /// The server said this device still owes its PIN (a gate opened while we
  /// were signed in — the owner set a PIN on another device). Park on the
  /// gate without dropping the session.
  void _onPinRequired() {
    if (state.stage == AuthStage.pinRequired ||
        state.stage == AuthStage.signedOut) {
      return;
    }
    Future.microtask(() {
      if (state.stage == AuthStage.signedOut) return;
      state = AuthState(AuthStage.pinRequired, state.user);
    });
  }

  /// This device's linked-devices session id (null before batch 6 sign-ins).
  String? get sessionId {
    try {
      return ref.read(settingsStoreProvider).sessionId;
    } catch (_) {
      return null;
    }
  }

  Future<void> _rememberSession(String? sessionId) async {
    try {
      await ref.read(settingsStoreProvider).setSessionId(sessionId);
    } catch (_) {}
  }

  /// WS `session_revoked` for MY session: the server already refuses the
  /// tokens, so wipe and return to login at once (docs/settings.md).
  void onSessionRevokedEvent(String? revokedSessionId) {
    if (revokedSessionId == null || revokedSessionId != sessionId) return;
    unawaited(ref.read(tokenStorageProvider).clear());
    _onSessionEnded();
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
    } on ApiException catch (e) {
      if (e.status == 403 && e.detail == 'pin_required') {
        // Tokens are good; the device owes its PIN. Keep them.
        state = const AuthState(AuthStage.pinRequired, null);
        return;
      }
      await tokens.clear();
      state = const AuthState(AuthStage.signedOut, null);
    } catch (_) {
      await tokens.clear();
      state = const AuthState(AuthStage.signedOut, null);
    }
  }

  /// Two-step PIN gate (batch 6): verify for this session, then continue the
  /// normal sign-in resolution. Throws `pin_invalid` /
  /// `pin_too_many_attempts` as [ApiException].
  Future<void> verifyPin(String pin) async {
    await ref.read(settingsRepositoryProvider).verifyPin(pin);
    await _afterTokens();
  }

  /// Forgot PIN: start the 7-day wait. Returns when the PIN clears.
  Future<DateTime?> requestPinReset() async {
    final r = await ref.read(settingsRepositoryProvider).requestPinReset();
    state = state.copyWith(pinClearsAt: r.clearsAt);
    return r.clearsAt;
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
    Map<String, dynamic> device = const {};
    try {
      device = (await ref.read(deviceInfoProvider).describe()).toJson();
    } catch (_) {}
    final pair = await ref
        .read(authRepositoryProvider)
        .signInWithFirebase(idToken, device: device);
    await _rememberSession(pair.sessionId);
    if (pair.pinRequired) {
      // Nothing but /auth/pin/* works until the PIN is entered; /users/me
      // would 403. The gate screen calls [verifyPin].
      state = AuthState(AuthStage.pinRequired, null, pinClearsAt: pair.pinClearsAt);
      return;
    }
    await _afterTokens();
  }

  /// Tokens are usable: load me and resolve the stage.
  Future<void> _afterTokens() async {
    final me = await ref.read(authRepositoryProvider).me();
    final registered =
        me.fullName.isNotEmpty && !me.npiNumber.startsWith('PENDING');
    if (!registered) {
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
      // FCM can stall (simulators, no APNs); never let it hold sign-out.
      final token = await ref
          .read(pushTokenProviderProvider)
          .getToken()
          .timeout(const Duration(seconds: 3));
      if (token != null && token.isNotEmpty) {
        await ref
            .read(userRepositoryProvider)
            .unregisterPushToken(token: token)
            .timeout(const Duration(seconds: 5));
      }
    } catch (_) {}
    await ref.read(authRepositoryProvider).logout();
    // Firebase keeps its own session; without this the next social tap would
    // silently reuse the old identity.
    try {
      await ref.read(authBrokerProvider).signOut();
    } catch (_) {}
    await _wipeLocalPhi();
    await _rememberSession(null);
    ref.read(orgProvider.notifier).clear();
    // realtimeSessionProvider closes the socket on this transition.
    state = const AuthState(AuthStage.signedOut, null);
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
