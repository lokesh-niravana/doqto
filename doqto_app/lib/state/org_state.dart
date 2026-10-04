import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/models/organization.dart';

class OrgState {
  final Organization? current;
  final bool loading;
  final String? error;
  const OrgState({this.current, this.loading = false, this.error});

  OrgState copyWith({Organization? current, bool? loading, String? error}) =>
      OrgState(current: current ?? this.current, loading: loading ?? this.loading, error: error);
}

class OrgNotifier extends Notifier<OrgState> {
  @override
  OrgState build() => const OrgState();

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

final orgMembersProvider = FutureProvider.family((ref, String orgId) async {
  return ref.read(orgRepositoryProvider).members(orgId);
});
