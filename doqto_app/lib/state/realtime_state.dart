import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/api/websocket_client.dart';
import 'auth_state.dart';

/// How long event-triggered list refreshes wait to coalesce a burst (a group
/// join fires a system message AND a member event; a reconnect replays
/// several). Overridden to zero in tests.
final realtimeRefreshDebounceProvider =
    Provider<Duration>((_) => const Duration(milliseconds: 300));

/// Coalesces repeated triggers into one [action] call per quiet window.
/// With a zero delay the action still runs asynchronously (next microtask),
/// never re-entrantly inside the trigger.
class RefreshCoalescer {
  RefreshCoalescer(this.delay, this.action);

  final Duration delay;
  final FutureOr<void> Function() action;
  Timer? _timer;

  void call() {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      action();
    });
  }

  void dispose() => _timer?.cancel();
}

/// Subscribes [onEvent] to the socket and a coalesced [refresh] to every
/// reconnect, tied to [ref]'s lifetime. Returns the coalescer so the notifier
/// can also trigger it from its own event handler.
RefreshCoalescer listenRealtime(
  Ref ref, {
  required void Function(WsEvent event, RefreshCoalescer refresh) onEvent,
  required FutureOr<void> Function() refresh,
}) {
  final ws = ref.read(websocketClientProvider);
  final coalescer =
      RefreshCoalescer(ref.read(realtimeRefreshDebounceProvider), refresh);
  final sub = ws.events.listen((e) => onEvent(e, coalescer));
  // Gap recovery: a (re)connect means events may have been missed — refetch.
  final stateSub = ws.states.listen((s) {
    if (s == WsConnState.connected) coalescer();
  });
  ref.onDispose(() {
    sub.cancel();
    stateSub.cancel();
    coalescer.dispose();
  });
  return coalescer;
}

/// Auth stages that carry a usable session. An org is NOT required: direct
/// messages and the networking graph work without one, and a doctor waiting
/// on org verification still receives invitations, messages and the
/// `org_updated` event that ends the wait.
bool wantsRealtimeSocket(AuthState s) =>
    s.user != null &&
    (s.stage == AuthStage.signedIn ||
        s.stage == AuthStage.needsOrg ||
        s.stage == AuthStage.pendingVerification);

/// Owns the socket's lifetime: open whenever a session exists, closed on
/// sign-out. Activated once by watching it from the root widget. This is the
/// ONLY place that opens the socket — auth no longer does, which is how
/// org-less users used to end up with no realtime at all.
final realtimeSessionProvider = Provider<void>((ref) {
  final ws = ref.watch(websocketClientProvider);
  final api = ref.watch(apiClientProvider);

  // Linked devices (batch 6): a revoke of THIS session ends it immediately.
  final revokeSub = ws.events.listen((e) {
    if (e.type != WsEventServer.sessionRevoked) return;
    ref
        .read(authProvider.notifier)
        .onSessionRevokedEvent(e.data['session_id'] as String?);
  });
  ref.onDispose(revokeSub.cancel);

  void apply(AuthState auth) {
    if (wantsRealtimeSocket(auth)) {
      // Token read per (re)connect, refreshed first if it is about to expire.
      unawaited(ws.connect(tokenProvider: api.freshAccessToken));
    } else if (auth.stage == AuthStage.signedOut) {
      unawaited(ws.close());
    }
  }

  ref.listen<AuthState>(authProvider, (_, next) => apply(next),
      fireImmediately: true);
});
