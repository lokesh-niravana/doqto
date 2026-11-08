import '../../core/enums/app_enums.dart';

/// Bundled notification tones (batch 6). Wire names mirror
/// NOTIFICATION_TONES on the backend; `default` = the system sound, `none`
/// = silent. Each ships as `ios/Runner/Resources/tones/NAME.caf`,
/// `android res/raw/NAME.wav` and `assets/tones/NAME.wav` (preview).
class NotificationTones {
  NotificationTones._();

  static const String systemDefault = 'default';
  static const String none = 'none';

  /// The bundled files, in picker order.
  static const List<String> bundled = [
    'chime',
    'pulse',
    'ping',
    'bell',
    'glass',
    'note',
    'pop',
    'ripple',
    'signal',
    'tap',
    'whistle',
  ];

  static const List<String> all = [systemDefault, ...bundled, none];

  static bool isValid(String? s) => s != null && all.contains(s);

  /// Preview asset for a bundled tone; null for default / none.
  static String? assetFor(String tone) =>
      bundled.contains(tone) ? 'assets/tones/$tone.wav' : null;

  static String label(String tone) => switch (tone) {
        systemDefault => 'Default',
        none => 'None',
        _ => tone.isEmpty ? tone : tone[0].toUpperCase() + tone.substring(1),
      };
}

/// Mirrors `NotificationSettingsOut` — effective values (`*_show_preview`
/// already resolved server-side from the org rule).
class NotificationSettings {
  final String messagesTone;
  final VibratePattern messagesVibrate;
  final bool messagesShowPreview;
  final bool messagesHighPriority;
  final String groupsTone;
  final VibratePattern groupsVibrate;
  final bool groupsShowPreview;
  final bool groupsHighPriority;
  final bool reactionNotifications;
  final bool conversationTones;
  final bool haptics;

  const NotificationSettings({
    this.messagesTone = NotificationTones.systemDefault,
    this.messagesVibrate = VibratePattern.defaultPattern,
    this.messagesShowPreview = true,
    this.messagesHighPriority = true,
    this.groupsTone = NotificationTones.systemDefault,
    this.groupsVibrate = VibratePattern.defaultPattern,
    this.groupsShowPreview = true,
    this.groupsHighPriority = true,
    this.reactionNotifications = true,
    this.conversationTones = true,
    this.haptics = true,
  });

  static const defaults = NotificationSettings();

  factory NotificationSettings.fromJson(Map<String, dynamic> j) =>
      NotificationSettings(
        messagesTone: (j['messages_tone'] as String?) ?? NotificationTones.systemDefault,
        messagesVibrate: VibratePattern.fromWire(j['messages_vibrate'] as String?),
        messagesShowPreview: (j['messages_show_preview'] as bool?) ?? true,
        messagesHighPriority: (j['messages_high_priority'] as bool?) ?? true,
        groupsTone: (j['groups_tone'] as String?) ?? NotificationTones.systemDefault,
        groupsVibrate: VibratePattern.fromWire(j['groups_vibrate'] as String?),
        groupsShowPreview: (j['groups_show_preview'] as bool?) ?? true,
        groupsHighPriority: (j['groups_high_priority'] as bool?) ?? true,
        reactionNotifications: (j['reaction_notifications'] as bool?) ?? true,
        conversationTones: (j['conversation_tones'] as bool?) ?? true,
        haptics: (j['haptics'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => {
        'messages_tone': messagesTone,
        'messages_vibrate': messagesVibrate.wire,
        'messages_show_preview': messagesShowPreview,
        'messages_high_priority': messagesHighPriority,
        'groups_tone': groupsTone,
        'groups_vibrate': groupsVibrate.wire,
        'groups_show_preview': groupsShowPreview,
        'groups_high_priority': groupsHighPriority,
        'reaction_notifications': reactionNotifications,
        'conversation_tones': conversationTones,
        'haptics': haptics,
      };

  NotificationSettings copyWith({
    String? messagesTone,
    VibratePattern? messagesVibrate,
    bool? messagesShowPreview,
    bool? messagesHighPriority,
    String? groupsTone,
    VibratePattern? groupsVibrate,
    bool? groupsShowPreview,
    bool? groupsHighPriority,
    bool? reactionNotifications,
    bool? conversationTones,
    bool? haptics,
  }) =>
      NotificationSettings(
        messagesTone: messagesTone ?? this.messagesTone,
        messagesVibrate: messagesVibrate ?? this.messagesVibrate,
        messagesShowPreview: messagesShowPreview ?? this.messagesShowPreview,
        messagesHighPriority: messagesHighPriority ?? this.messagesHighPriority,
        groupsTone: groupsTone ?? this.groupsTone,
        groupsVibrate: groupsVibrate ?? this.groupsVibrate,
        groupsShowPreview: groupsShowPreview ?? this.groupsShowPreview,
        groupsHighPriority: groupsHighPriority ?? this.groupsHighPriority,
        reactionNotifications:
            reactionNotifications ?? this.reactionNotifications,
        conversationTones: conversationTones ?? this.conversationTones,
        haptics: haptics ?? this.haptics,
      );

  @override
  bool operator ==(Object other) =>
      other is NotificationSettings &&
      other.messagesTone == messagesTone &&
      other.messagesVibrate == messagesVibrate &&
      other.messagesShowPreview == messagesShowPreview &&
      other.messagesHighPriority == messagesHighPriority &&
      other.groupsTone == groupsTone &&
      other.groupsVibrate == groupsVibrate &&
      other.groupsShowPreview == groupsShowPreview &&
      other.groupsHighPriority == groupsHighPriority &&
      other.reactionNotifications == reactionNotifications &&
      other.conversationTones == conversationTones &&
      other.haptics == haptics;

  @override
  int get hashCode => Object.hash(
        messagesTone,
        messagesVibrate,
        messagesShowPreview,
        messagesHighPriority,
        groupsTone,
        groupsVibrate,
        groupsShowPreview,
        groupsHighPriority,
        reactionNotifications,
        conversationTones,
        haptics,
      );
}
