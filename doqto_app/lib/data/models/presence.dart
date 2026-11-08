import '../../core/enums/app_enums.dart';

/// One doctor's presence AS THE SERVER LETS ME SEE IT (batch 2). A doctor who
/// hides their last seen reads exactly like an offline stranger: `offline`
/// with no [lastSeenAt] — the client never knows the difference.
class PresenceInfo {
  final String userId;
  final PresenceStatus status;
  final DateTime? lastSeenAt;

  /// Status under the name (batch 6): directory data, not gated by last-seen
  /// visibility. Preset OR custom text.
  final StatusPreset? statusPreset;
  final String? statusText;
  final DateTime? statusExpiresAt;

  const PresenceInfo({
    required this.userId,
    required this.status,
    this.lastSeenAt,
    this.statusPreset,
    this.statusText,
    this.statusExpiresAt,
  });

  /// Preset label or custom text; null when unset or expired.
  String? statusLabel([DateTime? now]) {
    final exp = statusExpiresAt;
    if (exp != null && !exp.isAfter(now ?? DateTime.now().toUtc())) return null;
    if (statusPreset != null) return statusPreset!.label;
    final t = statusText?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  factory PresenceInfo.fromJson(Map<String, dynamic> j) => PresenceInfo(
        userId: (j['user_id'] ?? '') as String,
        status: PresenceStatus.fromWire(j['status'] as String?),
        lastSeenAt: j['last_seen_at'] == null
            ? null
            : DateTime.tryParse(j['last_seen_at'] as String)?.toUtc(),
        statusPreset: StatusPreset.fromWire(j['status_preset'] as String?),
        statusText: j['status_text'] as String?,
        statusExpiresAt: j['status_expires_at'] is String
            ? DateTime.tryParse(j['status_expires_at'] as String)?.toUtc()
            : null,
      );

  bool get isOnline => status == PresenceStatus.online;
}
