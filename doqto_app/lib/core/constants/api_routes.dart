/// API route paths — mirrored from app/core/routes.py on the backend.
class ApiRoutes {
  ApiRoutes._();

  static const String apiV1 = '/api/v1';

  // Auth
  static const String authFirebase = '$apiV1/auth/firebase';
  static const String authRefresh = '$apiV1/auth/refresh';
  static const String authLogout = '$apiV1/auth/logout';
  static const String authRegister = '$apiV1/auth/register';
  // Two-step PIN (batch 6): verify on a new device / start the 7-day reset.
  static const String authPinVerify = '$apiV1/auth/pin/verify';
  static const String authPinResetRequest = '$apiV1/auth/pin/reset-request';

  // Users
  static const String usersMe = '$apiV1/users/me';
  static const String usersMeAvatar = '$apiV1/users/me/avatar';
  /// Stable picture bytes for any doctor (visibility enforced server-side).
  static String userAvatar(String id) => '$apiV1/users/$id/avatar';
  static const String usersMePushTokens = '$apiV1/users/me/push-tokens';
  // Attach a phone to the signed-in account (POST, sign-up) or change the
  // number (PATCH, batch 6) — both take a Firebase ID token for the number.
  // See docs/phone-verification.md and docs/settings.md.
  static const String usersMePhone = '$apiV1/users/me/phone';
  // Settings (batch 6)
  static const String usersMeNotifications = '$apiV1/users/me/notifications';
  static const String usersMeSessions = '$apiV1/users/me/sessions';
  static String usersMeSession(String id) => '$apiV1/users/me/sessions/$id';
  static const String usersMeSessionsRevokeOthers =
      '$apiV1/users/me/sessions/revoke-others';
  static const String usersMePin = '$apiV1/users/me/pin';
  static const String usersMeExport = '$apiV1/users/me/export';
  static const String usersMeStatus = '$apiV1/users/me/status';

  // Orgs
  static const String orgs = '$apiV1/orgs';
  static const String orgsJoin = '$apiV1/orgs/join';
  static const String orgsMine = '$apiV1/orgs/mine';
  static const String orgsDirectorySearch = '$apiV1/orgs/directory/search';
  static const String orgsDirectorySuggested = '$apiV1/orgs/directory/suggested';
  static const String orgsDirectoryJoin = '$apiV1/orgs/directory/join';
  static String orgDetail(String id) => '$apiV1/orgs/$id';
  static String orgMembers(String id) => '$apiV1/orgs/$id/members';
  static String orgMember(String orgId, String userId) =>
      '$apiV1/orgs/$orgId/members/$userId';
  static String orgInviteCode(String id) => '$apiV1/orgs/$id/invite-code';
  // Compliance (batch 7)
  static String orgPolicies(String id) =>
      '$apiV1/orgs/$id/policies'; // GET member / PATCH admin
  static String orgAudit(String id) => '$apiV1/orgs/$id/audit'; // GET admin
  static String orgReports(String id) =>
      '$apiV1/orgs/$id/reports'; // GET ?status=&cursor= (admin)
  static String orgReport(String orgId, String reportId) =>
      '$apiV1/orgs/$orgId/reports/$reportId'; // PATCH {status}
  static String orgAccessRequests(String id) =>
      '$apiV1/orgs/$id/access-requests'; // GET list / POST {conversation_id, reason}
  static String orgAccessRequestApprove(String orgId, String requestId) =>
      '$apiV1/orgs/$orgId/access-requests/$requestId/approve';
  static String orgAccessRequestReject(String orgId, String requestId) =>
      '$apiV1/orgs/$orgId/access-requests/$requestId/reject';
  static String orgAccessRequestMessages(String orgId, String requestId) =>
      '$apiV1/orgs/$orgId/access-requests/$requestId/messages'; // GET ?cursor=

  // Conversations
  static const String conversations = '$apiV1/conversations';
  // Badge number: unread across the list minus muted / archived (batch 3).
  static const String conversationsUnreadTotal =
      '$apiV1/conversations/unread-total';
  static String conversationMessages(String id) =>
      '$apiV1/conversations/$id/messages';
  static String conversationScheduleMessage(String id) =>
      '$apiV1/conversations/$id/messages/schedule';
  // My pending scheduled messages in a chat (batch 7); cancel with scheduled().
  static String conversationScheduled(String id) =>
      '$apiV1/conversations/$id/scheduled';
  static String scheduled(String id) => '$apiV1/scheduled/$id'; // DELETE
  static String conversationRead(String id) => '$apiV1/conversations/$id/read';
  static String conversationDelivered(String id) =>
      '$apiV1/conversations/$id/delivered';
  static String conversationMembers(String id) =>
      '$apiV1/conversations/$id/members';
  static String conversationMember(String convId, String userId) =>
      '$apiV1/conversations/$convId/members/$userId';
  static String conversationSettings(String id) =>
      '$apiV1/conversations/$id/settings';
  // My pin / archive / mute / mark unread / clear / delete (batch 3).
  static String conversationPrefs(String id) =>
      '$apiV1/conversations/$id/prefs';
  // Pinned message (batch 4): PUT {message_id, duration_sec} / DELETE.
  static String conversationPin(String id) => '$apiV1/conversations/$id/pin';

