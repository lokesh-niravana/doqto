import '../../core/constants/api_routes.dart';
import '../api/api_client.dart';
import '../models/network_profile.dart';

/// All networking-graph + profile endpoints (M1). Every list endpoint returns
/// a `{data, next_cursor}` page; single-object endpoints return the object.
class NetworkRepository {
  final ApiClient _api;
  NetworkRepository(this._api);

  // --- Profiles / search (M2 contracts, consumed by M1 screens) ---

  Future<NetworkProfile> getProfile(String userId) async {
    final j = await _api.get(ApiRoutes.userProfile(userId));
    return NetworkProfile.fromJson(j);
  }

  Future<CursorPage<PersonCard>> searchPeople({
    String? q,
    String? specialty,
    String? state,
    String? degree,
    String? cursor,
    int? limit,
  }) async {
    final j = await _api.get(ApiRoutes.peopleSearch, query: {
      if (q != null && q.isNotEmpty) 'q': q,
      if (specialty != null && specialty.isNotEmpty) 'specialty': specialty,
      if (state != null && state.isNotEmpty) 'state': state,
      if (degree != null && degree.isNotEmpty) 'degree': degree,
      'cursor': ?cursor,
      'limit': ?limit,
    });
    return _page(j, PersonCard.fromJson);
  }

  // --- Invite a colleague ---

  Future<List<NpiHit>> npiLookup(String q, {String? state}) async {
    final j = await _api.getList(ApiRoutes.npiLookup, query: {
      'q': q,
      if (state != null && state.isNotEmpty) 'state': state,
    });
    return j
        .map((e) => NpiHit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Remembered so they're connected to us when they register with this NPI.
  Future<void> recordInvite(String npi) =>
      _api.post(ApiRoutes.appInvites, body: {'npi': npi});

  // --- Recommended for you ---

  Future<CursorPage<PersonCard>> suggestions({String? cursor, int? limit}) async {
    final j = await _api.get(ApiRoutes.suggestions, query: {
      'cursor': ?cursor,
      'limit': ?limit,
    });
    return _page(j, PersonCard.fromJson);
  }

  Future<void> dismissSuggestion(String userId) =>
      _api.post(ApiRoutes.suggestionDismiss(userId));

  // --- Invitations ---

  Future<Invitation> sendInvitation(String recipientId, {String? message}) async {
    final j = await _api.post(ApiRoutes.invitations, body: {
      'recipient_id': recipientId,
      if (message != null && message.isNotEmpty) 'message': message,
    });
    return Invitation.fromJson(j);
  }

  Future<void> acceptInvitation(String invitationId) =>
      _api.post(ApiRoutes.invitationAccept(invitationId));

  Future<void> ignoreInvitation(String invitationId) =>
      _api.post(ApiRoutes.invitationIgnore(invitationId));

  Future<void> withdrawInvitation(String invitationId) =>
      _api.delete(ApiRoutes.invitation(invitationId));

  /// [direction] = 'received' | 'sent'; [status] filters (default 'pending').
  Future<CursorPage<Invitation>> listInvitations({
    String direction = 'received',
    String status = 'pending',
    String? cursor,
  }) async {
    final j = await _api.get(ApiRoutes.invitations, query: {
      'direction': direction,
      'status': status,
      'cursor': ?cursor,
    });
    return _page(j, Invitation.fromJson);
  }

  // --- Connections ---

  Future<CursorPage<PersonCard>> listConnections({String? q, String? cursor}) async {
    final j = await _api.get(ApiRoutes.connections, query: {
      if (q != null && q.isNotEmpty) 'q': q,
      'cursor': ?cursor,
    });
    return _page(j, PersonCard.fromJson);
  }

  Future<void> removeConnection(String userId) =>
      _api.delete(ApiRoutes.connection(userId));

  Future<CursorPage<PersonCard>> mutualConnections(String userId, {String? cursor}) async {
    final j = await _api.get(ApiRoutes.mutualConnections(userId), query: {
      'cursor': ?cursor,
    });
    return _page(j, PersonCard.fromJson);
  }

  // --- Blocks / reports ---

  Future<void> block(String userId) => _api.post(ApiRoutes.block(userId));

  Future<void> unblock(String userId) => _api.delete(ApiRoutes.block(userId));

  /// People I muted (no pushes or banners from them). Ids only.
  Future<List<String>> listMutes() async {
    final list = await _api.getList(ApiRoutes.mutes);
    return [
      for (final e in list)
        if ((e as Map)['muted_user_id'] is String) e['muted_user_id'] as String,
    ];
  }

  Future<void> mute(String userId) => _api.post(ApiRoutes.mute(userId));

  Future<void> unmute(String userId) => _api.delete(ApiRoutes.mute(userId));

  Future<CursorPage<PersonCard>> listBlocks({String? cursor}) async {
    final j = await _api.get(ApiRoutes.blocks, query: {
      'cursor': ?cursor,
    });
    return _page(j, PersonCard.fromJson);
  }

  /// Report a person (default) or, with [subjectType] `message`, a message —
  /// then [contextMessageIds] carries the last few ids in the thread (ids
  /// only, never bodies).
  Future<void> report({
    required String subjectId,
    required String reason,
    String? details,
    String subjectType = 'user',
    List<String>? contextMessageIds,
  }) =>
      _api.post(ApiRoutes.reports, body: {
        'subject_type': subjectType,
        'subject_id': subjectId,
        'reason': reason,
        if (details != null && details.isNotEmpty) 'details': details,
        if (contextMessageIds != null && contextMessageIds.isNotEmpty)
          'context_message_ids': contextMessageIds,
      });

  // --- Privacy settings ---

  Future<PrivacySettings> getPrivacy() async {
    final j = await _api.get(ApiRoutes.usersMePrivacy);
    return PrivacySettings.fromJson(j);
  }

  Future<PrivacySettings> updatePrivacy(PrivacySettings settings) async {
    final j = await _api.patch(ApiRoutes.usersMePrivacy, body: settings.toJson());
    return PrivacySettings.fromJson(j);
  }

  /// PATCH only the fields that changed — the house style for the privacy
  /// screen, so one toggle never re-sends (and never clobbers) the rest.
  Future<PrivacySettings> patchPrivacy(Map<String, dynamic> patch) async {
    final j = await _api.patch(ApiRoutes.usersMePrivacy, body: patch);
    return PrivacySettings.fromJson(j);
  }

  // --- Notifications ---

  Future<CursorPage<Map<String, dynamic>>> listNotifications({String? cursor}) async {
    final j = await _api.get(ApiRoutes.notifications, query: {
      'cursor': ?cursor,
    });
    return _page(j, (m) => m);
  }

  Future<void> markNotificationsRead({List<String>? ids}) =>
      _api.post(ApiRoutes.notificationsRead,
          body: {'ids': ?ids});

  Future<int> unreadCount() async {
    final j = await _api.get(ApiRoutes.notificationsUnreadCount);
    return (j['unread_count'] as num?)?.toInt() ??
        (j['count'] as num?)?.toInt() ??
        0;
  }

  // --- helpers ---

  CursorPage<T> _page<T>(
    Map<String, dynamic> j,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final data = (j['data'] as List? ?? const [])
        .map((e) => fromJson((e as Map).cast<String, dynamic>()))
        .toList();
    return CursorPage(data, j['next_cursor'] as String?);
  }
}
