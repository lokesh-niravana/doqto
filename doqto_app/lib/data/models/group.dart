import '../../core/enums/app_enums.dart';
import 'network_profile.dart';

/// Client-only membership-state mirror (backend GroupMemberState). Tolerant:
/// unknown → [active] so a member row never wrongly disappears. NOT parity-gated
/// (backend-only enum — plan §M5).
enum GroupMemberState {
  active,
  banned,
  left,
  removed,
  unknown;

  String get wire => switch (this) {
        GroupMemberState.active => 'active',
        GroupMemberState.banned => 'banned',
        GroupMemberState.left => 'left',
        GroupMemberState.removed => 'removed',
        GroupMemberState.unknown => 'unknown',
      };

  static GroupMemberState fromWire(String? s) => switch (s) {
        'active' => GroupMemberState.active,
        'banned' => GroupMemberState.banned,
        'left' => GroupMemberState.left,
        'removed' => GroupMemberState.removed,
        _ => GroupMemberState.unknown,
      };
}

/// Where this group appeared in "My groups" (client-only tag, set by the state
/// layer from which /me/groups query produced it — the wire has no such field).
enum GroupMembershipTag { member, invited, none }

/// A group. Tolerant hand-written [fromJson] that parses BOTH the full
/// `GroupOut` (detail/create) and the `GroupCardOut` (my groups) — card
/// payloads omit conversation_id/owner_id/post_policy, which default to safe
/// empties. Mirrors backend schemas/group.py.
class Group {
  final String id;
  final String name;
  final String? description;
  final String? memberDmPolicy;
  final String? postPolicy;
  final String? avatarUrl;

  /// Short-lived GET URL for [avatarUrl] (an S3 key) — what the UI renders.
  final String? avatarPresignedUrl;
  final int memberCount;
  final String conversationId;
  final String ownerId;
  final String? orgId;

  /// The requesting user's role/state, when the payload carries it.
  final GroupRole? myRole;
  final GroupMemberState? myState;
  final DateTime? createdAt;

  /// My PENDING invite to this group, when I have one — what Accept /
  /// Decline act on. Null for members.
  final String? inviteId;

  /// Client-only tag (see [GroupMembershipTag]); never from the wire.
  final GroupMembershipTag membershipTag;

  const Group({
    required this.id,
    required this.name,
    required this.description,
    required this.memberDmPolicy,
    required this.postPolicy,
    required this.avatarUrl,
    this.avatarPresignedUrl,
    required this.memberCount,
    required this.conversationId,
    required this.ownerId,
    required this.orgId,
    required this.myRole,
    required this.myState,
    required this.createdAt,
    this.inviteId,
    this.membershipTag = GroupMembershipTag.none,
  });

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        description: j['description'] as String?,
        memberDmPolicy: j['member_dm_policy'] as String?,
        postPolicy: j['post_policy'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        avatarPresignedUrl: j['avatar_presigned_url'] as String?,
        memberCount: (j['member_count'] as num?)?.toInt() ?? 0,
        conversationId: (j['conversation_id'] ?? '') as String,
        ownerId: (j['owner_id'] ?? '') as String,
        orgId: j['org_id'] as String?,
        myRole: j['my_role'] != null
            ? GroupRole.fromWire(j['my_role'] as String?)
            : null,
        myState: j['my_state'] != null
            ? GroupMemberState.fromWire(j['my_state'] as String?)
            : null,
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'] as String)
            : null,
        inviteId: j['invite_id'] as String?,
      );

  /// True when the requesting user is an active member.
  bool get isMember =>
      myRole != null &&
      (myState == null || myState == GroupMemberState.active);

  /// True when the requesting user can manage the group (owner/admin/mod).
  bool get isAdmin => isMember && (myRole?.isAdminTier ?? false);

  /// Owner or admin: may edit the group, its settings, add/remove members
  /// and mint invite links. Moderators may not (server rule).
  bool get canManage =>
      isMember && (myRole == GroupRole.owner || myRole == GroupRole.admin);

  bool get isOwner => isMember && myRole == GroupRole.owner;

  /// A pending invite I can accept or decline.
  bool get hasPendingInvite => !isMember && inviteId != null;

  /// Only owner/admin may post when the group is admins-only.
  bool get adminsOnlyPosting => postPolicy == 'admins_only';
  bool get canPost => isMember && (!adminsOnlyPosting || canManage);

  String get initials => initialsOf(name);
  int get avatarIndex => avatarIndexFrom(null, id);

