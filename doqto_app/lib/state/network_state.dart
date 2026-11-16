import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/api/websocket_client.dart';
import '../data/models/network_profile.dart';
import '../data/repositories/network_repository.dart';
import 'auth_state.dart';
import 'org_state.dart';
import 'realtime_state.dart';

/// Self-loading, cached relationship+profile for one user, with optimistic
/// mutation methods that flip [RelationshipState] locally, call the repo, and
/// roll back on error. Family-keyed by userId so each profile screen owns its
/// own instance.
///
/// Live: the other party's actions reach us as socket events and flip the
/// button without a refetch (they invite → Accept/Ignore; they accept →
/// Message; they withdraw/remove → Connect). Local actions fan out to every
/// other provider that shows the same fact (inbox, sent list, connections,
/// suggestions) so no screen is stale when you navigate back to it.
class RelationshipNotifier extends FamilyAsyncNotifier<NetworkProfile, String> {
  /// Invitation id learned from a successful [invite] — lets [withdraw] skip a
  /// lookup. Null until we send one (or resolve it on demand).
  String? _invitationId;

  NetworkRepository get _repo => ref.read(networkRepositoryProvider);

  @override
  Future<NetworkProfile> build(String userId) async {
    final ws = ref.read(websocketClientProvider);
    final sub = ws.events.listen(_onEvent);
    ref.onDispose(sub.cancel);
    return _repo.getProfile(userId);
  }

  void _onEvent(WsEvent event) {
    switch (event.type) {
      case WsEventServer.invitationReceived:
        if (event.data['sender_id'] == arg) {
          applyRelationship(RelationshipState.pendingIncoming);
        }
      case WsEventServer.invitationAccepted:
        if (event.data['user_id'] == arg) {
          applyRelationship(RelationshipState.connected);
        }
      case WsEventServer.invitationWithdrawn:
        if (event.data['sender_id'] == arg) {
          applyRelationship(RelationshipState.none);
        }
      case WsEventServer.connectionRemoved:
        if (event.data['user_id'] == arg) {
          applyRelationship(RelationshipState.none);
        }
      case WsEventServer.profileUpdated:
        if (event.data['user_id'] == arg) refresh();
      default:
        break;
    }
  }

  /// Refetch the profile in place (no loading flash).
  Future<void> refresh() async {
    try {
      state = AsyncData(await _repo.getProfile(arg));
    } catch (_) {
      // Keep showing what we have.
    }
  }

  /// Apply a relationship state learned from elsewhere (a socket event, or a
  /// sibling provider that performed the mutation). No network call.
  void applyRelationship(RelationshipState next) {
    final profile = state.valueOrNull;
    if (profile == null) return;
    final rel = profile.relationship;
    if (rel.connectionState == next) return;
    final connected = next == RelationshipState.connected;
    state = AsyncData(profile.copyWith(
      relationship: rel.copyWith(
        connectionState: next,
        degree: connected
            ? ConnectionDegree.first
            : (rel.degree == ConnectionDegree.first
                ? ConnectionDegree.out
                : rel.degree),
        canMessage: connected
            ? CanMessage.open
            : (rel.isColleague ? rel.canMessage : CanMessage.denied),
      ),
    ));
    if (next == RelationshipState.none) _invitationId = null;
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

  /// blocked → none (optimistic; the server refuses nothing here except a
  /// network error, which rolls the profile back to Unblock). After an
  /// unblock the pair is NOT reconnected — the block tore the edge down.
  Future<void> unblock() async {
    final rel = state.value?.relationship;
    if (rel == null) return;
    await _mutate(
      rel.copyWith(connectionState: RelationshipState.none),
      () => _repo.unblock(arg),
    );
    if (ref.exists(blockedProvider)) {
      ref.read(blockedProvider.notifier).removeLocally(arg);
    }
    // The real relationship (colleague? discoverable?) is the server's call.
    refresh();
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
    ref.read(sentInvitationsProvider.notifier).refresh();
    ref.read(suggestionsProvider.notifier).removeUser(arg);
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
    // The request leaves the inbox (and the Network badge), the connections
    // list grows, and the suggestion card (if any) goes.
    ref.read(invitationsProvider.notifier).removeBySender(arg);
    ref.read(connectionsProvider.notifier).refresh();
    ref.read(suggestionsProvider.notifier).removeUser(arg);
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
    ref.read(invitationsProvider.notifier).removeBySender(arg);
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
    ref.read(sentInvitationsProvider.notifier).removeByRecipient(arg);
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

/// Patch a profile screen's relationship if (and only if) one is open for
/// [userId]. Never builds the provider — that would cost a profile fetch.
void _patchRelationship(Ref ref, String userId, RelationshipState next) {
  if (!ref.exists(relationshipProvider(userId))) return;
  ref.read(relationshipProvider(userId).notifier).applyRelationship(next);
}

/// The signed-in user's connections list. Cache-first (Hive) so a cold start
/// offline still paints; live-refreshes on connection_removed /
/// invitation_accepted (someone accepted → new connection) / profile_updated
/// (a connection changed name or photo) and on every reconnect.
class ConnectionsNotifier extends AsyncNotifier<List<PersonCard>> {
  @override
  Future<List<PersonCard>> build() async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        switch (event.type) {
          case WsEventServer.connectionRemoved:
            _removeLocally(event.data['user_id'] as String?);
            refresh();
          case WsEventServer.invitationAccepted:
          case WsEventServer.profileUpdated:
            refresh();
          default:
            break;
        }
      },
    );

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

  void _removeLocally(String? userId) {
    final list = state.valueOrNull;
    if (userId == null || list == null) return;
    state = AsyncData([for (final p in list) if (p.id != userId) p]);
  }

  /// Remove a connection: the row goes now, the server is told, and the
  /// person's profile (if open) flips back to Connect. Restores truth via
  /// [refresh] if the call fails.
  Future<void> remove(String userId) async {
    _removeLocally(userId);
    try {
      await ref.read(networkRepositoryProvider).removeConnection(userId);
      _patchRelationship(ref, userId, RelationshipState.none);
    } catch (e) {
      await refresh();
      rethrow;
    }
  }

  /// Block: same local effect as a removal (the server tears the edge down
  /// silently); the blocked person is also dropped from the inbox/sent lists
  /// and suggestions.
  Future<void> block(String userId) async {
    _removeLocally(userId);
    try {
      await ref.read(networkRepositoryProvider).block(userId);
      // The profile stays reachable for ME and now offers Unblock.
      _patchRelationship(ref, userId, RelationshipState.blocked);
      ref.read(invitationsProvider.notifier).removeBySender(userId);
      ref.read(sentInvitationsProvider.notifier).removeByRecipient(userId);
      ref.read(suggestionsProvider.notifier).removeUser(userId);
      if (ref.exists(blockedProvider)) {
        ref.read(blockedProvider.notifier).refresh();
      }
    } catch (e) {
      await refresh();
      rethrow;
    }
  }
}

final connectionsProvider =
    AsyncNotifierProvider<ConnectionsNotifier, List<PersonCard>>(
        ConnectionsNotifier.new);

/// The doctors I blocked (Settings → Privacy → Blocked contacts). Unblock is
/// optimistic: the row goes now, comes back if the server refuses, and the
/// person's profile (if open) flips from Unblock to Connect.
class BlockedNotifier extends AsyncNotifier<List<PersonCard>> {
  @override
  Future<List<PersonCard>> build() async {
    final page = await ref.read(networkRepositoryProvider).listBlocks();
    return page.data;
  }

