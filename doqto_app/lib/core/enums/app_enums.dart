// Mirrors docs/enums.md + app/core/enums.py on the backend.
// Wire values are snake_case strings — enforced via @JsonValue.
// A parity check in scripts/check_enum_parity.py fails CI on drift.

import 'package:json_annotation/json_annotation.dart';

enum UserRole {
  @JsonValue('doctor') doctor,
  @JsonValue('super_admin') superAdmin;

  String get wire => switch (this) {
        UserRole.doctor => 'doctor',
        UserRole.superAdmin => 'super_admin',
      };

  // Tolerant (A5): unknown wire values map to the least-privileged role.
  static UserRole fromWire(String s) => switch (s) {
        'super_admin' => UserRole.superAdmin,
        _ => UserRole.doctor,
      };
}

enum OrgStatus {
  @JsonValue('pending') pending,
  @JsonValue('active') active,
  @JsonValue('suspended') suspended;

  String get wire => switch (this) {
        OrgStatus.pending => 'pending',
        OrgStatus.active => 'active',
        OrgStatus.suspended => 'suspended',
      };

  // Tolerant (A5): unknown wire values fail safe to `pending`
  // (benign "verification in progress" state, never grants access).
  static OrgStatus fromWire(String s) => switch (s) {
        'active' => OrgStatus.active,
        'suspended' => OrgStatus.suspended,
        _ => OrgStatus.pending,
      };
}

enum OrgRole {
  @JsonValue('admin') admin,
  @JsonValue('doctor') doctor;

  String get wire => switch (this) {
        OrgRole.admin => 'admin',
        OrgRole.doctor => 'doctor',
      };

  // Tolerant (A5): unknown wire values map to the least-privileged role.
  static OrgRole fromWire(String s) => switch (s) {
        'admin' => OrgRole.admin,
        _ => OrgRole.doctor,
      };
}

enum PracticeType {
  @JsonValue('independent') independent,
  @JsonValue('specialty_group') specialtyGroup,
  @JsonValue('community_hospital') communityHospital;

  String get wire => switch (this) {
        PracticeType.independent => 'independent',
        PracticeType.specialtyGroup => 'specialty_group',
        PracticeType.communityHospital => 'community_hospital',
      };
}

enum ConversationType {
  @JsonValue('direct') direct,
  @JsonValue('group') group,

  /// Tolerant fallback for wire values this client doesn't know yet (A5).
  /// Consumers must treat it like [direct] (safest render path) — never crash.
  @JsonValue('unknown') unknown;

  String get wire => switch (this) {
        ConversationType.direct => 'direct',
        ConversationType.group => 'group',
        ConversationType.unknown => 'unknown',
      };

  static ConversationType fromWire(String s) => switch (s) {
        'direct' => ConversationType.direct,
        'group' => ConversationType.group,
        _ => ConversationType.unknown,
      };
}

enum MessageType {
  @JsonValue('text') text,
  @JsonValue('voice_note') voiceNote,
  @JsonValue('image') image,
  @JsonValue('file') file,
  @JsonValue('system') system,

  /// Tolerant fallback for wire values this client doesn't know yet (A5).
  /// Consumers must treat it like [text] (generic bubble) — never crash.
  @JsonValue('unknown') unknown;

  String get wire => switch (this) {
        MessageType.text => 'text',
        MessageType.voiceNote => 'voice_note',
        MessageType.image => 'image',
        MessageType.file => 'file',
        MessageType.system => 'system',
        MessageType.unknown => 'unknown',
      };

  static MessageType fromWire(String s) => switch (s) {
        'text' => MessageType.text,
        'voice_note' => MessageType.voiceNote,
        'image' => MessageType.image,
        'file' => MessageType.file,
        'system' => MessageType.system,
        _ => MessageType.unknown,
      };
}

/// Access tier of a conversation (networking layer, plan M0/A5).
/// `open` = normal thread; `pending_request` = message-request tier;
/// `declined` = recipient declined the request.
enum ConversationAccess {
  @JsonValue('open') open,
  @JsonValue('pending_request') pendingRequest,
  @JsonValue('declined') declined,

  /// Tolerant fallback (A5) — consumers must treat it like [open].
  @JsonValue('unknown') unknown;

  String get wire => switch (this) {
        ConversationAccess.open => 'open',
        ConversationAccess.pendingRequest => 'pending_request',
        ConversationAccess.declined => 'declined',
        ConversationAccess.unknown => 'unknown',
      };

  static ConversationAccess fromWire(String s) => switch (s) {
        'open' => ConversationAccess.open,
        'pending_request' => ConversationAccess.pendingRequest,
        'declined' => ConversationAccess.declined,
        _ => ConversationAccess.unknown,
      };
}

