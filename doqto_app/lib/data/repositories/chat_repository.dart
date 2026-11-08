import '../../core/constants/api_routes.dart';
import '../../core/enums/app_enums.dart';
import '../api/api_client.dart';
import '../models/conversation.dart';
import '../models/message.dart';
import '../models/message_edit.dart';

class ChatRepository {
  final ApiClient _api;
  ChatRepository(this._api);

  Future<List<Conversation>> listConversations() async {
    final list = await _api.getList(ApiRoutes.conversations);
    return list
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
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
  Future<List<Message>> listMessages(
    String conversationId, {
    DateTime? before,
    int? afterSeq,
    DateTime? changedSince,
  }) async {
    final query = <String, dynamic>{
      'before': ?before?.toUtc().toIso8601String(),
      'after_seq': ?afterSeq,
      'changed_since': ?changedSince?.toUtc().toIso8601String(),
    };
    final list = await _api.getList(
      ApiRoutes.conversationMessages(conversationId),
      query: query.isEmpty ? null : query,
    );
    return list
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Message> sendText(
    String conversationId,
    String content, {
    String? clientId,
  }) async {
    final j = await _api.post(
      ApiRoutes.conversationMessages(conversationId),
      body: {
        'type': MessageType.text.wire,
        'content': content,
        // Outbox idempotency key — retries return the original row.
        'client_id': ?clientId,
      },
    );
    return Message.fromJson(j);
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

  Future<Message> uploadFile({
    required String conversationId,
    required List<int> bytes,
    required String filename,
    String? contentType,
    String? clientId,
  }) async {
    final j = await _api.postMultipart(
      ApiRoutes.messageUpload(conversationId),
      fileField: 'file',
      bytes: bytes,
      filename: filename,
      // Server classifies IMAGE vs FILE from this MIME type.
      contentType: contentType,
      fields: {
        // Outbox idempotency key — retries return the original row.
        'client_id': ?clientId,
      },
    );
    return Message.fromJson(j);
  }

  Future<Message> uploadVoiceNote({
    required String conversationId,
    required List<int> bytes,
    required String filename,
    required int durationSec,
    String? transcript,
    String? clientId,
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
      },
    );
    return Message.fromJson(j);
  }

  /// Sender-only, within 5 min of sending; the server keeps the history.
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

  /// Sender-only, within 3 min of sending; returns the tombstone row.
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

  Future<String> fileUrl(String messageId) async {
    final j = await _api.get(ApiRoutes.messageFileUrl(messageId));
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
