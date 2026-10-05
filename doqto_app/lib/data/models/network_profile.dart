import '../../core/enums/app_enums.dart';

/// Shared initials helper — first + last name initial, uppercased.
String initialsOf(String? fullName) {
  final name = (fullName ?? '').trim();
  if (name.isEmpty) return '?';
  final parts = name.split(RegExp(r'\s+'));
  final first = parts.first.isNotEmpty ? parts.first[0] : '';
  final last = parts.length > 1 && parts.last.isNotEmpty ? parts.last[0] : '';
  final out = (first + last).toUpperCase();
  return out.isEmpty ? '?' : out;
}

/// Deterministic avatar color index from an id + optional server-provided
/// `avatar_color` hint. Falls back to a hash of the id so every person gets a
/// stable color even when the server omits the hint.
int avatarIndexFrom(String? avatarColor, String id) {
  if (avatarColor != null && avatarColor.trim().isNotEmpty) {
    final parsed = int.tryParse(avatarColor.trim());
    if (parsed != null) return parsed;
  }
  return id.hashCode.abs();
}

/// Relationship context between the viewer and another person. Every field is
/// derived server-side from the permission module; the client mirrors it as a
/// value object (see [ConnectionDegree]/[RelationshipState]/[CanMessage] — plain
/// wire strings, NOT parity-gated). Tolerant parsing throughout.
class Relationship {
  final ConnectionDegree degree;
  final RelationshipState connectionState;
  final CanMessage canMessage;
  final int mutualCount;
  final String? contextLabel;

  /// Viewer and target share an organization. Colleagues need no connection to
  /// message, so the Connect affordances stay out of their way entirely.
  final bool isColleague;

  const Relationship({
    required this.degree,
    required this.connectionState,
    required this.canMessage,
    required this.mutualCount,
    this.contextLabel,
    this.isColleague = false,
  });

  factory Relationship.fromJson(Map<String, dynamic> j) => Relationship(
        degree: ConnectionDegree.fromWire(j['degree'] as String?),
        connectionState: RelationshipState.fromWire(j['connection_state'] as String?),
        canMessage: CanMessage.fromWire(j['can_message'] as String?),
        mutualCount: (j['mutual_count'] as num?)?.toInt() ?? 0,
        contextLabel: j['context_label'] as String?,
        isColleague: (j['is_colleague'] ?? false) as bool,
      );

  Relationship copyWith({
    ConnectionDegree? degree,
    RelationshipState? connectionState,
    CanMessage? canMessage,
    int? mutualCount,
    String? contextLabel,
    bool? isColleague,
  }) =>
      Relationship(
        degree: degree ?? this.degree,
        connectionState: connectionState ?? this.connectionState,
        canMessage: canMessage ?? this.canMessage,
        mutualCount: mutualCount ?? this.mutualCount,
        contextLabel: contextLabel ?? this.contextLabel,
        isColleague: isColleague ?? this.isColleague,
      );
}

/// Mirrors backend PublicProfileOut. Never carries phone/email/NPI (HIPAA
/// minimum-necessary — the backend omits them from this payload).
class NetworkProfile {
  final String id;
  final String fullName;
  final String? headline;
  final String? specialty;
  final String? locationLabel;
  final String? avatarColor;
  final String? avatarUrl;
  final String? avatarPresignedUrl;
  final String? about;
  final int? yearsOfExperience;
  final List<String> skills;
  final Relationship relationship;

  const NetworkProfile({
    required this.id,
    required this.fullName,
    required this.headline,
    required this.specialty,
    required this.locationLabel,
    required this.avatarColor,
    required this.avatarUrl,
    required this.avatarPresignedUrl,
    required this.about,
    required this.yearsOfExperience,
    required this.skills,
    required this.relationship,
  });

  factory NetworkProfile.fromJson(Map<String, dynamic> j) => NetworkProfile(
        id: (j['id'] ?? '') as String,
        fullName: (j['full_name'] ?? '') as String,
        headline: j['headline'] as String?,
        specialty: j['specialty'] as String?,
        locationLabel: j['location_label'] as String?,
        avatarColor: j['avatar_color'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        avatarPresignedUrl: j['avatar_presigned_url'] as String?,
        about: j['about'] as String?,
        yearsOfExperience: (j['years_of_experience'] as num?)?.toInt(),
        skills: ((j['skills'] as List?) ?? const []).map((e) => e.toString()).toList(),
        // Relationship fields live flat on PublicProfileOut.
        relationship: Relationship.fromJson(j),
      );

  String get initials => initialsOf(fullName);
  int get avatarIndex => avatarIndexFrom(avatarColor, id);

  NetworkProfile copyWith({Relationship? relationship}) => NetworkProfile(
        id: id,
        fullName: fullName,
        headline: headline,
        specialty: specialty,
        locationLabel: locationLabel,
        avatarColor: avatarColor,
        avatarUrl: avatarUrl,
        avatarPresignedUrl: avatarPresignedUrl,
        about: about,
        yearsOfExperience: yearsOfExperience,
        skills: skills,
        relationship: relationship ?? this.relationship,
      );
}

/// Mirrors backend PersonCardOut (search results). No PHI.
class PersonCard {
  final String id;
  final String fullName;
  final String? headline;
  final String? specialty;
  final String? locationLabel;
  final String? avatarColor;
  final String? avatarUrl;
  final String? avatarPresignedUrl;
  final ConnectionDegree degree;
  final int mutualCount;