enum TranscriptStatus {
  @JsonValue('none') none,
  @JsonValue('pending') pending,
  @JsonValue('completed') completed,
  @JsonValue('failed') failed;

  String get wire => switch (this) {
        TranscriptStatus.none => 'none',
        TranscriptStatus.pending => 'pending',
        TranscriptStatus.completed => 'completed',
        TranscriptStatus.failed => 'failed',
      };

  static TranscriptStatus fromWire(String s) => switch (s) {
        'pending' => TranscriptStatus.pending,
        'completed' => TranscriptStatus.completed,
        'failed' => TranscriptStatus.failed,
        _ => TranscriptStatus.none,
      };
}

enum PresenceStatus {
  online,
  away,
  offline;

  String get wire => switch (this) {
        PresenceStatus.online => 'online',
        PresenceStatus.away => 'away',
        PresenceStatus.offline => 'offline',
      };

  static PresenceStatus fromWire(String? s) => switch (s) {
        'online' => PresenceStatus.online,
        'away' => PresenceStatus.away,
        _ => PresenceStatus.offline,
      };
}

enum WsEventServer {
  newMessage,
  transcriptReady,
  messageDelivered,
  messageRead,
  messageEdited,
  messageDeleted,
  presenceUpdate,
  memberAdded,
  memberRemoved,
  systemMessage,
  typingStart,
  typingStop,
  heartbeatAck,
  // Networking graph (M1) — recipient-scoped.
  invitationReceived,
  invitationAccepted,
  connectionRemoved,
  notificationCreated,
  // Message-request tier (M4) — recipient/initiator-scoped, PHI-free.
  conversationRequestReceived,
  conversationRequestAccepted,
  conversationRequestDeclined,
  // Groups (M5) — recipient-scoped, PHI-free.
  groupInviteReceived,
  groupMemberJoined,
  // Realtime coverage (R1) — recipient-scoped, PHI-free.
  /// First frame after a successful auth frame: the socket is live.
  connected,
  invitationWithdrawn,
  orgUpdated,
  groupUpdated,
  profileUpdated;

  String get wire => switch (this) {
        WsEventServer.newMessage => 'new_message',
        WsEventServer.transcriptReady => 'transcript_ready',
        WsEventServer.messageDelivered => 'message_delivered',
        WsEventServer.messageRead => 'message_read',
        WsEventServer.messageEdited => 'message_edited',
        WsEventServer.messageDeleted => 'message_deleted',
        WsEventServer.presenceUpdate => 'presence_update',
        WsEventServer.memberAdded => 'member_added',
        WsEventServer.memberRemoved => 'member_removed',
        WsEventServer.systemMessage => 'system_message',
        WsEventServer.typingStart => 'typing_start',
        WsEventServer.typingStop => 'typing_stop',
        WsEventServer.heartbeatAck => 'heartbeat_ack',
        WsEventServer.invitationReceived => 'invitation_received',
        WsEventServer.invitationAccepted => 'invitation_accepted',
        WsEventServer.connectionRemoved => 'connection_removed',
        WsEventServer.notificationCreated => 'notification_created',
        WsEventServer.conversationRequestReceived =>
          'conversation_request_received',
        WsEventServer.conversationRequestAccepted =>
          'conversation_request_accepted',
        WsEventServer.conversationRequestDeclined =>
          'conversation_request_declined',
        WsEventServer.groupInviteReceived => 'group_invite_received',
        WsEventServer.groupMemberJoined => 'group_member_joined',
        WsEventServer.connected => 'connected',
        WsEventServer.invitationWithdrawn => 'invitation_withdrawn',
        WsEventServer.orgUpdated => 'org_updated',
        WsEventServer.groupUpdated => 'group_updated',
        WsEventServer.profileUpdated => 'profile_updated',
      };

  static WsEventServer? fromWire(String s) => switch (s) {
        'new_message' => WsEventServer.newMessage,
        'transcript_ready' => WsEventServer.transcriptReady,
        'message_delivered' => WsEventServer.messageDelivered,
        'message_read' => WsEventServer.messageRead,
        'message_edited' => WsEventServer.messageEdited,
        'message_deleted' => WsEventServer.messageDeleted,
        'presence_update' => WsEventServer.presenceUpdate,
        'member_added' => WsEventServer.memberAdded,
        'member_removed' => WsEventServer.memberRemoved,
        'system_message' => WsEventServer.systemMessage,
        'typing_start' => WsEventServer.typingStart,
        'typing_stop' => WsEventServer.typingStop,
        'heartbeat_ack' => WsEventServer.heartbeatAck,
        'invitation_received' => WsEventServer.invitationReceived,
        'invitation_accepted' => WsEventServer.invitationAccepted,
        'connection_removed' => WsEventServer.connectionRemoved,
        'notification_created' => WsEventServer.notificationCreated,
        'conversation_request_received' =>
          WsEventServer.conversationRequestReceived,
        'conversation_request_accepted' =>
          WsEventServer.conversationRequestAccepted,
        'conversation_request_declined' =>
          WsEventServer.conversationRequestDeclined,
        'group_invite_received' => WsEventServer.groupInviteReceived,
        'group_member_joined' => WsEventServer.groupMemberJoined,
        'connected' => WsEventServer.connected,
        'invitation_withdrawn' => WsEventServer.invitationWithdrawn,
        'org_updated' => WsEventServer.orgUpdated,
        'group_updated' => WsEventServer.groupUpdated,
        'profile_updated' => WsEventServer.profileUpdated,
        _ => null,
      };
}

