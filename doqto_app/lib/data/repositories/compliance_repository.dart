import '../../core/constants/api_routes.dart';
import '../api/api_client.dart';
import '../models/compliance.dart';
import '../models/message.dart';
import '../models/organization.dart';

/// Batch 7 wire calls: org policies, break-glass access requests, the org
/// moderation queue and my scheduled messages. See docs/compliance.md.
class ComplianceRepository {
  final ApiClient _api;
  ComplianceRepository(this._api);

  // ---- Policies -----------------------------------------------------------

  Future<OrgPolicies> policies(String orgId) async =>
      OrgPolicies.fromJson(await _api.get(ApiRoutes.orgPolicies(orgId)));

  /// Partial update (admin). [patch] carries wire keys; `null` clears a
  /// nullable value (no timer / keep forever).
  Future<OrgPolicies> patchPolicies(String orgId, Map<String, dynamic> patch) async =>
      OrgPolicies.fromJson(await _api.patch(ApiRoutes.orgPolicies(orgId), body: patch));

  // ---- Break-glass --------------------------------------------------------

  Future<List<AccessRequest>> accessRequests(String orgId) async {
    final j = await _api.get(ApiRoutes.orgAccessRequests(orgId));
    return [
      for (final r in (j['data'] as List? ?? const []))
        AccessRequest.fromJson(r as Map<String, dynamic>),
    ];
  }

  Future<AccessRequest> createAccessRequest(
    String orgId, {
    required String conversationId,
    required String reason,
  }) async {
    final j = await _api.post(
      ApiRoutes.orgAccessRequests(orgId),
      body: {'conversation_id': conversationId, 'reason': reason},
    );
    return AccessRequest.fromJson(j);
  }

  Future<AccessRequest> approveAccessRequest(String orgId, String requestId) async =>
      AccessRequest.fromJson(await _api.post(ApiRoutes.orgAccessRequestApprove(orgId, requestId)));

  Future<AccessRequest> rejectAccessRequest(String orgId, String requestId) async =>
      AccessRequest.fromJson(await _api.post(ApiRoutes.orgAccessRequestReject(orgId, requestId)));

  /// One audited page of the conversation (requester only, approved and
  /// inside the 24 h window). Newest first; [cursor] pages older.
  Future<BreakGlassPage> accessRequestMessages(
    String orgId,
    String requestId, {
    String? cursor,
  }) async {
    final j = await _api.get(
      ApiRoutes.orgAccessRequestMessages(orgId, requestId),
      query: cursor == null ? null : {'cursor': cursor},
    );
    return BreakGlassPage(
      [
        for (final m in (j['data'] as List? ?? const []))
          Message.fromJson(m as Map<String, dynamic>),
      ],
      j['next_cursor'] as String?,
    );
  }

  // ---- Moderation ---------------------------------------------------------

  /// [status] is a wire value or `all`.
  Future<List<OrgReport>> reports(String orgId, {String status = 'all'}) async {
    final list = await _api.getList(ApiRoutes.orgReports(orgId), query: {'status': status});
    return [for (final r in list) OrgReport.fromJson(r as Map<String, dynamic>)];
  }

  Future<OrgReport> setReportStatus(String orgId, String reportId, ReportStatus status) async =>
      OrgReport.fromJson(
        await _api.patch(ApiRoutes.orgReport(orgId, reportId), body: {'status': status.wire}),
      );

  // ---- Scheduled messages -------------------------------------------------

  Future<List<ScheduledMessage>> scheduled(String conversationId) async {
    final list = await _api.getList(ApiRoutes.conversationScheduled(conversationId));
    return [for (final s in list) ScheduledMessage.fromJson(s as Map<String, dynamic>)];
  }

  Future<void> cancelScheduled(String scheduledId) async {
    await _api.delete(ApiRoutes.scheduled(scheduledId));
  }
}