  /// Suggestions only: why they're suggested (colleague, mutual,
  /// specialty_nearby, specialty, nearby, new_member).
  final String? reason;

  const PersonCard({
    required this.id,
    required this.fullName,
    required this.headline,
    required this.specialty,
    required this.locationLabel,
    required this.avatarColor,
    required this.avatarUrl,
    required this.avatarPresignedUrl,
    required this.degree,
    required this.mutualCount,
    this.reason,
  });

  factory PersonCard.fromJson(Map<String, dynamic> j) => PersonCard(
        // `user_id`: the connections endpoint names the same field differently.
        // An empty id routes to `/people/` — a Page-not-found, not an error.
        id: (j['id'] ?? j['user_id'] ?? '') as String,
        fullName: (j['full_name'] ?? '') as String,
        headline: j['headline'] as String?,
        specialty: j['specialty'] as String?,
        locationLabel: j['location_label'] as String?,
        avatarColor: j['avatar_color'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        avatarPresignedUrl: j['avatar_presigned_url'] as String?,
        degree: ConnectionDegree.fromWire(j['degree'] as String?),
        mutualCount: (j['mutual_count'] as num?)?.toInt() ?? 0,
        reason: j['reason'] as String?,
      );

  String get initials => initialsOf(fullName);
  int get avatarIndex => avatarIndexFrom(avatarColor, id);
}

/// The other party in an [Invitation] (sender or recipient). Parsed tolerantly
/// from either a nested object or flat `<role>_id`/`<role>_name` fields.
class InvitationParty {
  final String id;
  final String fullName;
  final String? headline;
  final String? specialty;
  final String? avatarColor;
  final String? avatarPresignedUrl;

  const InvitationParty({
    required this.id,
    required this.fullName,
    this.headline,
    this.specialty,
    this.avatarColor,
    this.avatarPresignedUrl,
  });

  factory InvitationParty.fromJson(Map<String, dynamic> j) => InvitationParty(
        id: (j['id'] ?? '') as String,
        fullName: (j['full_name'] ?? j['name'] ?? '') as String,
        headline: j['headline'] as String?,
        specialty: j['specialty'] as String?,
        avatarColor: j['avatar_color'] as String?,
        avatarPresignedUrl: j['avatar_presigned_url'] as String?,
      );

  String get initials => initialsOf(fullName);
  int get avatarIndex => avatarIndexFrom(avatarColor, id);
}

/// A connection invitation (sent or received). Tolerant of flat vs nested
/// party shapes — the backend M1 payload for lists is `{data:[...]}`.
class Invitation {
  final String id;
  final InvitationParty? sender;
  final InvitationParty? recipient;
  final InvitationStatus status;
  final String? message;
  final DateTime? createdAt;

  const Invitation({
    required this.id,
    required this.sender,
    required this.recipient,
    required this.status,
    required this.message,
    required this.createdAt,
  });

  static InvitationParty? _party(
    Map<String, dynamic> j,
    String objectKey,
    String idKey,
    String nameKey,
  ) {
    final nested = j[objectKey];
    if (nested is Map) {
      return InvitationParty.fromJson(nested.cast<String, dynamic>());
    }
    final id = j[idKey] as String?;
    if (id == null) return null;
    return InvitationParty(id: id, fullName: (j[nameKey] ?? '') as String);
  }

  factory Invitation.fromJson(Map<String, dynamic> j) => Invitation(
        id: (j['id'] ?? '') as String,
        sender: _party(j, 'sender', 'sender_id', 'sender_name'),
        recipient: _party(j, 'recipient', 'recipient_id', 'recipient_name'),
        status: InvitationStatus.fromWire((j['status'] ?? 'pending') as String),
        message: j['message'] as String?,
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'] as String)
            : null,
      );
}

/// Mirrors backend user_privacy_settings (GET/PATCH /users/me/privacy).
class PrivacySettings {
  final InvitePolicy invitePolicy;
  final DmPolicy dmPolicy;
  final Discoverability discoverability;

  const PrivacySettings({
    required this.invitePolicy,
    required this.dmPolicy,
    required this.discoverability,
  });

  factory PrivacySettings.fromJson(Map<String, dynamic> j) => PrivacySettings(
        invitePolicy: InvitePolicy.fromWire((j['invite_policy'] ?? 'everyone') as String),
        dmPolicy: DmPolicy.fromWire((j['dm_policy'] ?? 'everyone') as String),
        discoverability:
            Discoverability.fromWire((j['discoverability'] ?? 'everyone') as String),
      );

  Map<String, dynamic> toJson() => {
        'invite_policy': invitePolicy.wire,
        'dm_policy': dmPolicy.wire,
        'discoverability': discoverability.wire,
      };
}

/// A cursor-paginated list page — `{data, next_cursor}`.
class CursorPage<T> {
  final List<T> data;
  final String? nextCursor;
  const CursorPage(this.data, this.nextCursor);
}