enum WsEventClient {
  heartbeat,
  typingStart,
  typingStop;

  String get wire => switch (this) {
        WsEventClient.heartbeat => 'heartbeat',
        WsEventClient.typingStart => 'typing_start',
        WsEventClient.typingStop => 'typing_stop',
      };
}

enum DevicePlatform {
  @JsonValue('ios') ios,
  @JsonValue('android') android;

  String get wire => switch (this) {
        DevicePlatform.ios => 'ios',
        DevicePlatform.android => 'android',
      };

  static DevicePlatform fromWire(String s) => switch (s) {
        'ios' => DevicePlatform.ios,
        'android' => DevicePlatform.android,
        _ => throw ArgumentError('Unknown DevicePlatform: $s'),
      };
}

/// Connection-invitation lifecycle (networking graph, M1). Shared wire enum
/// (invitation lists) — mirrors backend InvitationStatus.
enum InvitationStatus {
  @JsonValue('pending') pending,
  @JsonValue('accepted') accepted,
  @JsonValue('ignored') ignored,
  @JsonValue('withdrawn') withdrawn,
  @JsonValue('expired') expired,

  /// Tolerant fallback (A5) — never emitted by the server.
  @JsonValue('unknown') unknown;

  String get wire => switch (this) {
        InvitationStatus.pending => 'pending',
        InvitationStatus.accepted => 'accepted',
        InvitationStatus.ignored => 'ignored',
        InvitationStatus.withdrawn => 'withdrawn',
        InvitationStatus.expired => 'expired',
        InvitationStatus.unknown => 'unknown',
      };

  static InvitationStatus fromWire(String s) => switch (s) {
        'pending' => InvitationStatus.pending,
        'accepted' => InvitationStatus.accepted,
        'ignored' => InvitationStatus.ignored,
        'withdrawn' => InvitationStatus.withdrawn,
        'expired' => InvitationStatus.expired,
        _ => InvitationStatus.unknown,
      };
}

/// Who may send me a connection invitation (user_privacy_settings, M1).
/// Shared wire enum — mirrors backend InvitePolicy.
enum InvitePolicy {
  @JsonValue('everyone') everyone,
  @JsonValue('second_degree') secondDegree,
  @JsonValue('shared_group_or_org') sharedGroupOrOrg,
  @JsonValue('nobody') nobody,

  /// Tolerant fallback (A5) — never emitted by the server.
  @JsonValue('unknown') unknown;

  String get wire => switch (this) {
        InvitePolicy.everyone => 'everyone',
        InvitePolicy.secondDegree => 'second_degree',
        InvitePolicy.sharedGroupOrOrg => 'shared_group_or_org',
        InvitePolicy.nobody => 'nobody',
        InvitePolicy.unknown => 'unknown',
      };

  static InvitePolicy fromWire(String s) => switch (s) {
        'everyone' => InvitePolicy.everyone,
        'second_degree' => InvitePolicy.secondDegree,
        'shared_group_or_org' => InvitePolicy.sharedGroupOrOrg,
        'nobody' => InvitePolicy.nobody,
        _ => InvitePolicy.unknown,
      };
}

/// Who may open a direct conversation with me (user_privacy_settings, M1).
/// Shared wire enum — mirrors backend DmPolicy.
enum DmPolicy {
  @JsonValue('everyone') everyone,
  @JsonValue('connections_and_requests') connectionsAndRequests,
  @JsonValue('connections_only') connectionsOnly,
  @JsonValue('nobody') nobody,

  /// Tolerant fallback (A5) — never emitted by the server.
  @JsonValue('unknown') unknown;

  String get wire => switch (this) {
        DmPolicy.everyone => 'everyone',
        DmPolicy.connectionsAndRequests => 'connections_and_requests',
        DmPolicy.connectionsOnly => 'connections_only',
        DmPolicy.nobody => 'nobody',
        DmPolicy.unknown => 'unknown',
      };

