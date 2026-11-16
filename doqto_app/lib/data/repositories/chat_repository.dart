import 'dart:convert';

import '../../core/constants/api_routes.dart';
import '../../core/enums/app_enums.dart';
import '../api/api_client.dart';
import '../models/conversation.dart';
import '../models/conversation_prefs.dart';
import '../models/media.dart';
import '../models/message.dart';
import '../models/message_edit.dart';
import '../models/network_profile.dart' show CursorPage;

class ChatRepository {
  final ApiClient _api;
  ChatRepository(this._api);

  Future<List<Conversation>> listConversations() async {
    final list = await _api.getList(ApiRoutes.conversations);
    return list
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Partial update of my private view of a chat. [patch] carries wire
  /// field names (`pinned`, `archived`, `muted_until`, `marked_unread`,
  /// `clear_chat`, `delete_chat`, …); the server returns the full prefs.
  Future<ConversationPrefs> updatePrefs(
    String conversationId,
    Map<String, dynamic> patch,
  ) async {
    final j = await _api.patch(
      ApiRoutes.conversationPrefs(conversationId),
      body: patch,
    );
    return ConversationPrefs.fromJson(j);
  }

  /// Unread across my chats minus muted / archived ones — the icon badge.
  Future<int> unreadTotal() async {
    final j = await _api.get(ApiRoutes.conversationsUnreadTotal);
    return (j['total'] as num?)?.toInt() ?? 0;
  }

  Future<Conversation> createConversation({
    required ConversationType type,
    String? name,
    required List<String> memberIds,
  }) async {
    final j = await _api.post(
      ApiRoutes.conversations,
      body: {'type': type.wire, 'name': name, 'member_ids': memberIds},
    );
    return Conversation.fromJson(j);
  }

  /// [before] pages backwards (history); [afterSeq] pages forwards in seq
  /// order (catch-up after offline). The server rejects both together.
  /// [beforeDate] (jump to date, batch 4) returns the usual descending page
  /// ending at the end of that UTC day; exclusive with [before].
  Future<List<Message>> listMessages(
    String conversationId, {
    DateTime? before,
    int? afterSeq,
    DateTime? changedSince,
    DateTime? beforeDate,
  }) async {
    final query = <String, dynamic>{
      'before': ?before?.toUtc().toIso8601String(),
      'after_seq': ?afterSeq,
      'changed_since': ?changedSince?.toUtc().toIso8601String(),
      if (beforeDate != null)
        'before_date':
            '${beforeDate.year.toString().padLeft(4, '0')}-${beforeDate.month.toString().padLeft(2, '0')}-${beforeDate.day.toString().padLeft(2, '0')}',
    };
    final list = await _api.getList(
      ApiRoutes.conversationMessages(conversationId),
      query: query.isEmpty ? null : query,
    );
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// [replyToId] quotes a live message of the same conversation
  /// (422 `reply_target_invalid` otherwise).
  Future<Message> sendText(
    String conversationId,
    String content, {
    String? clientId,
    String? replyToId,
  }) async {
    final j = await _api.post(
      ApiRoutes.conversationMessages(conversationId),
      body: {
        'type': MessageType.text.wire,
        'content': content,
        // Outbox idempotency key — retries return the original row.
        'client_id': ?clientId,
        'reply_to_id': ?replyToId,
      },
    );
    return Message.fromJson(j);
  }

  // ---- Batch 4 -------------------------------------------------------------

  /// Copy a message into up to five chats; one new row per destination.
  Future<List<Message>> forward(String messageId, List<String> conversationIds) async {
    final r = await _api.postList(
      ApiRoutes.messageForward(messageId),
      body: {'conversation_ids': conversationIds},
    );
    return [for (final e in r) Message.fromJson((e as Map).cast<String, dynamic>())];
  }

  /// Star / unstar for me only. Idempotent; returns the row with `starred`.
  Future<Message> setStarred(String messageId, bool starred) async {
    final j = starred
        ? await _api.put(ApiRoutes.messageStar(messageId))
        : await _api.delete(ApiRoutes.messageStar(messageId));
    return Message.fromJson(j);
  }

  /// My starred messages across every chat, newest star first.
  Future<CursorPage<StarredMessage>> starred({String? cursor, int? limit}) async {
    final j = await _api.get(ApiRoutes.messagesStarred, query: {
      'cursor': ?cursor,
      'limit': ?limit,
    });
    return CursorPage(
      [
        for (final e in (j['data'] as List? ?? const []))
          StarredMessage.fromJson((e as Map).cast<String, dynamic>()),
      ],
      j['next_cursor'] as String?,
    );
  }

  /// Pin [messageId] for everyone for [durationSec] (24 h / 7 d / 30 d).
  Future<Conversation> pinMessage(
    String conversationId,
    String messageId,
    int durationSec,
  ) async {
    final j = await _api.put(
      ApiRoutes.conversationPin(conversationId),
      body: {'message_id': messageId, 'duration_sec': durationSec},
    );
    return Conversation.fromJson(j);
  }

  Future<Conversation> unpinMessage(String conversationId) async {
    final j = await _api.delete(ApiRoutes.conversationPin(conversationId));
    return Conversation.fromJson(j);
  }

  /// Server-side link preview (SSRF-guarded, image proxied as base64).
  Future<LinkPreview> linkPreview(String url) async {
    final j = await _api.get(ApiRoutes.linkPreview, query: {'url': url});
    return LinkPreview.fromJson(j);
  }

  /// Queue [content] for future delivery. [scheduledLocal] is the wall-clock
  /// time in [timezone] (IANA name); the server resolves the UTC instant.
  Future<void> scheduleText(
    String conversationId,
    String content, {
    required String scheduledLocal,
    required String timezone,
  }) async {
    await _api.post(
      ApiRoutes.conversationScheduleMessage(conversationId),
      body: {
        'content': content,
        'scheduled_local': scheduledLocal,
        'timezone': timezone,
      },
    );
  }

  /// Inline upload (≤ 25 MB). [caption] rides under the media; a video may
  /// carry its JPEG poster in [thumb] plus [durationSec] / [width] / [height].
  Future<Message> uploadFile({
    required String conversationId,
    required List<int> bytes,
    required String filename,
    String? contentType,
    String? clientId,
    String? caption,
    List<int>? thumb,
    int? durationSec,
    int? width,
    int? height,
  }) async {
    final j = await _api.postMultipart(
      ApiRoutes.messageUpload(conversationId),
      fileField: 'file',
      bytes: bytes,
      filename: filename,
      // Server classifies IMAGE / VIDEO / FILE from this MIME type.
      contentType: contentType,
      extraFiles: thumb == null
          ? null
          : {'thumb': (bytes: thumb, filename: 'poster.jpg', contentType: 'image/jpeg')},
      fields: {
        // Outbox idempotency key — retries return the original row.
        'client_id': ?clientId,
        if (caption != null && caption.isNotEmpty) 'caption': caption,
        'duration_sec': ?durationSec,
        'width': ?width,
        'height': ?height,
      },
    );
    return Message.fromJson(j);
  }

  /// [waveform] is the ≤ 64 amplitude bytes (base64 on the wire).
  Future<Message> uploadVoiceNote({
    required String conversationId,
    required List<int> bytes,
    required String filename,
    required int durationSec,
    String? transcript,
    String? clientId,
    List<int>? waveform,
    String? caption,
  }) async {
    final j = await _api.postMultipart(
      ApiRoutes.messageVoiceNote(conversationId),
      fileField: 'file',
      bytes: bytes,
      filename: filename,
      fields: {
        'duration_sec': durationSec,
        if (transcript != null && transcript.isNotEmpty)
          'transcript': transcript,
        // Outbox idempotency key — retries return the original row.
        'client_id': ?clientId,
        if (waveform != null && waveform.isNotEmpty) 'waveform': base64Encode(waveform),
        if (caption != null && caption.isNotEmpty) 'caption': caption,
      },
    );
    return Message.fromJson(j);
  }

  // ---- Batch 5: presigned upload, gallery, export, polls -----------------

  /// Step 1 of a large upload: presigned PUT URL(s) for [sizeBytes] of
  /// [contentType]. [withThumb] (video) adds a poster PUT URL.
  Future<UploadIntent> uploadIntent(
    String conversationId, {
    required String fileName,
    required String contentType,
    required int sizeBytes,
    String? clientId,
    bool withThumb = false,
  }) async {
    final j = await _api.post(
      ApiRoutes.messageUploadIntent(conversationId),
      body: {
        'file_name': fileName,
        'content_type': contentType,
        'size_bytes': sizeBytes,
        'client_id': ?clientId,
        'with_thumb': withThumb,
      },
    );
    return UploadIntent.fromJson(j);
  }

  /// PUT [bytes] to one presigned URL; returns the ETag.
  Future<String> putPresigned(
    String url,
    List<int> bytes, {
    required String contentType,
    void Function(int sent, int total)? onProgress,
  }) =>
      _api.putToUrl(url, bytes, contentType: contentType, onProgress: onProgress);

  /// Step 2: the object is in S3 — create the message.
  Future<Message> uploadComplete(
    String conversationId, {
    required String intentId,
    List<(int, String)> parts = const [],
    String? caption,
    int? durationSec,
    int? width,
    int? height,
    bool hasThumb = false,
  }) async {
    final j = await _api.post(
      ApiRoutes.messageUploadComplete(conversationId),
      body: {
        'intent_id': intentId,
        'parts': [
          for (final (n, etag) in parts) {'part_number': n, 'etag': etag},
        ],
        if (caption != null && caption.isNotEmpty) 'caption': caption,
        'duration_sec': ?durationSec,
        'width': ?width,
        'height': ?height,
        'has_thumb': hasThumb,
      },
    );
    return Message.fromJson(j);
  }

  /// Photos / videos / documents / links of one chat, newest first.
  Future<CursorPage<MediaGalleryItem>> listMedia(
    String conversationId,
    MediaKind kind, {
    String? cursor,
    int? limit,
  }) async {
    final j = await _api.get(ApiRoutes.conversationMedia(conversationId), query: {
      'type': kind.wire,
      'cursor': ?cursor,
      'limit': ?limit,
    });
    return CursorPage(
      [
        for (final e in (j['data'] as List? ?? const []))
          MediaGalleryItem.fromJson((e as Map).cast<String, dynamic>()),
      ],
      j['next_cursor'] as String?,
    );
  }

  /// Audit a save / share BEFORE doing it. 403 `media_export_blocked` means
  /// the org forbids it — do not export.
  Future<void> exportAudit(String messageId) async {
    await _api.post(ApiRoutes.messageExportAudit(messageId));
  }

  /// Create a poll: 2–12 options, optionally multiple choice.
  Future<Message> sendPoll(
    String conversationId, {
    required String question,
    required List<String> options,
    bool multiple = false,
    String? clientId,
    String? replyToId,
  }) async {
    final j = await _api.post(
      ApiRoutes.conversationMessages(conversationId),
      body: {
        'type': MessageType.poll.wire,
        'poll': {'question': question, 'options': options, 'multiple': multiple},
        'client_id': ?clientId,
        'reply_to_id': ?replyToId,
      },
    );
    return Message.fromJson(j);
  }

  /// Replace my selection ([optionIds] empty = withdraw every vote).
  Future<Message> vote(String messageId, List<String> optionIds) async {
    final j = optionIds.isEmpty
        ? await _api.delete(ApiRoutes.messageVote(messageId))
        : await _api.put(ApiRoutes.messageVote(messageId), body: {'option_ids': optionIds});
    return Message.fromJson(j);
  }

  /// Sender-only, within 15 min of sending; the server keeps the history.
  Future<Message> editMessage(String messageId, String content) async {
    final j = await _api.patch(
      ApiRoutes.message(messageId),
      body: {'content': content},
    );
    return Message.fromJson(j);
  }

  /// Add or replace my one reaction. Same emoji again is a server no-op.
  Future<Message> setReaction(String messageId, String emoji) async {
    final j = await _api.put(
      ApiRoutes.messageReaction(messageId),
      body: {'emoji': emoji},
    );
    return Message.fromJson(j);
  }

  /// Remove my reaction (no-op if I had none).
  Future<Message> removeReaction(String messageId) async {
    final j = await _api.delete(ApiRoutes.messageReaction(messageId));
    return Message.fromJson(j);
  }

  /// Sender within 48 h, or a group admin at any age; returns the tombstone.
  Future<Message> deleteMessage(String messageId) async {
    final j = await _api.delete(ApiRoutes.message(messageId));
    return Message.fromJson(j);
  }

  /// "Delete for me": hides for this user only; any message, any age.
  Future<void> hideMessages(List<String> messageIds) async {
    await _api.post(ApiRoutes.messagesHide, body: {'message_ids': messageIds});
  }

  /// Previous versions, oldest first — any member may read them.
  Future<List<MessageEdit>> messageEdits(String messageId) async {
    final list = await _api.getList(ApiRoutes.messageEdits(messageId));
    return list
        .map((e) => MessageEdit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> markRead(String messageId) async {
    await _api.post(ApiRoutes.messageRead(messageId));
  }

  Future<void> markConversationRead(String conversationId) async {
    await _api.post(ApiRoutes.conversationRead(conversationId));
  }

  /// Ack receipt → sender's gray double-check. Fire on message arrival.
  Future<void> markConversationDelivered(String conversationId) async {
    await _api.post(ApiRoutes.conversationDelivered(conversationId));
  }

  /// Message info: who my message reached and who read it (sender-only).
  Future<List<MessageReceipt>> messageReceipts(String messageId) async {
    final list = await _api.getList(ApiRoutes.messageReceipts(messageId));
    return list
        .map((e) => MessageReceipt.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// Presigned GET of the media object, or of the video poster with [thumb].
  Future<String> fileUrl(String messageId, {bool thumb = false}) async {
    final j = await _api.get(
      ApiRoutes.messageFileUrl(messageId),
      query: thumb ? {'thumb': 1} : null,
    );
    return j['url'] as String;
  }

  Future<void> addMembers(String conversationId, List<String> userIds) async {
    await _api.patch(
      ApiRoutes.conversationMembers(conversationId),
      body: {'user_ids': userIds},
    );
  }

  Future<void> removeMember(String conversationId, String userId) async {
    await _api.delete(ApiRoutes.conversationMember(conversationId, userId));
  }

  Future<void> updateSettings(
    String conversationId, {
    int? disappearAfterSec,
  }) async {
    await _api.patch(
      ApiRoutes.conversationSettings(conversationId),
      body: {'disappear_after_sec': disappearAfterSec},
    );
  }
}