  Future<void> refresh() async {
    try {
      final page = await ref.read(networkRepositoryProvider).listBlocks();
      state = AsyncData(page.data);
    } catch (_) {
      // Offline refresh: keep showing what we have.
    }
  }

  void removeLocally(String userId) {
    final list = state.valueOrNull;
    if (list == null) return;
    state = AsyncData([for (final p in list) if (p.id != userId) p]);
  }

  Future<void> unblock(String userId) async {
    final before = state.valueOrNull ?? const <PersonCard>[];
    state = AsyncData([for (final p in before) if (p.id != userId) p]);
    try {
      await ref.read(networkRepositoryProvider).unblock(userId);
      _patchRelationship(ref, userId, RelationshipState.none);
    } catch (e) {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final blockedProvider =
    AsyncNotifierProvider<BlockedNotifier, List<PersonCard>>(BlockedNotifier.new);

/// Received, still-pending invitations. Network-only (no cache — this is a
/// live inbox). Refreshes on invitation_received / invitation_accepted /
/// invitation_withdrawn (the sender changed their mind: the card goes at once).
class InvitationsNotifier extends AsyncNotifier<List<Invitation>> {
  @override
  Future<List<Invitation>> build() async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        switch (event.type) {
          case WsEventServer.invitationWithdrawn:
            _removeLocally(event.data['invitation_id'] as String?);
            refresh();
          case WsEventServer.invitationReceived:
          case WsEventServer.invitationAccepted:
            refresh();
          default:
            break;
        }
      },
    );

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

  void _removeLocally(String? invitationId) {
    final list = state.valueOrNull;
    if (invitationId == null || list == null) return;
    state = AsyncData(list.where((i) => i.id != invitationId).toList());
  }

  /// Drop every pending request from [userId] (accepted/ignored elsewhere,
  /// e.g. from their profile screen). No network call.
  void removeBySender(String userId) {
    final list = state.valueOrNull;
    if (list == null) return;
    final next = list.where((i) => i.sender?.id != userId).toList();
    if (next.length != list.length) state = AsyncData(next);
  }

  /// Optimistically drop the invitation, accept it server-side, and refresh the
  /// connections list. Restores truth (via [refresh]) if the call fails.
  Future<void> accept(Invitation inv) async {
    _removeLocally(inv.id);
    try {
      await ref.read(networkRepositoryProvider).acceptInvitation(inv.id);
      ref.read(connectionsProvider.notifier).refresh();
      final sender = inv.sender?.id;
      if (sender != null) {
        _patchRelationship(ref, sender, RelationshipState.connected);
        ref.read(suggestionsProvider.notifier).removeUser(sender);
      }
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
      final sender = inv.sender?.id;
      if (sender != null) _patchRelationship(ref, sender, RelationshipState.none);
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
/// invitations screen). Network-only; refreshes when a recipient accepts
/// (invitation_accepted) and on reconnect. Ignores are silent by design, so
/// an ignored request simply stays "Pending" here until it expires.
class SentInvitationsNotifier extends AsyncNotifier<List<Invitation>> {
  @override
  Future<List<Invitation>> build() async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        if (event.type == WsEventServer.invitationAccepted) {
          removeByRecipient(event.data['user_id'] as String?);
          refresh();
        }
      },
    );
    final page = await ref
        .read(networkRepositoryProvider)
        .listInvitations(direction: 'sent', status: 'pending');
    return page.data;
  }

  Future<void> refresh() async {
    try {
      final page = await ref
          .read(networkRepositoryProvider)
          .listInvitations(direction: 'sent', status: 'pending');
      state = AsyncData(page.data);
    } catch (_) {
      // Keep showing what we have.
    }
  }

  /// Drop the pending request to [userId] (withdrawn/accepted elsewhere).
  void removeByRecipient(String? userId) {
    final list = state.valueOrNull;
    if (userId == null || list == null) return;
    final next = list.where((i) => i.recipient?.id != userId).toList();
    if (next.length != list.length) state = AsyncData(next);
  }

  /// Send a request from a row that has no profile loaded (search,
  /// suggestions): the sent list and suggestions update, and the person's
  /// profile (if open) flips to Pending. Throws on failure for the row's
  /// rollback + haptic.
  Future<void> send(String userId) async {
    await ref.read(networkRepositoryProvider).sendInvitation(userId);
    _patchRelationship(ref, userId, RelationshipState.pendingOutgoing);
    ref.read(suggestionsProvider.notifier).removeUser(userId);
    await refresh();
  }

  /// Optimistically drop the row, withdraw server-side, flip the person's
  /// profile (if open) back to Connect. Restores truth if the call fails.
  Future<void> withdraw(Invitation inv) async {
    final list = state.valueOrNull;
    if (list != null) {
      state = AsyncData(list.where((i) => i.id != inv.id).toList());
    }
    try {
      await ref.read(networkRepositoryProvider).withdrawInvitation(inv.id);
      final recipient = inv.recipient?.id;
      if (recipient != null) {
        _patchRelationship(ref, recipient, RelationshipState.none);
      }
    } catch (e) {
      await refresh();
      rethrow;
    }
  }
}

final sentInvitationsProvider =
    AsyncNotifierProvider<SentInvitationsNotifier, List<Invitation>>(
        SentInvitationsNotifier.new);

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
/// up to 50 serves both the Network tab preview and the See all screen. A
/// card leaves the moment a request exists either way (sent or received) or
/// a connection forms; the list refetches on reconnect.
class SuggestionsNotifier extends AsyncNotifier<List<PersonCard>> {
  static const limit = 50;