  static DmPolicy fromWire(String s) => switch (s) {
        'everyone' => DmPolicy.everyone,
        'connections_and_requests' => DmPolicy.connectionsAndRequests,
        'connections_only' => DmPolicy.connectionsOnly,
        'nobody' => DmPolicy.nobody,
        _ => DmPolicy.unknown,
      };
}

/// Who may find me / view my profile (user_privacy_settings, M1).
/// Shared wire enum — mirrors backend Discoverability.
enum Discoverability {
  @JsonValue('everyone') everyone,
  @JsonValue('connections') connections,
  @JsonValue('nobody') nobody,

  /// Tolerant fallback (A5) — never emitted by the server.
  @JsonValue('unknown') unknown;

  String get wire => switch (this) {
        Discoverability.everyone => 'everyone',
        Discoverability.connections => 'connections',
        Discoverability.nobody => 'nobody',
        Discoverability.unknown => 'unknown',
      };

  static Discoverability fromWire(String s) => switch (s) {
        'everyone' => Discoverability.everyone,
        'connections' => Discoverability.connections,
        'nobody' => Discoverability.nobody,
        _ => Discoverability.unknown,
      };
}

/// Member capability ladder (groups, M5). Shared wire enum — mirrors backend
/// GroupRole. §9.3.
enum GroupRole {
  @JsonValue('owner') owner,
  @JsonValue('admin') admin,
  @JsonValue('moderator') moderator,
  @JsonValue('member') member,

  /// Tolerant fallback (A5) — treat like [member] (least-privileged, safe).
  @JsonValue('unknown') unknown;

  String get wire => switch (this) {
        GroupRole.owner => 'owner',
        GroupRole.admin => 'admin',
        GroupRole.moderator => 'moderator',
        GroupRole.member => 'member',
        GroupRole.unknown => 'unknown',
      };

  static GroupRole fromWire(String? s) => switch (s) {
        'owner' => GroupRole.owner,
        'admin' => GroupRole.admin,
        'moderator' => GroupRole.moderator,
        'member' => GroupRole.member,
        _ => GroupRole.unknown,
      };

  /// Admin-tier roles (see join-request queue, approve/reject, edit group).
  bool get isAdminTier =>
      this == GroupRole.owner ||
      this == GroupRole.admin ||
      this == GroupRole.moderator;
}

/// Relationship degree as a plain wire string ('1st'|'2nd'|'3rd'|'out').
/// CLIENT-ONLY type-safety wrapper — NOT part of enum parity (backend sends a
/// bare string). Tolerant: unknown → [out] (least-connected, safe default).
enum ConnectionDegree {
  first,
  second,
  third,
  out;

  String get wire => switch (this) {
        ConnectionDegree.first => '1st',
        ConnectionDegree.second => '2nd',
        ConnectionDegree.third => '3rd',
        ConnectionDegree.out => 'out',
      };

  static ConnectionDegree fromWire(String? s) => switch (s) {
        '1st' => ConnectionDegree.first,
        '2nd' => ConnectionDegree.second,
        '3rd' => ConnectionDegree.third,
        _ => ConnectionDegree.out,
      };
}

/// Relationship state as a plain wire string
/// ('none'|'pending_outgoing'|'pending_incoming'|'connected').
/// CLIENT-ONLY — NOT part of enum parity. Tolerant: unknown → [none].
enum RelationshipState {
  none,
  pendingOutgoing,
  pendingIncoming,
  connected;

  String get wire => switch (this) {
        RelationshipState.none => 'none',
        RelationshipState.pendingOutgoing => 'pending_outgoing',
        RelationshipState.pendingIncoming => 'pending_incoming',
        RelationshipState.connected => 'connected',
      };

  static RelationshipState fromWire(String? s) => switch (s) {
        'pending_outgoing' => RelationshipState.pendingOutgoing,
        'pending_incoming' => RelationshipState.pendingIncoming,
        'connected' => RelationshipState.connected,
        _ => RelationshipState.none,
      };
}

/// Messaging affordance as a plain wire string ('open'|'request'|'denied').
/// CLIENT-ONLY — NOT part of enum parity. Tolerant: unknown → [denied]
/// (fail-safe: never surface an "open" composer we weren't told about).
enum CanMessage {
  open,
  request,
  denied;

  String get wire => switch (this) {
        CanMessage.open => 'open',
        CanMessage.request => 'request',
        CanMessage.denied => 'denied',
      };

  static CanMessage fromWire(String? s) => switch (s) {
        'open' => CanMessage.open,
        'request' => CanMessage.request,
        _ => CanMessage.denied,
      };
}

enum DisappearAfter {
  off(null),
  day(86400),
  week(604800);

  final int? seconds;
  const DisappearAfter(this.seconds);
}
