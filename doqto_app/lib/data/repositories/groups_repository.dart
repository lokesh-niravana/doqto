import 'dart:io';

import '../../core/constants/api_routes.dart';
import '../../core/enums/app_enums.dart';
import '../api/api_client.dart';
import '../models/group.dart';
import '../models/network_profile.dart' show CursorPage;

/// Every group endpoint (M5). Groups are invite-only and undiscoverable, so
/// there is no browse and no join: `GET /groups` returns a `{data,
/// next_cursor}` page of the caller's own groups, `/me/groups` and members
/// return bare lists, and single-object endpoints return the object.
class GroupsRepository {
  final ApiClient _api;
  GroupsRepository(this._api);

  // --- Create / list / detail / update ---

  Future<Group> createGroup({
    required String name,
    String? description,
    String? memberDmPolicy,
    String? postPolicy,
    String? orgId,
  }) async {
    final j = await _api.post(ApiRoutes.groups, body: {
      'name': name,
      if (description != null && description.isNotEmpty)
        'description': description,
      'member_dm_policy': ?memberDmPolicy,
      'post_policy': ?postPolicy,
      'org_id': ?orgId,
    });
    return Group.fromJson(j);
  }

  /// The caller's groups as a `{data, next_cursor}` page.
  Future<CursorPage<Group>> listGroups({String? q, String? cursor}) async {
    final j = await _api.get(ApiRoutes.groups, query: {
      if (q != null && q.isNotEmpty) 'q': q,
      'cursor': ?cursor,
    });
    final data = (j['data'] as List? ?? const [])
        .map((e) => Group.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return CursorPage(data, j['next_cursor'] as String?);
  }

  Future<Group> getGroup(String id) async {
    final j = await _api.get(ApiRoutes.group(id));
    return Group.fromJson(j);
  }

  Future<Group> updateGroup(
    String id, {
    String? name,
    String? description,
    String? postPolicy,
    String? memberDmPolicy,
    String? avatarUrl,
  }) async {
    final j = await _api.patch(ApiRoutes.group(id), body: {
      'name': ?name,
      'description': ?description,
      'post_policy': ?postPolicy,
      'member_dm_policy': ?memberDmPolicy,
      'avatar_url': ?avatarUrl,
    });
    return Group.fromJson(j);
  }

  /// Owner/admin sets the group picture (JPG/PNG/WEBP ≤ 2 MB).
  Future<Group> uploadAvatar(String id, File file) async {
    final bytes = await file.readAsBytes();
    final filename = file.path.split('/').last;
    final lower = filename.toLowerCase();
    final mime = lower.endsWith('.png')
        ? 'image/png'
        : lower.endsWith('.webp')
            ? 'image/webp'
            : 'image/jpeg';
    final j = await _api.postMultipart(
      ApiRoutes.groupAvatar(id),
      fileField: 'file',
      bytes: bytes,
      filename: filename,
      contentType: mime,
    );
    return Group.fromJson(j);
  }

  Future<Group> deleteAvatar(String id) async {
    final j = await _api.delete(ApiRoutes.groupAvatar(id));
    return Group.fromJson(j);
  }

  /// `/me/groups?state=member|invited` → bare list of cards.
  Future<List<Group>> myGroups({String state = 'member'}) async {
    final list = await _api.getList(ApiRoutes.meGroups, query: {'state': state});
    return list
        .map((e) => Group.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  // --- Invites (the only way into a group) ---

  Future<GroupInvite> inviteUser(String groupId, String userId) async {
    final j = await _api.post(ApiRoutes.groupInvites(groupId),
        body: {'user_id': userId});
    return GroupInvite.fromJson(j);
  }

  Future<GroupInvite> createLinkInvite(
    String groupId, {
    int? maxUses,
    DateTime? expiresAt,
  }) async {
    final j = await _api.post(ApiRoutes.groupInvites(groupId), body: {
      'link': true,
      'max_uses': ?maxUses,
      if (expiresAt != null) 'expires_at': expiresAt.toUtc().toIso8601String(),
    });
    return GroupInvite.fromJson(j);
  }

  /// Pending invites (direct + link) — owner/admin only.
  Future<List<GroupInvite>> listInvites(String groupId) async {
    final list = await _api.getList(ApiRoutes.groupInvites(groupId));
    return list
        .map((e) => GroupInvite.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<JoinResult> acceptLinkInvite(String token) async {
    final j = await _api.post(ApiRoutes.groupInviteTokenAccept(token));
    return JoinResult.fromJson(j);
  }

  Future<void> acceptInvite(String groupId, String inviteId) =>
      _api.post(ApiRoutes.groupInviteAccept(groupId, inviteId));

  Future<void> declineInvite(String groupId, String inviteId) =>
      _api.post(ApiRoutes.groupInviteDecline(groupId, inviteId));

  Future<void> revokeInvite(String groupId, String inviteId) =>
      _api.delete(ApiRoutes.groupInvite(groupId, inviteId));

  // --- Members / roles / ownership ---

  Future<List<GroupMember>> members(String groupId) async {
    final list = await _api.getList(ApiRoutes.groupMembers(groupId));
    return list
        .map((e) => GroupMember.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<void> changeRole(String groupId, String userId, GroupRole role) =>
      _api.patch(ApiRoutes.groupMember(groupId, userId), body: {'role': role.wire});

  /// Remove a member, or leave the group (pass your own id).
  Future<void> removeMember(String groupId, String userId) =>
      _api.delete(ApiRoutes.groupMember(groupId, userId));

  Future<void> banMember(String groupId, String userId) =>
      _api.post(ApiRoutes.groupMemberBan(groupId, userId));

  Future<void> transferOwnership(String groupId, String userId) =>
      _api.post(ApiRoutes.groupTransferOwnership(groupId), body: {'user_id': userId});
}