  @override
  Future<List<PersonCard>> build() async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, _) {
        switch (event.type) {
          case WsEventServer.invitationReceived:
            removeUser(event.data['sender_id'] as String?);
          case WsEventServer.invitationAccepted:
            removeUser(event.data['user_id'] as String?);
          default:
            break;
        }
      },
    );
    return _fetch();
  }

  Future<List<PersonCard>> _fetch() async =>
      (await ref.read(networkRepositoryProvider).suggestions(limit: limit)).data;

  Future<void> refresh() async {
    try {
      state = AsyncData(await _fetch()); // in place — no flash
    } catch (e, st) {
      if (state.valueOrNull == null) state = AsyncError(e, st);
    }
  }

  /// Drop a card without telling the server (a request or connection now
  /// exists, so the server won't suggest them again anyway).
  void removeUser(String? userId) {
    final list = state.valueOrNull;
    if (userId == null || list == null) return;
    final next = [for (final p in list) if (p.id != userId) p];
    if (next.length != list.length) state = AsyncData(next);
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


/// People I muted (M1 `mutes`, surfaced in batch 3): no pushes (server) and
/// no in-app banners (notification_state) from them. Optimistic with rollback.
class MutedUsersNotifier extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async =>
      (await ref.read(networkRepositoryProvider).listMutes()).toSet();

  bool isMuted(String userId) => state.value?.contains(userId) ?? false;

  Future<void> setMuted(String userId, bool muted) async {
    final before = state.value ?? <String>{};
    final next = {...before};
    if (muted) {
      next.add(userId);
    } else {
      next.remove(userId);
    }
    state = AsyncData(next);
    try {
      final repo = ref.read(networkRepositoryProvider);
      if (muted) {
        await repo.mute(userId);
      } else {
        await repo.unmute(userId);
      }
    } catch (_) {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final mutedUsersProvider =
    AsyncNotifierProvider<MutedUsersNotifier, Set<String>>(MutedUsersNotifier.new);