  Group copyWith({
    String? name,
    String? description,
    String? memberDmPolicy,
    String? postPolicy,
    String? avatarUrl,
    String? avatarPresignedUrl,
    bool clearAvatar = false,
    GroupRole? myRole,
    GroupMemberState? myState,
    int? memberCount,
    GroupMembershipTag? membershipTag,
    bool clearMyRole = false,
    bool clearInvite = false,
  }) =>
      Group(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        memberDmPolicy: memberDmPolicy ?? this.memberDmPolicy,
        postPolicy: postPolicy ?? this.postPolicy,
        avatarUrl: clearAvatar ? null : (avatarUrl ?? this.avatarUrl),
        avatarPresignedUrl:
            clearAvatar ? null : (avatarPresignedUrl ?? this.avatarPresignedUrl),
        memberCount: memberCount ?? this.memberCount,
        conversationId: conversationId,
        ownerId: ownerId,
        orgId: orgId,
        myRole: clearMyRole ? null : (myRole ?? this.myRole),
        myState: clearMyRole ? null : (myState ?? this.myState),
        createdAt: createdAt,
        inviteId: clearInvite ? null : inviteId,
        membershipTag: membershipTag ?? this.membershipTag,
      );

  Map<String, dynamic> toCacheJson() => {
        'id': id,
        'name': name,
        'description': description,
        'member_dm_policy': memberDmPolicy,
        'post_policy': postPolicy,
        'avatar_url': avatarUrl,
        'avatar_presigned_url': avatarPresignedUrl,
        'member_count': memberCount,
        'conversation_id': conversationId,
        'owner_id': ownerId,
        'org_id': orgId,
        'my_role': myRole?.wire,
        'my_state': myState?.wire,
        'created_at': createdAt?.toIso8601String(),
      };
}

/// One active member of a group. Mirrors backend GroupMemberOut. Carries NO
/// relationship fields (the members endpoint doesn't return degree/state), so
/// per-row Connect/Message is driven by [relationshipProvider] or a tap that
/// routes to /people/:id.
class GroupMember {
  final String userId;
  final String fullName;
  final String? specialty;
  final String? headline;
  final String? avatarColor;
  final String? avatarUrl;
  final String? avatarPresignedUrl;
  final GroupRole role;
  final GroupMemberState state;

  const GroupMember({
    required this.userId,
    required this.fullName,
    required this.specialty,
    required this.headline,
    required this.avatarColor,
    required this.avatarUrl,
    this.avatarPresignedUrl,
    required this.role,
    required this.state,
  });

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        userId: (j['user_id'] ?? '') as String,
        fullName: (j['full_name'] ?? '') as String,
        specialty: j['specialty'] as String?,
        headline: j['headline'] as String?,
        avatarColor: j['avatar_color'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        avatarPresignedUrl: j['avatar_presigned_url'] as String?,
        role: GroupRole.fromWire(j['role'] as String?),
        state: GroupMemberState.fromWire(j['state'] as String?),
      );

  String get initials => initialsOf(fullName);
  int get avatarIndex => avatarIndexFrom(avatarColor, userId);

  GroupMember copyWith({GroupRole? role}) => GroupMember(
        userId: userId,
        fullName: fullName,
        specialty: specialty,
        headline: headline,
        avatarColor: avatarColor,
        avatarUrl: avatarUrl,
        avatarPresignedUrl: avatarPresignedUrl,
        role: role ?? this.role,
        state: state,
      );
}

/// A pending invite into a group — direct (has [inviteeId]) or a shareable
/// link (has [token]). Mirrors backend GroupInviteOut. Admins list and
/// revoke these.
class GroupInvite {
  final String id;
  final String groupId;
  final String inviterId;
  final String? inviteeId;
  final String? token;
  final int? maxUses;
  final int useCount;
  final DateTime? expiresAt;
  final String state;
  final DateTime? createdAt;

  const GroupInvite({
    required this.id,
    required this.groupId,
    required this.inviterId,
    required this.inviteeId,
    required this.token,
    required this.maxUses,
    required this.useCount,
    required this.expiresAt,
    required this.state,
    required this.createdAt,
  });

  bool get isLink => token != null && token!.isNotEmpty;

  /// The app-scheme deep link that joins through this invite. Universal
  /// (https) links need an associated domain the iOS target does not have
  /// yet, so the scheme form is the one we share.
  String get deepLink => 'doqto:///g/$token';

  factory GroupInvite.fromJson(Map<String, dynamic> j) => GroupInvite(
        id: (j['id'] ?? '') as String,
        groupId: (j['group_id'] ?? '') as String,
        inviterId: (j['inviter_id'] ?? '') as String,
        inviteeId: j['invitee_id'] as String?,
        token: j['token'] as String?,
        maxUses: (j['max_uses'] as num?)?.toInt(),
        useCount: (j['use_count'] as num?)?.toInt() ?? 0,
        expiresAt: j['expires_at'] != null
            ? DateTime.tryParse(j['expires_at'] as String)
            : null,
        state: (j['state'] ?? 'pending') as String,
        createdAt: j['created_at'] != null
            ? DateTime.tryParse(j['created_at'] as String)
            : null,
      );
}

/// Result of accepting an invite link: `{result: 'joined'}`.
class JoinResult {
  final String result;
  final String groupId;
  const JoinResult(this.result, this.groupId);

  bool get joined => result == 'joined';

  factory JoinResult.fromJson(Map<String, dynamic> j) => JoinResult(
        (j['result'] ?? '') as String,
        (j['group_id'] ?? '') as String,
      );
}
