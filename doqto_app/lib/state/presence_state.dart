import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/models/presence.dart';
import '../data/repositories/user_repository.dart';
import 'realtime_state.dart';

/// Presence + last seen of the doctors on screen (batch 2).
///
/// Screens call [track] with the peers they render; the notifier fetches
/// their snapshot once, then keeps it live from `presence_update` frames.
/// Everything tracked is refetched on reconnect (gap recovery) and when the
/// app resumes (main.dart) — a locked phone misses frames. What the server
/// hands back is already filtered by the other doctor's privacy settings, so
/// this layer never decides who may see what.
class PresenceNotifier extends Notifier<Map<String, PresenceInfo>> {
  final _tracked = <String>{};
  Future<void>? _inFlight;

  @override
  Map<String, PresenceInfo> build() {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, _) {
        if (event.type == WsEventServer.presenceUpdate) _apply(event.data);
      },
    );
    return const {};
  }

  /// Start following these doctors; fetches anyone not seen yet.
  Future<void> track(Iterable<String> ids) async {
    final fresh = <String>[];
    for (final id in ids) {
      if (id.isEmpty) continue;
      if (_tracked.add(id)) fresh.add(id);
    }
    if (fresh.isEmpty) return;
    await _fetch(fresh);
  }

  /// Refetch everyone tracked — reconnect, resume, pull-to-refresh.
  Future<void> refresh() async {
    if (_tracked.isEmpty) return;
    // Most recently tracked first, capped at what one call may carry.
    final ids = _tracked.toList().reversed.take(UserRepository.presenceMaxIds).toList();
    await _fetch(ids);
  }

  Future<void> _fetch(List<String> ids) async {
    // One request at a time: a burst of screens opening collapses into the
    // next call rather than racing stale snapshots over fresh frames.
    while (_inFlight != null) {
      await _inFlight;
    }
    final run = _doFetch(ids);
    _inFlight = run;
    try {
      await run;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _doFetch(List<String> ids) async {
    try {
      final rows = await ref.read(userRepositoryProvider).fetchPresence(ids);
      final next = Map<String, PresenceInfo>.of(state);
      for (final row in rows) {
        next[row.userId] = row;
      }
      state = next;
    } catch (_) {
      // Offline or rate-limited: keep what we have; the next trigger retries.
    }
  }

  void _apply(Map<String, dynamic> data) {
    final id = data['user_id'] as String?;
    if (id == null) return;
    final incoming = PresenceInfo.fromJson(data);
    final prev = state[id];
    // An `online` frame carries no last_seen_at; keep the one we had so the
    // header can fall back to it the moment they go away again.
    final merged = PresenceInfo(
      userId: id,
      status: incoming.status,
      lastSeenAt: incoming.lastSeenAt ?? prev?.lastSeenAt,
    );
    state = {...state, id: merged};
  }
}

final presenceProvider =
    NotifierProvider<PresenceNotifier, Map<String, PresenceInfo>>(
        PresenceNotifier.new);

/// One doctor's presence, or null when nothing is known (not tracked yet, or
/// hidden from me — the two look the same by design).
final presenceOfProvider = Provider.family<PresenceInfo?, String>(
  (ref, userId) => ref.watch(presenceProvider.select((m) => m[userId])),
);
