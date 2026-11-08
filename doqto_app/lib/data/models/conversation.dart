import '../../core/enums/app_enums.dart';
import 'conversation_prefs.dart';

class Conversation {
  final String id;

  /// NULL for every network-scoped conversation — since M0 that includes ALL
  /// direct conversations, so this is nullable on the wire and here.
  final String? orgId;
  final ConversationType type;
  final String? name;
  final String? createdBy;
  final int? disappearAfterSec;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> memberIds;
  final String? displayName; // direct chats: the other member's full name (server-resolved)
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;
  final String? lastMessageSenderId;
  final MessageType? lastMessageType;
  final int unreadCount;

  /// Networking (M0, additive). Read from the LIST endpoint only —
  /// `GET /conversations/{id}` (detail) returns access=null (known backend gap),
  /// so the tier is always sourced from the conversations/requests list.
  /// null/absent = legacy payload; treat as an open (focused) conversation.
  final ConversationAccess? access;

  /// Who opened a pending message request (M4). For a received request this is
  /// the sender; when it equals me, I'm the initiator ("Request sent").
  final String? initiatorId;

  /// True when this conversation lives on the network bus (org_id NULL) rather
  /// than an org (M3/M4). Drives the "not connected" composer banner gate.
  final bool isNetwork;

  /// True when a received message request has been hidden by the recipient
  /// (M4). Hidden requests live under the "Hidden requests" footer, not the
  /// badge count.
  final bool isHidden;

  /// Set when this conversation backs a network group (M5). null otherwise.
  final String? groupId;

  /// My pin / archive / mute / mark-unread state (batch 3). Private to me.
  final ConversationPrefs prefs;

  /// Pinned message (batch 4): shared by every member; null = nothing pinned.
  final String? pinnedMessageId;
  final DateTime? pinnedUntil;

  const Conversation({
    required this.id,
    required this.orgId,
    required this.type,
    required this.name,
    required this.createdBy,
    required this.disappearAfterSec,
    required this.createdAt,
    required this.updatedAt,
    required this.memberIds,
    this.displayName,
    required this.lastMessageAt,
    required this.lastMessagePreview,
    required this.lastMessageSenderId,
    required this.lastMessageType,
    required this.unreadCount,
    this.access,
    this.initiatorId,
    this.isNetwork = false,
    this.isHidden = false,
    this.groupId,
    this.prefs = ConversationPrefs.defaults,
    this.pinnedMessageId,
    this.pinnedUntil,
  });

  /// The pin the thread banner shows — none once it has lapsed.
  String? activePinnedMessageId([DateTime? now]) {
    if (pinnedMessageId == null) return null;
    final until = pinnedUntil;
    if (until != null && !until.isAfter((now ?? DateTime.now()).toUtc())) return null;
    return pinnedMessageId;
  }

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: j['id'] as String,
        orgId: j['org_id'] as String?,
        type: ConversationType.fromWire(j['type'] as String),
        name: j['name'] as String?,
        createdBy: j['created_by'] as String?,
        disappearAfterSec: j['disappear_after_sec'] as int?,
        createdAt: DateTime.parse(j['created_at'] as String),
        updatedAt: DateTime.parse(j['updated_at'] as String),
        memberIds: ((j['member_ids'] ?? []) as List).map((e) => e.toString()).toList(),
        displayName: j['display_name'] as String?,
        lastMessageAt: j['last_message_at'] != null
            ? DateTime.parse(j['last_message_at'] as String)
            : null,
        lastMessagePreview: j['last_message_preview'] as String?,
        lastMessageSenderId: j['last_message_sender_id'] as String?,
        lastMessageType: j['last_message_type'] != null
            ? MessageType.fromWire(j['last_message_type'] as String)
            : null,
        unreadCount: (j['unread_count'] ?? 0) as int,
        access: j['access'] != null
            ? ConversationAccess.fromWire(j['access'] as String)
            : null,
        initiatorId: j['initiator_id'] as String?,
        isNetwork: (j['is_network'] ?? false) as bool,
        isHidden: (j['is_hidden'] ?? false) as bool,
        groupId: j['group_id'] as String?,
        prefs: j['prefs'] is Map
            ? ConversationPrefs.fromJson((j['prefs'] as Map).cast<String, dynamic>())
            : ConversationPrefs.defaults,
        pinnedMessageId: j['pinned_message_id'] as String?,
        pinnedUntil: j['pinned_until'] != null
            ? DateTime.parse(j['pinned_until'] as String)
            : null,
      );

  Conversation copyWith({
    ConversationAccess? access,
    String? initiatorId,
    bool? isNetwork,
    bool? isHidden,
    String? groupId,
    ConversationPrefs? prefs,
    String? Function()? pinnedMessageId,
    DateTime? Function()? pinnedUntil,
  }) =>
      Conversation(
        id: id,
        orgId: orgId,
        type: type,
        name: name,
        createdBy: createdBy,
        disappearAfterSec: disappearAfterSec,
        createdAt: createdAt,
        updatedAt: updatedAt,
        memberIds: memberIds,
        displayName: displayName,
        lastMessageAt: lastMessageAt,
        lastMessagePreview: lastMessagePreview,
        lastMessageSenderId: lastMessageSenderId,
        lastMessageType: lastMessageType,
        unreadCount: unreadCount,
        access: access ?? this.access,
        initiatorId: initiatorId ?? this.initiatorId,
        isNetwork: isNetwork ?? this.isNetwork,
        isHidden: isHidden ?? this.isHidden,
        groupId: groupId ?? this.groupId,
        prefs: prefs ?? this.prefs,
        pinnedMessageId:
            pinnedMessageId != null ? pinnedMessageId() : this.pinnedMessageId,
        pinnedUntil: pinnedUntil != null ? pinnedUntil() : this.pinnedUntil,
      );

  /// Round-trips through [Conversation.fromJson] — used by the offline cache.
  Map<String, dynamic> toJson() => {
        'id': id,
        'org_id': orgId,
        'type': type.wire,
        'name': name,
        'created_by': createdBy,
        'disappear_after_sec': disappearAfterSec,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'member_ids': memberIds,
        'display_name': displayName,
        'last_message_at': lastMessageAt?.toIso8601String(),
        'last_message_preview': lastMessagePreview,
        'last_message_sender_id': lastMessageSenderId,
        'last_message_type': lastMessageType?.wire,
        'unread_count': unreadCount,
        'access': access?.wire,
        'initiator_id': initiatorId,
        'is_network': isNetwork,
        'is_hidden': isHidden,
        'group_id': groupId,
        'prefs': prefs.toJson(),
        'pinned_message_id': pinnedMessageId,
        'pinned_until': pinnedUntil?.toIso8601String(),
      };
}
