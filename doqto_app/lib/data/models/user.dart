import '../../core/enums/app_enums.dart';

class User {
  final String id;
  final String phone;
  final String? email;
  final String fullName;
  final String? specialty;
  final String npiNumber;
  final UserRole role;
  final String? avatarColor;
  final String? avatarUrl;
  final String? avatarPresignedUrl;
  final String? bio;
  final String? city;
  final String? state;
  final int? yearsOfExperience;
  final List<String> skills;
  final DateTime? lastSeenAt;
  final DateTime createdAt;

  /// Status under the name (batch 6): a preset OR custom text, never both.
  final StatusPreset? statusPreset;
  final String? statusText;
  final DateTime? statusExpiresAt;

  /// Two-step PIN (batch 6).
  final bool pinEnabled;
  final DateTime? pinClearsAt;

  const User({
    required this.id,
    required this.phone,
    required this.email,
    required this.fullName,
    required this.specialty,
    required this.npiNumber,
    required this.role,
    required this.avatarColor,
    required this.avatarUrl,
    required this.avatarPresignedUrl,
    required this.bio,
    required this.city,
    required this.state,
    required this.yearsOfExperience,
    required this.skills,
    required this.lastSeenAt,
    required this.createdAt,
    this.statusPreset,
    this.statusText,
    this.statusExpiresAt,
    this.pinEnabled = false,
    this.pinClearsAt,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as String,
        // Absent for accounts created by social sign-in until they add one.
        phone: (j['phone'] ?? '') as String,
        email: j['email'] as String?,
        fullName: (j['full_name'] ?? '') as String,
        specialty: j['specialty'] as String?,
        npiNumber: (j['npi_number'] ?? '') as String,
        role: UserRole.fromWire(j['role'] as String),
        avatarColor: j['avatar_color'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        avatarPresignedUrl: j['avatar_presigned_url'] as String?,
        bio: j['bio'] as String?,
        city: j['city'] as String?,
        state: j['state'] as String?,
        yearsOfExperience: j['years_of_experience'] as int?,
        skills: ((j['skills'] as List?) ?? const []).cast<String>(),
        lastSeenAt: j['last_seen_at'] != null ? DateTime.parse(j['last_seen_at'] as String) : null,
        createdAt: DateTime.parse(j['created_at'] as String),
        statusPreset: StatusPreset.fromWire(j['status_preset'] as String?),
        statusText: j['status_text'] as String?,
        statusExpiresAt: j['status_expires_at'] != null
            ? DateTime.tryParse(j['status_expires_at'] as String)?.toUtc()
            : null,
        pinEnabled: (j['pin_enabled'] as bool?) ?? false,
        pinClearsAt: j['pin_clears_at'] != null
            ? DateTime.tryParse(j['pin_clears_at'] as String)?.toUtc()
            : null,
      );

  /// What to show under the name: the preset's label or the custom text,
  /// nothing once it has expired.
  String? statusLabel([DateTime? now]) {
    final exp = statusExpiresAt;
    if (exp != null && !exp.isAfter(now ?? DateTime.now().toUtc())) return null;
    if (statusPreset != null) return statusPreset!.label;
    final t = statusText?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  User copyWith({
    StatusPreset? Function()? statusPreset,
    String? Function()? statusText,
    DateTime? Function()? statusExpiresAt,
    bool? pinEnabled,
    DateTime? Function()? pinClearsAt,
  }) =>
      User(
        id: id,
        phone: phone,
        email: email,
        fullName: fullName,
        specialty: specialty,
        npiNumber: npiNumber,
        role: role,
        avatarColor: avatarColor,
        avatarUrl: avatarUrl,
        avatarPresignedUrl: avatarPresignedUrl,
        bio: bio,
        city: city,
        state: state,
        yearsOfExperience: yearsOfExperience,
        skills: skills,
        lastSeenAt: lastSeenAt,
        createdAt: createdAt,
        statusPreset: statusPreset == null ? this.statusPreset : statusPreset(),
        statusText: statusText == null ? this.statusText : statusText(),
        statusExpiresAt:
            statusExpiresAt == null ? this.statusExpiresAt : statusExpiresAt(),
        pinEnabled: pinEnabled ?? this.pinEnabled,
        pinClearsAt: pinClearsAt == null ? this.pinClearsAt : pinClearsAt(),
      );

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    final first = parts.first[0];
    final last = parts.length > 1 ? parts.last[0] : '';
    return (first + last).toUpperCase();
  }

  String? get locationLabel {
    final parts = [city, state].whereType<String>().where((s) => s.trim().isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(', ');
  }
}
