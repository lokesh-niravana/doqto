import '../../core/enums/app_enums.dart';

/// One doctor's presence AS THE SERVER LETS ME SEE IT (batch 2). A doctor who
/// hides their last seen reads exactly like an offline stranger: `offline`
/// with no [lastSeenAt] — the client never knows the difference.
class PresenceInfo {
  final String userId;
  final PresenceStatus status;
  final DateTime? lastSeenAt;

  const PresenceInfo({
    required this.userId,
    required this.status,
    this.lastSeenAt,
  });

  factory PresenceInfo.fromJson(Map<String, dynamic> j) => PresenceInfo(
        userId: (j['user_id'] ?? '') as String,
        status: PresenceStatus.fromWire(j['status'] as String?),
        lastSeenAt: j['last_seen_at'] == null
            ? null
            : DateTime.tryParse(j['last_seen_at'] as String)?.toUtc(),
      );

  bool get isOnline => status == PresenceStatus.online;
}
