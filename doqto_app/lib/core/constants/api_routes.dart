/// API route paths — mirrored from app/core/routes.py on the backend.
class ApiRoutes {
  ApiRoutes._();

  static const String apiV1 = '/api/v1';

  // Auth
  static const String authFirebase = '$apiV1/auth/firebase';
  static const String authRefresh = '$apiV1/auth/refresh';
  static const String authLogout = '$apiV1/auth/logout';
  static const String authRegister = '$apiV1/auth/register';

  // Users
  static const String usersMe = '$apiV1/users/me';
  static const String usersMeAvatar = '$apiV1/users/me/avatar';
  static const String usersMePushTokens = '$apiV1/users/me/push-tokens';
  // Attach a phone to the signed-in account. NOT YET ON THE BACKEND — see
  // docs/phone-verification.md for the contract.
  static const String usersMePhone = '$apiV1/users/me/phone';

  // Orgs
  static const String orgs = '$apiV1/orgs';
  static const String orgsJoin = '$apiV1/orgs/join';
  static const String orgsMine = '$apiV1/orgs/mine';
  static String orgDetail(String id) => '$apiV1/orgs/$id';
  static String orgMembers(String id) => '$apiV1/orgs/$id/members';
  static String orgMember(String orgId, String userId) =>
      '$apiV1/orgs/$orgId/members/$userId';
  static String orgInviteCode(String id) => '$apiV1/orgs/$id/invite-code';

  // Conversations
  static const String conversations = '$apiV1/conversations';
  static String conversationMessages(String id) =>
      '$apiV1/conversations/$id/messages';
  static String conversationScheduleMessage(String id) =>
      '$apiV1/conversations/$id/messages/schedule';
  static String conversationRead(String id) => '$apiV1/conversations/$id/read';
  static String conversationDelivered(String id) =>
      '$apiV1/conversations/$id/delivered';
  static String conversationMembers(String id) =>
      '$apiV1/conversations/$id/members';
  static String conversationMember(String convId, String userId) =>
      '$apiV1/conversations/$convId/members/$userId';
  static String conversationSettings(String id) =>
      '$apiV1/conversations/$id/settings';

  // Messages
  static String messageUpload(String convId) =>
      '$apiV1/messages/upload/$convId';
  static String messageVoiceNote(String convId) =>
      '$apiV1/messages/voice-notes/$convId';
  static String messageRead(String id) => '$apiV1/messages/$id/read';
  static String message(String id) =>
      '$apiV1/messages/$id'; // PATCH edit / DELETE
  static String messageEdits(String id) => '$apiV1/messages/$id/edits';
  static const String messagesHide =
      '$apiV1/messages/hide'; // POST delete-for-me
  static String messageFileUrl(String id) => '$apiV1/messages/$id/file-url';

  // People / profiles (networking M1/M2)
  static String userProfile(String userId) => '$apiV1/users/$userId/profile';
  static const String peopleSearch = '$apiV1/people/search';

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
  static const String reports = '$apiV1/network/reports';

  // Privacy settings (M1)
  static const String usersMePrivacy = '$apiV1/users/me/privacy';

  // Notifications (M1)
  static const String notifications = '$apiV1/notifications';
  static const String notificationsRead = '$apiV1/notifications/read';
  static const String notificationsUnreadCount =
      '$apiV1/notifications/unread-count';

  // Groups (M5) — router mounted at /api/v1.
  static const String groups = '$apiV1/groups';
  static String group(String id) => '$apiV1/groups/$id';
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

  // Billing
  static const String billing = '$apiV1/billing';
  static const String billingCheckout = '$apiV1/billing/checkout';
  static const String billingPortal = '$apiV1/billing/portal';

  // Admin endpoints live in the separate Next.js admin panel — not in the mobile app.

  // WebSocket
  static String wsOrg(String orgId) => '/ws/$orgId';
}
