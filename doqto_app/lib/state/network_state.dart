import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/api/websocket_client.dart';
import '../data/models/network_profile.dart';
import '../data/repositories/network_repository.dart';
import 'auth_state.dart';
import 'org_state.dart';

/// Self-loading, cached relationship+profile for one user, with optimistic
/// mutation methods that flip [RelationshipState] locally, call the repo, and
/// roll back on error. Family-keyed by userId so each profile screen owns its
/// own instance.
class RelationshipNotifier extends FamilyAsyncNotifier<NetworkProfile, String> {
  /// Invitation id learned from a successful [invite] — lets [withdraw] skip a
  /// lookup. Null until we send one (or resolve it on demand).
  String? _invitationId;

  NetworkRepository get _repo => ref.read(networkRepositoryProvider);

  @override
  Future<NetworkProfile> build(String userId) async {
    return _repo.getProfile(userId);
  }

  /// Optimistically apply a new relationship, run [action], and roll back to the
  /// previous relationship if it throws (so the button can re-flip + haptic).
  Future<void> _mutate(
    Relationship optimistic,
    Future<void> Function() action,
  ) async {
    final profile = state.value;
    if (profile == null) return;
    final previous = profile.relationship;
    state = AsyncData(profile.copyWith(relationship: optimistic));
    try {
      await action();
    } catch (e) {
      // Roll back to the pre-mutation relationship, then rethrow so the caller
      // (ConnectButton / screen) can surface the error + error haptic.
      final now = state.value ?? profile;
      state = AsyncData(now.copyWith(relationship: previous));
      rethrow;
    }
  }

  /// none → pending_outgoing.
  Future<void> invite({String? message}) async {
    final rel = state.value?.relationship;
    if (rel == null) return;
    await _mutate(
      rel.copyWith(connectionState: RelationshipState.pendingOutgoing),
      () async {
        final inv = await _repo.sendInvitation(arg, message: message);
        _invitationId = inv.id;
      },
    );
  }

  /// pending_incoming → connected. Resolves the invitation id from the received
  /// pending list (the profile payload doesn't carry it).
  Future<void> accept() async {
    final rel = state.value?.relationship;
    if (rel == null) return;
    await _mutate(
      rel.copyWith(
        connectionState: RelationshipState.connected,
        degree: ConnectionDegree.first,
        canMessage: CanMessage.open,
      ),
      () async {
        final id = await _resolveInvitationId(direction: 'received');
        if (id == null) throw StateError('invitation_not_found');
        await _repo.acceptInvitation(id);
      },
    );
    // A new connection changes the connections list — refresh it.
    ref.invalidate(connectionsProvider);
  }

  /// pending_incoming → none (silent to sender).
  Future<void> ignore() async {
    final rel = state.value?.relationship;
    if (rel == null) return;
    await _mutate(
      rel.copyWith(connectionState: RelationshipState.none),
      () async {
        final id = await _resolveInvitationId(direction: 'received');
        if (id == null) throw StateError('invitation_not_found');
        await _repo.ignoreInvitation(id);
      },
    );
  }

  /// pending_outgoing → none.
  Future<void> withdraw() async {
    final rel = state.value?.relationship;
    if (rel == null) return;
    await _mutate(
      rel.copyWith(connectionState: RelationshipState.none),
      () async {
        final id = _invitationId ?? await _resolveInvitationId(direction: 'sent');
        if (id == null) throw StateError('invitation_not_found');
        await _repo.withdrawInvitation(id);
        _invitationId = null;
      },
    );
  }

  Future<String?> _resolveInvitationId({required String direction}) async {
    final page = await _repo.listInvitations(direction: direction, status: 'pending');
    for (final inv in page.data) {
      final party = direction == 'received' ? inv.sender : inv.recipient;
      if (party?.id == arg) return inv.id;
    }
    return null;
  }
}

final relationshipProvider =
    AsyncNotifierProvider.family<RelationshipNotifier, NetworkProfile, String>(
        RelationshipNotifier.new);

