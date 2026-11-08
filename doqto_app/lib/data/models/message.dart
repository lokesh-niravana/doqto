import '../../core/enums/app_enums.dart';

/// Client-side send lifecycle (not a wire enum — the server only ever returns
/// persisted messages, which are always [sent]).
enum MessageStatus { sending, sent, failed }

/// One emoji on a message and who chose it (oldest first). Wire shape of the
/// server's `ReactionOut`; the same for every viewer.
class MessageReaction {
  final String emoji;
  final List<String> userIds;

  const MessageReaction({required this.emoji, required this.userIds});

  int get count => userIds.length;

  factory MessageReaction.fromJson(Map<String, dynamic> j) => MessageReaction(
        emoji: j['emoji'] as String,
        userIds: [for (final u in (j['user_ids'] as List? ?? const [])) u as String],
      );

  Map<String, dynamic> toJson() =>
      {'emoji': emoji, 'count': count, 'user_ids': userIds};

  static List<MessageReaction> listFromJson(Object? raw) => [
        for (final r in (raw as List? ?? const []))
          MessageReaction.fromJson(r as Map<String, dynamic>),
      ];

  /// The list after [me] picks [emoji] (null = remove): one reaction per
  /// person, empty groups dropped, sorted by count desc then first-seen —
  /// the same order the server returns, so the optimistic update and the
  /// confirmed one don't reshuffle the pill.
  static List<MessageReaction> apply(
    List<MessageReaction> current,
    String me,
    String? emoji,
  ) {
    final out = <MessageReaction>[];
    var added = false;
    for (final r in current) {
      final ids = [for (final u in r.userIds) if (u != me) u];
      if (r.emoji == emoji) {
        ids.add(me);
        added = true;
      }
      if (ids.isNotEmpty) out.add(MessageReaction(emoji: r.emoji, userIds: ids));
    }
    if (emoji != null && !added) {
      out.add(MessageReaction(emoji: emoji, userIds: [me]));
    }
    // List.sort isn't guaranteed stable; sort by (count desc, original index).
    final indexed = out.asMap().entries.toList()
      ..sort((a, b) {
        final c = b.value.count.compareTo(a.value.count);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return [for (final e in indexed) e.value];
  }
}

/// One recipient's delivery/read state for a message I sent (message info).
/// Mirrors backend MessageReceiptOut. Group chats derive it from member read
/// cursors, so [deliveredAt] may be null even when [delivered] is true.
class MessageReceipt {
  final String userId;
  final String fullName;
  final String? avatarColor;
  final String? avatarPresignedUrl;
  final bool delivered;
  final bool read;
  final DateTime? deliveredAt;
  final DateTime? readAt;

  const MessageReceipt({
    required this.userId,
    required this.fullName,
    required this.avatarColor,
    required this.avatarPresignedUrl,
    required this.delivered,
    required this.read,
    required this.deliveredAt,
    required this.readAt,
  });

  factory MessageReceipt.fromJson(Map<String, dynamic> j) => MessageReceipt(
        userId: (j['user_id'] ?? '') as String,
        fullName: (j['full_name'] ?? '') as String,
        avatarColor: j['avatar_color'] as String?,
        avatarPresignedUrl: j['avatar_presigned_url'] as String?,
        delivered: (j['delivered'] as bool?) ?? false,
        read: (j['read'] as bool?) ?? false,
        deliveredAt: j['delivered_at'] != null
            ? DateTime.tryParse(j['delivered_at'] as String)
            : null,
        readAt: j['read_at'] != null
            ? DateTime.tryParse(j['read_at'] as String)
            : null,
      );
}

/// The quoted message on a reply, rendered live by the server from the
/// target's current row (`ReplyPreviewOut`). [preview] is "Message deleted"
/// for a tombstone; the whole object is null once the target expired.
class ReplyPreview {
  final String id;
  final String senderId;
  final MessageType type;
  final String? preview;

  const ReplyPreview({
    required this.id,
    required this.senderId,
    required this.type,
    required this.preview,
  });

  factory ReplyPreview.fromJson(Map<String, dynamic> j) => ReplyPreview(
        id: j['id'] as String,
        senderId: j['sender_id'] as String,
        type: MessageType.fromWire((j['type'] as String?) ?? 'text'),
        preview: j['preview'] as String?,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'sender_id': senderId, 'type': type.wire, 'preview': preview};

  /// What the quote strip shows for a target of this [type].
  static String previewFor(Message m) {
    if (m.isDeleted) return 'Message deleted';
    return switch (m.type) {
      MessageType.image => 'Photo',
      MessageType.voiceNote => 'Voice note',
      MessageType.file => m.fileName ?? 'File',
      _ => (m.content ?? '').length > 140
          ? (m.content ?? '').substring(0, 140)
          : (m.content ?? ''),
    };
  }

  factory ReplyPreview.of(Message m) => ReplyPreview(
        id: m.id,
        senderId: m.senderId,
        type: m.type,
        preview: previewFor(m),
      );
}

/// One row of GET /messages/starred: the message plus where it lives.
class StarredMessage {
  final Message message;
  final String conversationId;
  final ConversationType conversationType;
  final String? conversationName;
  final DateTime starredAt;

  const StarredMessage({
    required this.message,
    required this.conversationId,
    required this.conversationType,
    required this.conversationName,
    required this.starredAt,
  });

  factory StarredMessage.fromJson(Map<String, dynamic> j) => StarredMessage(
        message: Message.fromJson((j['message'] as Map).cast<String, dynamic>()),
        conversationId: j['conversation_id'] as String,
        conversationType:
            ConversationType.fromWire((j['conversation_type'] as String?) ?? 'direct'),
        conversationName: j['conversation_name'] as String?,
        starredAt: DateTime.parse(j['starred_at'] as String),
      );
}

/// GET /link-preview — fetched server-side, image proxied as a data: URL.
class LinkPreview {
  final String url;
  final String? title;
  final String? description;
  final String? siteName;
  final String? imageDataUrl;

  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.siteName,
    this.imageDataUrl,
  });

