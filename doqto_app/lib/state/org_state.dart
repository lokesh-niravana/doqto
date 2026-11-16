import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/models/organization.dart';
import 'auth_state.dart';
import 'realtime_state.dart';

class OrgState {
  final Organization? current;
  final bool loading;
  final String? error;
  const OrgState({this.current, this.loading = false, this.error});

  OrgState copyWith({Organization? current, bool? loading, String? error}) =>
      OrgState(current: current ?? this.current, loading: loading ?? this.loading, error: error);
}

/// The doctor's current organization. Listens for `org_updated` so a
/// verification decision (or being added to / removed from an org) reaches
/// the app the moment it happens: the auth stage is re-resolved, which is what
/// used to need a 15 s poll on the pending screen.
class OrgNotifier extends Notifier<OrgState> {
  @override
  OrgState build() {
    final sub = ref.read(websocketClientProvider).events.listen((event) {
      if (event.type != WsEventServer.orgUpdated) return;
      final orgId = event.data['org_id'] as String?;
      final status = event.data['status'] as String?;
      final current = state.current;
      // Unknown org (we were just added) or a status change on ours: let
      // auth re-resolve the stage from /orgs/mine.
      final relevant = current == null ||
          current.id != orgId ||
          (status != null && status != current.status.wire);
      if (relevant) ref.read(authProvider.notifier).refreshOrgStatus();
    });
    ref.onDispose(sub.cancel);
    return const OrgState();
  }

  void setCurrent(Organization org) {
    state = OrgState(current: org);
  }

  void clear() {
    state = const OrgState();
  }

  Future<Organization> createOrg({
    required String name,
    String? address,
    String? city,
    String? state,
    PracticeType? practiceType,
    DirectoryEntry? from,
  }) async {
    this.state = this.state.copyWith(loading: true, error: null);
    try {
      final org = await ref.read(orgRepositoryProvider).create(
            name: name,
            address: address,
            city: city,
            state: state,
            practiceType: practiceType,
            from: from,
          );
      this.state = OrgState(current: org);
      return org;
    } catch (e) {
      this.state = this.state.copyWith(loading: false, error: e.toString());
      rethrow;
    }
  }

  Future<Organization> joinOrg(String code) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final org = await ref.read(orgRepositoryProvider).join(code);
      state = OrgState(current: org);
      return org;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      rethrow;
    }
  }

  Future<Organization> joinByDirectory(DirectoryEntry entry) async {
    final org = await ref.read(orgRepositoryProvider).joinByDirectory(entry);
    state = OrgState(current: org);
    return org;
  }

  Future<void> refreshMembers() async {
    final org = state.current;
    if (org == null) return;
    await ref.read(orgRepositoryProvider).members(org.id);
  }
}

final orgProvider = NotifierProvider<OrgNotifier, OrgState>(OrgNotifier.new);

/// Members of one organization. Refetches in place when the org changes
/// (someone joined or was removed), when a colleague edits their profile,
/// and on reconnect.
class OrgMembersNotifier extends FamilyAsyncNotifier<List<OrgMember>, String> {
  @override
  Future<List<OrgMember>> build(String orgId) async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        switch (event.type) {
          case WsEventServer.orgUpdated:
            if (event.data['org_id'] == orgId) refresh();
          case WsEventServer.profileUpdated:
            refresh();
          default:
            break;
        }
      },
    );
    return ref.read(orgRepositoryProvider).members(orgId);
  }

  Future<void> refresh() async {
    try {
      state = AsyncData(await ref.read(orgRepositoryProvider).members(arg));
    } catch (_) {
      // Keep showing what we have.
    }
  }
}

final orgMembersProvider =
    AsyncNotifierProvider.family<OrgMembersNotifier, List<OrgMember>, String>(
        OrgMembersNotifier.new);