/// The signed-in user's connections list. Cache-first (Hive) so a cold start
/// offline still paints; live-refreshes on connection_removed /
/// invitation_accepted WS events (someone accepted → new connection).
class ConnectionsNotifier extends AsyncNotifier<List<PersonCard>> {
  @override
  Future<List<PersonCard>> build() async {
    final ws = ref.read(websocketClientProvider);
    final sub = ws.events.listen((event) {
      if (event.type == WsEventServer.connectionRemoved ||
          event.type == WsEventServer.invitationAccepted) {
        refresh();
      }
    });
    // Gap recovery: a reconnect means events were missed — refetch.
    final stateSub = ws.states.listen((s) {
      if (s == WsConnState.connected) refresh();
    });
    ref.onDispose(sub.cancel);
    ref.onDispose(stateSub.cancel);

    final cache = ref.read(networkCacheProvider);
    final cached = cache.connections();
    if (cached != null) state = AsyncData(cached); // instant paint offline
    try {
      final page = await ref.read(networkRepositoryProvider).listConnections();
      await cache.putConnections(page.data);
      return page.data;
    } catch (_) {
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<void> refresh() async {
    try {
      final page = await ref.read(networkRepositoryProvider).listConnections();
      await ref.read(networkCacheProvider).putConnections(page.data);
      state = AsyncData(page.data); // stays on previous data → no flash
    } catch (_) {
      // Offline refresh: keep showing what we have.
    }
  }
}

final connectionsProvider =
    AsyncNotifierProvider<ConnectionsNotifier, List<PersonCard>>(
        ConnectionsNotifier.new);

/// Received, still-pending invitations. Network-only (no cache — this is a
/// live inbox). Refreshes on invitation_received / invitation_accepted.
class InvitationsNotifier extends AsyncNotifier<List<Invitation>> {
  @override
  Future<List<Invitation>> build() async {
    final ws = ref.read(websocketClientProvider);
    final sub = ws.events.listen((event) {
      if (event.type == WsEventServer.invitationReceived ||
          event.type == WsEventServer.invitationAccepted) {
        refresh();
      }
    });
    final stateSub = ws.states.listen((s) {
      if (s == WsConnState.connected) refresh();
    });
    ref.onDispose(sub.cancel);
    ref.onDispose(stateSub.cancel);

    final page = await ref
        .read(networkRepositoryProvider)
        .listInvitations(direction: 'received', status: 'pending');
    return page.data;
  }

  Future<void> refresh() async {
    try {
      final page = await ref
          .read(networkRepositoryProvider)
          .listInvitations(direction: 'received', status: 'pending');
      state = AsyncData(page.data);
    } catch (_) {
      // Keep showing what we have.
    }
  }

  void _removeLocally(String invitationId) {
    final list = state.valueOrNull;
    if (list == null) return;
    state = AsyncData(list.where((i) => i.id != invitationId).toList());
  }

  /// Optimistically drop the invitation, accept it server-side, and refresh the
  /// connections list. Restores truth (via [refresh]) if the call fails.
  Future<void> accept(Invitation inv) async {
    _removeLocally(inv.id);
    try {
      await ref.read(networkRepositoryProvider).acceptInvitation(inv.id);
      ref.invalidate(connectionsProvider);
    } catch (e) {
      await refresh();
      rethrow;
    }
  }

  /// Optimistically drop the invitation and ignore it server-side (silent to
  /// the sender). No undo, per plan. Restores truth if the call fails.
  Future<void> ignore(Invitation inv) async {
    _removeLocally(inv.id);
    try {
      await ref.read(networkRepositoryProvider).ignoreInvitation(inv.id);
    } catch (e) {
      await refresh();
      rethrow;
    }
  }
}

final invitationsProvider =
    AsyncNotifierProvider<InvitationsNotifier, List<Invitation>>(
        InvitationsNotifier.new);

/// The signed-in user's still-pending *sent* invitations (the "Sent" tab of the
/// invitations screen). Network-only, auto-disposed — refetched each time the
/// screen mounts; invalidated after a withdraw.
final sentInvitationsProvider =
    FutureProvider.autoDispose<List<Invitation>>((ref) async {
  final page = await ref
      .read(networkRepositoryProvider)
      .listInvitations(direction: 'sent', status: 'pending');
  return page.data;
});

/// Everyone the signed-in doctor can put in a group: their connections PLUS
/// every colleague in their organization, deduped by id and name-sorted.
///
/// Colleagues belong here even without a connection — you already share an
/// organization, which is exactly why "no connections yet" was the wrong
/// answer on the invite step. Org members are best-effort: no org, or a failed
/// fetch, still leaves the connections list usable.
final invitablePeopleProvider =
    FutureProvider.autoDispose<List<PersonCard>>((ref) async {
  final connections = await ref.watch(connectionsProvider.future);
  final byId = {for (final p in connections) p.id: p};

  final me = ref.watch(authProvider).user?.id;
  final orgId = ref.watch(orgProvider).current?.id;
  if (orgId != null) {
    try {
      final members = await ref.watch(orgMembersProvider(orgId).future);
      for (final m in members) {
        if (m.id == me || byId.containsKey(m.id)) continue;
        byId[m.id] = PersonCard(
          id: m.id,
          fullName: m.fullName,
          headline: null,
          specialty: m.specialty,
          locationLabel: null,
          avatarColor: m.avatarColor,
          avatarUrl: m.avatarUrl,
          avatarPresignedUrl: m.avatarPresignedUrl,
          // A colleague need not be connected; `out` just means "no edge yet".
          degree: ConnectionDegree.out,
          mutualCount: 0,
        );
      }
    } catch (_) {
      // Colleagues are an addition, never a precondition.
    }
  }

  final all = byId.values.toList()
    ..sort((a, b) => a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
  return all;
});

/// "Recommended for you": doctors you probably know, best first. One fetch of
/// up to 50 serves both the Network tab preview and the See all screen.
class SuggestionsNotifier extends AsyncNotifier<List<PersonCard>> {
  static const limit = 50;

  @override
  Future<List<PersonCard>> build() async =>
      (await ref.read(networkRepositoryProvider).suggestions(limit: limit)).data;

  Future<void> refresh() async {
    state = await AsyncValue.guard(build);
  }

  /// Hide for good. Optimistic: the card goes now, and comes back if the
  /// server refuses.
  Future<void> dismiss(String userId) async {
    final before = state.value ?? const <PersonCard>[];
    state = AsyncData([for (final p in before) if (p.id != userId) p]);
    try {
      await ref.read(networkRepositoryProvider).dismissSuggestion(userId);
    } catch (_) {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final suggestionsProvider =
    AsyncNotifierProvider<SuggestionsNotifier, List<PersonCard>>(
        SuggestionsNotifier.new);
