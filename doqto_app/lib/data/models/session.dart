import '../../core/enums/app_enums.dart';

/// One signed-in device (batch 6). Mirrors `SessionOut`; `current` marks the
/// session behind the token that made the request.
class DeviceSession {
  final String id;
  final String? deviceName;
  final DevicePlatform? platform;
  final String? appVersion;
  final String? ip;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final bool current;

  const DeviceSession({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.ip,
    required this.createdAt,
    required this.lastSeenAt,
    this.current = false,
  });

  factory DeviceSession.fromJson(Map<String, dynamic> j) => DeviceSession(
        id: j['id'] as String,
        deviceName: j['device_name'] as String?,
        platform: switch (j['platform']) {
          'ios' => DevicePlatform.ios,
          'android' => DevicePlatform.android,
          _ => null,
        },
        appVersion: j['app_version'] as String?,
        ip: j['ip'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String).toUtc(),
        lastSeenAt: DateTime.parse(j['last_seen_at'] as String).toUtc(),
        current: (j['current'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'device_name': deviceName,
        'platform': platform?.wire,
        'app_version': appVersion,
        'ip': ip,
        'created_at': createdAt.toIso8601String(),
        'last_seen_at': lastSeenAt.toIso8601String(),
        'current': current,
      };

  /// "iPhone 16" / "Android device" — never empty.
  String get title {
    final n = deviceName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return switch (platform) {
      DevicePlatform.ios => 'iPhone',
      DevicePlatform.android => 'Android device',
      null => 'Unknown device',
    };
  }
}
