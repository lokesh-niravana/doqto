import '../../core/enums/app_enums.dart';

class Organization {
  final String id;
  final String name;
  final String? address;
  final String? city;
  final String? state;
  final String? practiceType;
  final String inviteCode;
  final OrgStatus status;
  final String? reviewNotes;
  final DateTime? verifiedAt;
  final DateTime createdAt;
  final int memberCount;

  const Organization({
    required this.id,
    required this.name,
    required this.address,
    required this.city,
    required this.state,
    required this.practiceType,
    required this.inviteCode,
    required this.status,
    required this.reviewNotes,
    required this.verifiedAt,
    required this.createdAt,
    required this.memberCount,
  });

  factory Organization.fromJson(Map<String, dynamic> j) => Organization(
        id: j['id'] as String,
        name: j['name'] as String,
        address: j['address'] as String?,
        city: j['city'] as String?,
        state: j['state'] as String?,
        practiceType: j['practice_type'] as String?,
        inviteCode: j['invite_code'] as String,
        status: OrgStatus.fromWire(j['status'] as String),
        reviewNotes: j['review_notes'] as String?,
        verifiedAt: j['verified_at'] != null ? DateTime.parse(j['verified_at'] as String) : null,
        createdAt: DateTime.parse(j['created_at'] as String),
        memberCount: (j['member_count'] ?? 0) as int,
      );
}

/// One organization-lookup result: a practice from the public directory
/// (Medicare groups, hospitals, NPI Registry). [doqtoOrgId] is set when the
/// practice is already on Doqto — then the user joins instead of creating.
class DirectoryEntry {
  final String source;
  final String sourceId;
  final String name;
  final String? city;
  final String? state;
  final PracticeType practiceType;
  final int? memberCount;
  final bool youAreListed;
  final String? doqtoOrgId;
  final String? doqtoOrgName;

  const DirectoryEntry({
    required this.source,
    required this.sourceId,
    required this.name,
    this.city,
    this.state,
    required this.practiceType,
    this.memberCount,
    this.youAreListed = false,
    this.doqtoOrgId,
    this.doqtoOrgName,
  });

  bool get onDoqto => doqtoOrgId != null;

  String get place => [city, state].whereType<String>().join(', ');

  factory DirectoryEntry.fromJson(Map<String, dynamic> j) {
    final org = j['doqto_org'] as Map<String, dynamic>?;
    return DirectoryEntry(
      source: j['source'] as String,
      sourceId: j['source_id'] as String,
      name: j['name'] as String,
      city: j['city'] as String?,
      state: j['state'] as String?,
      practiceType: PracticeType.values.firstWhere(
        (t) => t.wire == j['practice_type'],
        orElse: () => PracticeType.independent,
      ),
      memberCount: j['member_count'] as int?,
      youAreListed: (j['you_are_listed'] ?? false) as bool,
      doqtoOrgId: org?['id'] as String?,
      doqtoOrgName: org?['name'] as String?,
    );
  }
}

// Flat member shape — the API returns only minimum-necessary fields
// (no phone/email/NPI) per HIPAA minimum-necessary.
class OrgMember {
  final String id;
  final String fullName;
  final String? specialty;
  final OrgRole orgRole;
  final DateTime joinedAt;
  final PresenceStatus presence;
  final String? avatarColor;
  final String? avatarUrl;
  final String? avatarPresignedUrl;

  const OrgMember({
    required this.id,
    required this.fullName,
    required this.specialty,
    required this.orgRole,
    required this.joinedAt,
    required this.presence,
    required this.avatarColor,
    required this.avatarUrl,
    required this.avatarPresignedUrl,
  });

  factory OrgMember.fromJson(Map<String, dynamic> j) => OrgMember(
        id: j['id'] as String,
        fullName: j['full_name'] as String,
        specialty: j['specialty'] as String?,
        orgRole: OrgRole.fromWire(j['org_role'] as String),
        joinedAt: DateTime.parse(j['joined_at'] as String),
        presence: PresenceStatus.fromWire(j['presence'] as String?),
        avatarColor: j['avatar_color'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        avatarPresignedUrl: j['avatar_presigned_url'] as String?,
      );

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    final first = parts.first[0];
    final last = parts.length > 1 ? parts.last[0] : '';
    return (first + last).toUpperCase();
  }
}
