import '../../core/enums/app_enums.dart';
import 'message.dart';

/// Break-glass request lifecycle (batch 7). Backend-only enum on the wire;
/// tolerant: anything unknown reads as [pending].
enum AccessRequestStatus {
  pending,
  approved,
  rejected,
  expired;

  String get wire => name;

  static AccessRequestStatus fromWire(String? s) => switch (s) {
        'approved' => AccessRequestStatus.approved,
        'rejected' => AccessRequestStatus.rejected,
        'expired' => AccessRequestStatus.expired,
        _ => AccessRequestStatus.pending,
      };
}

/// One emergency-access request: an org admin asked to read a conversation
/// involving a member; a different admin decides. `reason` is the only free
/// text — never message content.
class AccessRequest {
  final String id;
  final String orgId;
  final String conversationId;
  final String requesterId;
  final String reason;
  final AccessRequestStatus status;
  final String? decidedBy;
  final DateTime? decidedAt;
  final DateTime? expiresAt;
  final DateTime? firstReadAt;
  final DateTime createdAt;

  const AccessRequest({
    required this.id,
    required this.orgId,
    required this.conversationId,
    required this.requesterId,
    required this.reason,
    required this.status,
    this.decidedBy,
    this.decidedAt,
    this.expiresAt,
    this.firstReadAt,
    required this.createdAt,
  });

  factory AccessRequest.fromJson(Map<String, dynamic> j) => AccessRequest(
        id: j['id'] as String,
        orgId: j['org_id'] as String,
        conversationId: j['conversation_id'] as String,
        requesterId: j['requester_id'] as String,
        reason: (j['reason'] as String?) ?? '',
        status: AccessRequestStatus.fromWire(j['status'] as String?),
        decidedBy: j['decided_by'] as String?,
        decidedAt: _date(j['decided_at']),
        expiresAt: _date(j['expires_at']),
        firstReadAt: _date(j['first_read_at']),
        createdAt: DateTime.parse(j['created_at'] as String),
      );

  /// The requester may open the audited read while this is true.
  bool get readable =>
      status == AccessRequestStatus.approved &&
      (expiresAt == null || expiresAt!.isAfter(DateTime.now().toUtc()));

  AccessRequest copyWith({AccessRequestStatus? status}) => AccessRequest(
        id: id,
        orgId: orgId,
        conversationId: conversationId,
        requesterId: requesterId,
        reason: reason,
        status: status ?? this.status,
        decidedBy: decidedBy,
        decidedAt: decidedAt,
        expiresAt: expiresAt,
        firstReadAt: firstReadAt,
        createdAt: createdAt,
      );
}

/// A page of the audited break-glass read: newest first, decrypted,
/// including tombstones kept under legal hold.
class BreakGlassPage {
  final List<Message> data;
  final String? nextCursor;
  const BreakGlassPage(this.data, this.nextCursor);
}

/// Moderation report status — backend-only enum; the org admin moves a
/// report between these from My Org → Reports.
enum ReportStatus {
  open,
  reviewing,
  actioned,
  dismissed;

  String get wire => name;

  static ReportStatus fromWire(String? s) => switch (s) {
        'reviewing' => ReportStatus.reviewing,
        'actioned' => ReportStatus.actioned,
        'dismissed' => ReportStatus.dismissed,
        _ => ReportStatus.open,
      };
}

/// A report in the org's moderation scope. Ids, reason and the reporter's
/// details only — the server never includes message bodies here.
class OrgReport {
  final String id;
  final String reporterId;
  final String subjectType; // user | message
  final String subjectId;
  final ReportReason reason;
  final String? details;
  final ReportStatus status;
  final List<String> contextMessageIds;
  final String? resolvedBy;
  final DateTime? resolvedAt;
  final DateTime createdAt;

  const OrgReport({
    required this.id,
    required this.reporterId,
    required this.subjectType,
    required this.subjectId,
    required this.reason,
    this.details,
    required this.status,
    this.contextMessageIds = const [],
    this.resolvedBy,
    this.resolvedAt,
    required this.createdAt,
  });

  factory OrgReport.fromJson(Map<String, dynamic> j) => OrgReport(
        id: j['id'] as String,
        reporterId: j['reporter_id'] as String,
        subjectType: (j['subject_type'] as String?) ?? 'user',
        subjectId: j['subject_id'] as String,
        reason: ReportReason.fromWire(j['reason'] as String?),
        details: j['details'] as String?,
        status: ReportStatus.fromWire(j['status'] as String?),
        contextMessageIds: [
          for (final id in (j['context_message_ids'] as List? ?? const [])) id.toString(),
        ],
        resolvedBy: j['resolved_by'] as String?,
        resolvedAt: _date(j['resolved_at']),
        createdAt: DateTime.parse(j['created_at'] as String),
      );

  OrgReport copyWith({ReportStatus? status}) => OrgReport(
        id: id,
        reporterId: reporterId,
        subjectType: subjectType,
        subjectId: subjectId,
        reason: reason,
        details: details,
        status: status ?? this.status,
        contextMessageIds: contextMessageIds,
        resolvedBy: resolvedBy,
        resolvedAt: resolvedAt,
        createdAt: createdAt,
      );
}

/// One of my not-yet-sent scheduled messages in a chat. No content: the
/// server never returns the draft, the app keeps what it scheduled.
class ScheduledMessage {
  final String id;
  final String conversationId;
  final DateTime scheduledAt;
  final String timezone;
  final String status; // pending | failed
  final String? error;
  final DateTime? createdAt;

  const ScheduledMessage({
    required this.id,
    required this.conversationId,
    required this.scheduledAt,
    required this.timezone,
    required this.status,
    this.error,
    this.createdAt,
  });

  factory ScheduledMessage.fromJson(Map<String, dynamic> j) => ScheduledMessage(
        id: j['id'] as String,
        conversationId: j['conversation_id'] as String,
        scheduledAt: DateTime.parse(j['scheduled_at'] as String),
        timezone: (j['timezone'] as String?) ?? 'UTC',
        status: (j['status'] as String?) ?? 'pending',
        error: j['error'] as String?,
        createdAt: _date(j['created_at']),
      );

  bool get failed => status == 'failed';
}

DateTime? _date(Object? v) => v is String && v.isNotEmpty ? DateTime.parse(v) : null;