  // Messages
  static String messageUpload(String convId) =>
      '$apiV1/messages/upload/$convId';
  static String messageVoiceNote(String convId) =>
      '$apiV1/messages/voice-notes/$convId';
  static String messageRead(String id) => '$apiV1/messages/$id/read';
  static String message(String id) =>
      '$apiV1/messages/$id'; // PATCH edit / DELETE
  static String messageEdits(String id) => '$apiV1/messages/$id/edits';
  static String messageReaction(String id) =>
      '$apiV1/messages/$id/reaction'; // PUT set / DELETE remove (own)
  static const String messagesHide =
      '$apiV1/messages/hide'; // POST delete-for-me
  static String messageFileUrl(String id) => '$apiV1/messages/$id/file-url';
  static String messageReceipts(String id) =>
      '$apiV1/messages/$id/receipts'; // sender-only read-by / delivered-to
  // Batch 4
  static String messageForward(String id) =>
      '$apiV1/messages/$id/forward'; // POST {conversation_ids: [≤5]}
  static String messageStar(String id) =>
      '$apiV1/messages/$id/star'; // PUT star / DELETE unstar (private)
  static const String messagesStarred =
      '$apiV1/messages/starred'; // GET ?cursor=&limit= across conversations
  static const String linkPreview = '$apiV1/link-preview'; // GET ?url=
  // Batch 5 (media)
  static String messageUploadIntent(String convId) =>
      '$apiV1/messages/upload-intent/$convId'; // POST → presigned URLs
  static String messageUploadComplete(String convId) =>
      '$apiV1/messages/upload-complete/$convId'; // POST → MessageOut
  static String messageExportAudit(String id) =>
      '$apiV1/messages/$id/export-audit'; // POST before save / share
  static String messageVote(String id) =>
      '$apiV1/messages/$id/vote'; // PUT {option_ids} / DELETE (own votes)
  static String conversationMedia(String id) =>
      '$apiV1/conversations/$id/media'; // GET ?type=image|video|file|link&cursor=

  // People / profiles (networking M1/M2)
  static String userProfile(String userId) => '$apiV1/users/$userId/profile';
  static const String peopleSearch = '$apiV1/people/search';
  static const String npiLookup = '$apiV1/people/npi-lookup';
  static const String appInvites = '$apiV1/people/invites';

  // Network graph (M1)
  static const String invitations = '$apiV1/network/invitations';
  static String invitationAccept(String id) =>
      '$apiV1/network/invitations/$id/accept';
  static String invitationIgnore(String id) =>
      '$apiV1/network/invitations/$id/ignore';
  static String invitation(String id) => '$apiV1/network/invitations/$id';
  static const String connections = '$apiV1/network/connections';
  static String connection(String userId) =>
      '$apiV1/network/connections/$userId';
  static String mutualConnections(String userId) =>
      '$apiV1/network/connections/mutual/$userId';
  static String block(String userId) => '$apiV1/network/blocks/$userId';
  static const String blocks = '$apiV1/network/blocks';
  // Mute a person: no pushes or banners from them, anywhere (M1 table).
  static const String mutes = '$apiV1/network/mutes';
  static String mute(String userId) => '$apiV1/network/mutes/$userId';
  static const String reports = '$apiV1/network/reports';
  static const String suggestions = '$apiV1/network/suggestions';
  static String suggestionDismiss(String userId) =>
      '$apiV1/network/suggestions/$userId/dismiss';

  // Privacy settings (M1 + batch 2)
  static const String usersMePrivacy = '$apiV1/users/me/privacy';
  // Presence + last seen for up to 50 users, privacy-filtered (batch 2).
  static const String usersPresence = '$apiV1/users/presence';

  // Notifications (M1)
  static const String notifications = '$apiV1/notifications';
  static const String notificationsRead = '$apiV1/notifications/read';
  static const String notificationsUnreadCount =
      '$apiV1/notifications/unread-count';

  // Groups (M5) — router mounted at /api/v1.
  static const String groups = '$apiV1/groups';
  static String group(String id) => '$apiV1/groups/$id';
  static String groupAvatar(String id) => '$apiV1/groups/$id/avatar';
  static String groupInvites(String id) => '$apiV1/groups/$id/invites';
  static String groupInvite(String groupId, String inviteId) =>
      '$apiV1/groups/$groupId/invites/$inviteId';
  static String groupInviteAccept(String groupId, String inviteId) =>
      '$apiV1/groups/$groupId/invites/$inviteId/accept';
  static String groupInviteDecline(String groupId, String inviteId) =>
      '$apiV1/groups/$groupId/invites/$inviteId/decline';
  static String groupInviteTokenAccept(String token) =>
      '$apiV1/group-invites/$token/accept';
  static String groupMembers(String id) => '$apiV1/groups/$id/members';
  static String groupMember(String groupId, String userId) =>
      '$apiV1/groups/$groupId/members/$userId';
  static String groupMemberBan(String groupId, String userId) =>
      '$apiV1/groups/$groupId/members/$userId/ban';
  static String groupTransferOwnership(String id) =>
      '$apiV1/groups/$id/transfer-ownership';
  static const String meGroups = '$apiV1/me/groups';


  // Audit (batch 6): iOS reports a detected screenshot of a chat.
  static const String auditScreenshot = '$apiV1/audit/screenshot';

  // App metadata (batch 6) — unauthenticated.
  static const String appMinVersion = '$apiV1/app/min-version';
  static const String appLegal = '$apiV1/app/legal';

  // Admin endpoints live in the separate Next.js admin panel — not in the mobile app.

  // WebSocket — user-scoped (A1): one socket per signed-in user, org or not.
  static const String ws = '/ws';
}