  bool get isEmpty => title == null && description == null && imageDataUrl == null;

  factory LinkPreview.fromJson(Map<String, dynamic> j) => LinkPreview(
        url: (j['url'] ?? '') as String,
        title: j['title'] as String?,
        description: j['description'] as String?,
        siteName: j['site_name'] as String?,
        imageDataUrl: j['image_data_url'] as String?,
      );
}

class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final MessageType type;
  final String? content;
  final String? s3Key;
  final String? fileName;
  final int? fileSizeBytes;
  final int? voiceDurationSec;
  final String? transcript;
  final TranscriptStatus transcriptStatus;
  final DateTime? expiresAt;
  final DateTime createdAt;
  final bool read;
  final bool delivered;
  final MessageStatus status;
  final String? clientId; // outbox idempotency key (echoed by the server)
  final int? seq; // per-conversation sequence (null for pending/legacy cache)
  final DateTime? editedAt; // sender edited the body (history on the server)
  final DateTime? deletedAt; // tombstone: content/media gone, row kept
  final List<MessageReaction> reactions;
  // Last post-send change (edit/delete/reaction) — catch-up cursor and the
  // staleness check for out-of-order `message_reacted` events.
  final DateTime? changedAt;
  // Outbox media file on disk — lets pending image bubbles show a real
  // preview instead of a filename. Never serialized; rebuilt from the outbox.
  final String? localPath;
  // Batch 4. [replyTo] is the server's live rendering of the quoted row.
  final String? replyToId;
  final ReplyPreview? replyTo;
  final bool forwarded;
  final int forwardDepth;
  final List<String> mentions; // user ids named with `@[uuid]` in the body
  final bool starred; // by me — the only per-viewer field

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    required this.content,
    required this.s3Key,
    required this.fileName,
    required this.fileSizeBytes,
    required this.voiceDurationSec,
    required this.transcript,
    required this.transcriptStatus,
    required this.expiresAt,
    required this.createdAt,
    this.read = false,
    this.delivered = false,
    this.status = MessageStatus.sent,
    this.clientId,
    this.seq,
    this.localPath,
    this.editedAt,
    this.deletedAt,
    this.reactions = const [],
    this.changedAt,
    this.replyToId,
    this.replyTo,
    this.forwarded = false,
    this.forwardDepth = 0,
    this.mentions = const [],
    this.starred = false,
  });

  /// Sender may edit a text message this long after sending (server-enforced).
  static const editWindow = Duration(minutes: 15);

  /// Sender may delete any message this long after sending (server-enforced).
  /// Group admins are not bound by it (see [canDelete]).
  static const deleteWindow = Duration(hours: 48);

  /// Copies at this depth cannot be forwarded again (server `forward_limit`).
  static const forwardMaxDepth = 5;

  /// "Forwarded many times" once a copy has travelled this far.
  bool get forwardedManyTimes => forwarded && forwardDepth >= forwardMaxDepth;
  bool get canForward =>
      type != MessageType.system &&
      !isDeleted &&
      status == MessageStatus.sent &&
      seq != null &&
      forwardDepth < forwardMaxDepth;

  /// Live, persisted, non-system rows can be starred / pinned / replied to.
  bool get canStar => canReact;
  bool get canPin => canReact;
  bool get canReply => canReact;

  bool get isDeleted => deletedAt != null;

  /// Only persisted, live, non-system rows take reactions (server-enforced).
  bool get canReact =>
      type != MessageType.system &&
      !isDeleted &&
      status == MessageStatus.sent &&
      seq != null;

  /// The emoji [me] reacted with, if any.
  String? myReaction(String me) {
    for (final r in reactions) {
      if (r.userIds.contains(me)) return r.emoji;
    }
    return null;
  }

  bool _own(String me, DateTime now, Duration window) =>
      senderId == me &&
      !isDeleted &&
      status == MessageStatus.sent &&
      !now.difference(createdAt).isNegative &&
      now.difference(createdAt) <= window;

  bool canEdit({required String me, DateTime? now}) =>
      type == MessageType.text &&
      _own(me, (now ?? DateTime.now()).toUtc(), editWindow);

  /// Sender within [deleteWindow]; a group admin ([isAdmin]) at any age.
  bool canDelete({required String me, DateTime? now, bool isAdmin = false}) {
    if (type == MessageType.system || isDeleted || status != MessageStatus.sent) {
      return false;
    }
    if (isAdmin && seq != null) return true;
    return _own(me, (now ?? DateTime.now()).toUtc(), deleteWindow);
  }

  /// Optimistic local message (text, media, or voice): shown with a clock tick
  /// while the outbox delivers it. `id` is the clientId until the server row
  /// replaces it.
  factory Message.pending({
    required String clientId,
    required String conversationId,
    required String senderId,
    String? content,
    MessageType type = MessageType.text,
    String? fileName,
    int? voiceDurationSec,
    String? transcript,
    MessageStatus status = MessageStatus.sending,
    String? localPath,
    ReplyPreview? replyTo,
  }) =>
      Message(
        id: clientId,
        conversationId: conversationId,
        senderId: senderId,
        type: type,
        content: content,
        s3Key: null,
        fileName: fileName,
        fileSizeBytes: null,
        voiceDurationSec: voiceDurationSec,
        transcript: transcript,
        transcriptStatus: TranscriptStatus.none,
        expiresAt: null,
        createdAt: DateTime.now().toUtc(),
        status: status,
        clientId: clientId,
        localPath: localPath,
        replyToId: replyTo?.id,
        replyTo: replyTo,
      );

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id'] as String,
        conversationId: j['conversation_id'] as String,
        senderId: j['sender_id'] as String,
        type: MessageType.fromWire(j['type'] as String),
        content: j['content'] as String?,
        s3Key: j['s3_key'] as String?,
        fileName: j['file_name'] as String?,
        fileSizeBytes: j['file_size_bytes'] as int?,
        voiceDurationSec: j['voice_duration_sec'] as int?,
        transcript: j['transcript'] as String?,
        transcriptStatus:
            TranscriptStatus.fromWire((j['transcript_status'] as String?) ?? 'none'),
        expiresAt: j['expires_at'] != null ? DateTime.parse(j['expires_at'] as String) : null,
        createdAt: DateTime.parse(j['created_at'] as String),
        read: (j['read'] as bool?) ?? false,
        delivered: (j['delivered'] as bool?) ?? false,
        clientId: j['client_id'] as String?,
        seq: j['seq'] as int?,
        editedAt: j['edited_at'] != null ? DateTime.parse(j['edited_at'] as String) : null,
        deletedAt: j['deleted_at'] != null ? DateTime.parse(j['deleted_at'] as String) : null,
        reactions: MessageReaction.listFromJson(j['reactions']),
        changedAt: j['changed_at'] != null ? DateTime.parse(j['changed_at'] as String) : null,
        replyToId: j['reply_to_id'] as String?,
        replyTo: j['reply_to'] is Map
            ? ReplyPreview.fromJson((j['reply_to'] as Map).cast<String, dynamic>())
            : null,
        forwarded: (j['forwarded'] as bool?) ?? false,
        forwardDepth: (j['forward_depth'] as num?)?.toInt() ?? 0,
        mentions: [for (final u in (j['mentions'] as List? ?? const [])) u.toString()],
        starred: (j['starred'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversation_id': conversationId,
        'sender_id': senderId,
        'type': type.wire,
        'content': content,
        's3_key': s3Key,
        'file_name': fileName,
        'file_size_bytes': fileSizeBytes,
        'voice_duration_sec': voiceDurationSec,
        'transcript': transcript,
        'transcript_status': transcriptStatus.wire,
        'expires_at': expiresAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'read': read,
        'delivered': delivered,
        'client_id': clientId,
        'seq': seq,
        'edited_at': editedAt?.toIso8601String(),
        'deleted_at': deletedAt?.toIso8601String(),
        'reactions': [for (final r in reactions) r.toJson()],
        'changed_at': changedAt?.toIso8601String(),
        'reply_to_id': replyToId,
        'reply_to': replyTo?.toJson(),
        'forwarded': forwarded,
        'forward_depth': forwardDepth,
        'mentions': mentions,
        'starred': starred,
      };

  Message copyWith({
    String? transcript,
    TranscriptStatus? transcriptStatus,
    bool? read,
    bool? delivered,
    MessageStatus? status,
    List<MessageReaction>? reactions,
    DateTime? changedAt,
    bool? starred,
    ReplyPreview? replyTo,
  }) =>
      Message(
        id: id,
        conversationId: conversationId,
        senderId: senderId,
        type: type,
        content: content,
        s3Key: s3Key,
        fileName: fileName,
        fileSizeBytes: fileSizeBytes,
        voiceDurationSec: voiceDurationSec,
        transcript: transcript ?? this.transcript,
        transcriptStatus: transcriptStatus ?? this.transcriptStatus,
        expiresAt: expiresAt,
        createdAt: createdAt,
        read: read ?? this.read,
        delivered: delivered ?? this.delivered,
        status: status ?? this.status,
        clientId: clientId,
        seq: seq,
        localPath: localPath,
        editedAt: editedAt,
        deletedAt: deletedAt,
        reactions: reactions ?? this.reactions,
        changedAt: changedAt ?? this.changedAt,
        replyToId: replyToId,
        replyTo: replyTo ?? this.replyTo,
        forwarded: forwarded,
        forwardDepth: forwardDepth,
        mentions: mentions,
        starred: starred ?? this.starred,
      );
}
