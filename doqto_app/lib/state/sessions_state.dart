import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/models/session.dart';

/// Linked devices (batch 6): every live session of mine, newest activity
/// first, `current` on this device. Refetches when another device signs in
/// or a session is revoked (WS `session_created` / `session_revoked`).
/// Revoking is optimistic: the row goes at once and comes back on failure.
class SessionsNotifier extends AsyncNotifier<List<DeviceSession>> {
  @override
  Future<List<DeviceSession>> build() {
    final sub = ref.read(websocketClientProvider).events.listen((e) {
      if (e.type == WsEventServer.sessionCreated ||
          e.type == WsEventServer.sessionRevoked) {
        unawaited(refresh());
      }
    });
    ref.onDispose(sub.cancel);
    return ref.read(settingsRepositoryProvider).listSessions();
  }

  Future<void> refresh() async {
    try {
      state = AsyncData(await ref.read(settingsRepositoryProvider).listSessions());
    } catch (_) {
      // keep what we have
    }
  }

  Future<void> revoke(String id) async {
    final before = state.valueOrNull ?? const <DeviceSession>[];
    state = AsyncData([for (final s in before) if (s.id != id) s]);
    try {
      await ref.read(settingsRepositoryProvider).revokeSession(id);
    } catch (_) {
      state = AsyncData(before);
      rethrow;
    }
  }

  /// Signs out every other device; returns how many went.
  Future<int> revokeOthers() async {
    final before = state.valueOrNull ?? const <DeviceSession>[];
    state = AsyncData([for (final s in before) if (s.current) s]);
    try {
      return await ref.read(settingsRepositoryProvider).revokeOtherSessions();
    } catch (_) {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final sessionsProvider =
    AsyncNotifierProvider<SessionsNotifier, List<DeviceSession>>(SessionsNotifier.new);

/// "Just now" / "5 min ago" / "3 h ago" / "2 d ago" / date.
String formatLastActive(DateTime at, {DateTime? now}) {
  final ref = (now ?? DateTime.now()).toUtc();
  final d = ref.difference(at.toUtc());
  if (d.inMinutes < 1) return 'Active now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  final l = at.toLocal();
  return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')}/${l.year % 100}';
}
