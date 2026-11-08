import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/models/compliance.dart';
import '../data/models/organization.dart';
import 'auth_state.dart';
import 'org_state.dart';
import 'realtime_state.dart';

/// The one source of truth for an org's policies (batch 7). Fetched from
/// `GET /orgs/{id}/policies`, refetched on every `org_updated` for that org
/// and on reconnect, so a policy an admin flips reaches every member's
/// device without a restart. Changes are optimistic with rollback.
class OrgPoliciesNotifier extends FamilyAsyncNotifier<OrgPolicies, String> {
  @override
  Future<OrgPolicies> build(String orgId) async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        if (event.type == WsEventServer.orgUpdated && event.data['org_id'] == orgId) {
          refresh();
        }
      },
    );
    return ref.read(complianceRepositoryProvider).policies(orgId);
  }

  Future<void> refresh() async {
    try {
      state = AsyncData(await ref.read(complianceRepositoryProvider).policies(arg));
    } catch (_) {
      // Keep what we have.
    }
  }

  /// Apply [patch] (wire keys) at once, confirm with the server, roll back
  /// on failure. Rethrows so the screen can toast.
  Future<void> change(Map<String, dynamic> patch) async {
    final current = state.valueOrNull ??
        ref.read(orgProvider).current?.policies ??
        OrgPolicies.defaults;
    state = AsyncData(current.apply(patch));
    try {
      final confirmed =
          await ref.read(complianceRepositoryProvider).patchPolicies(arg, patch);
      state = AsyncData(confirmed);
    } catch (_) {
      state = AsyncData(current);
      rethrow;
    }
  }
}

final orgPoliciesProvider =
    AsyncNotifierProvider.family<OrgPoliciesNotifier, OrgPolicies, String>(
        OrgPoliciesNotifier.new);

/// Policies of my current org as the app should enforce them right now:
/// the live provider's value, else the snapshot the org payload carried,
/// else the defaults (no org = nothing restricted).
final currentOrgPoliciesProvider = Provider<OrgPolicies>((ref) {
  final org = ref.watch(orgProvider).current;
  if (org == null) return OrgPolicies.defaults;
  return ref.watch(orgPoliciesProvider(org.id)).asData?.value ?? org.policies;
});

/// Am I an admin of my current org? Derived from the members list (the org
/// payload carries no role), false while it loads.
final isOrgAdminProvider = Provider<bool>((ref) {
  final org = ref.watch(orgProvider).current;
  final me = ref.watch(authProvider).user;
  if (org == null || me == null) return false;
  final members = ref.watch(orgMembersProvider(org.id)).asData?.value;
  if (members == null) return false;
  return members.any((m) => m.id == me.id && m.orgRole == OrgRole.admin);
});

/// Break-glass requests of one org (admins only). Refetched on
/// `access_request_updated` for the org and on reconnect; decisions patch
/// the row in place and are confirmed by the server's answer.
class AccessRequestsNotifier
    extends FamilyAsyncNotifier<List<AccessRequest>, String> {
  @override
  Future<List<AccessRequest>> build(String orgId) async {
    listenRealtime(
      ref,
      refresh: refresh,
      onEvent: (event, refresh) {
        if (event.type == WsEventServer.accessRequestUpdated &&
            event.data['org_id'] == orgId) {
          refresh();
        }
      },
    );
    return ref.read(complianceRepositoryProvider).accessRequests(orgId);
  }

  Future<void> refresh() async {
    try {
      state = AsyncData(
          await ref.read(complianceRepositoryProvider).accessRequests(arg));
    } catch (_) {}
  }

  Future<AccessRequest> create({
    required String conversationId,
    required String reason,
  }) async {
    final created = await ref.read(complianceRepositoryProvider).createAccessRequest(
          arg,
          conversationId: conversationId,
          reason: reason,
        );
    state = AsyncData([created, ...(state.valueOrNull ?? const [])]);
    return created;
  }

  Future<void> decide(String requestId, {required bool approve}) async {
    final before = state.valueOrNull ?? const <AccessRequest>[];
    final optimistic = approve ? AccessRequestStatus.approved : AccessRequestStatus.rejected;
    state = AsyncData([
      for (final r in before) r.id == requestId ? r.copyWith(status: optimistic) : r,
    ]);
    try {
      final repo = ref.read(complianceRepositoryProvider);
      final confirmed = approve
          ? await repo.approveAccessRequest(arg, requestId)
          : await repo.rejectAccessRequest(arg, requestId);
      state = AsyncData([
        for (final r in state.valueOrNull ?? before) r.id == requestId ? confirmed : r,
      ]);
    } catch (_) {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final accessRequestsProvider = AsyncNotifierProvider.family<
    AccessRequestsNotifier, List<AccessRequest>, String>(AccessRequestsNotifier.new);

/// Reports in the org's moderation scope (admins only), every status; the
/// screen filters with chips. Status changes are optimistic with rollback.
class OrgReportsNotifier extends FamilyAsyncNotifier<List<OrgReport>, String> {
  @override
  Future<List<OrgReport>> build(String orgId) async {
    listenRealtime(ref, refresh: refresh, onEvent: (_, _) {});
    return ref.read(complianceRepositoryProvider).reports(orgId);
  }

  Future<void> refresh() async {
    try {
      state = AsyncData(await ref.read(complianceRepositoryProvider).reports(arg));
    } catch (_) {}
  }

  Future<void> setStatus(String reportId, ReportStatus status) async {
    final before = state.valueOrNull ?? const <OrgReport>[];
    state = AsyncData([
      for (final r in before) r.id == reportId ? r.copyWith(status: status) : r,
    ]);
    try {
      final confirmed = await ref
          .read(complianceRepositoryProvider)
          .setReportStatus(arg, reportId, status);
      state = AsyncData([
        for (final r in state.valueOrNull ?? before) r.id == reportId ? confirmed : r,
      ]);
    } catch (_) {
      state = AsyncData(before);
      rethrow;
    }
  }
}

final orgReportsProvider =
    AsyncNotifierProvider.family<OrgReportsNotifier, List<OrgReport>, String>(
        OrgReportsNotifier.new);
