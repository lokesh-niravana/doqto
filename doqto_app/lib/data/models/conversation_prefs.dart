/// My private view of one conversation (batch 3): pin, archive, mute, mark
/// unread, clear / delete cursors and cosmetic choices. Mirrors
/// `ConversationPrefsOut`; absent on the wire = defaults.
class ConversationPrefs {
  /// `muted_until` at or beyond this instant means "always".
  static final DateTime alwaysUntil = DateTime.utc(9999, 12, 31);

  final DateTime? pinnedAt;
  final bool archived;
  final DateTime? mutedUntil;
  final String? customTone;
  final String? customVibrate;
  final String? theme;
  final String? wallpaper;
  final bool markedUnread;
  final int? clearedBeforeSeq;
  final int? hiddenUntilSeq;

  const ConversationPrefs({
    this.pinnedAt,
    this.archived = false,
    this.mutedUntil,
    this.customTone,
    this.customVibrate,
    this.theme,
    this.wallpaper,
    this.markedUnread = false,
    this.clearedBeforeSeq,
    this.hiddenUntilSeq,
  });

  static const defaults = ConversationPrefs();

  bool get isPinned => pinnedAt != null;

  /// Muted right now ([now] defaults to the wall clock).
  bool isMuted([DateTime? now]) =>
      mutedUntil != null && mutedUntil!.isAfter(now ?? DateTime.now().toUtc());

  /// Muted with no expiry ("Always").
  bool get isMutedAlways => mutedUntil != null && !mutedUntil!.isBefore(alwaysUntil);

  factory ConversationPrefs.fromJson(Map<String, dynamic> j) => ConversationPrefs(
        pinnedAt: _date(j['pinned_at']),
        archived: (j['archived'] ?? false) as bool,
        mutedUntil: _date(j['muted_until']),
        customTone: j['custom_tone'] as String?,
        customVibrate: j['custom_vibrate'] as String?,
        theme: j['theme'] as String?,
        wallpaper: j['wallpaper'] as String?,
        markedUnread: (j['marked_unread'] ?? false) as bool,
        clearedBeforeSeq: (j['cleared_before_seq'] as num?)?.toInt(),
        hiddenUntilSeq: (j['hidden_until_seq'] as num?)?.toInt(),
      );

  static DateTime? _date(Object? v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toUtc();
  }

  Map<String, dynamic> toJson() => {
        'pinned_at': pinnedAt?.toIso8601String(),
        'archived': archived,
        'muted_until': mutedUntil?.toIso8601String(),
        'custom_tone': customTone,
        'custom_vibrate': customVibrate,
        'theme': theme,
        'wallpaper': wallpaper,
        'marked_unread': markedUnread,
        'cleared_before_seq': clearedBeforeSeq,
        'hidden_until_seq': hiddenUntilSeq,
      };

  /// Nullable fields take a thunk so `() => null` can clear them.
  ConversationPrefs copyWith({
    DateTime? Function()? pinnedAt,
    bool? archived,
    DateTime? Function()? mutedUntil,
    String? Function()? customTone,
    String? Function()? customVibrate,
    String? Function()? theme,
    String? Function()? wallpaper,
    bool? markedUnread,
    int? Function()? clearedBeforeSeq,
    int? Function()? hiddenUntilSeq,
  }) =>
      ConversationPrefs(
        pinnedAt: pinnedAt == null ? this.pinnedAt : pinnedAt(),
        archived: archived ?? this.archived,
        mutedUntil: mutedUntil == null ? this.mutedUntil : mutedUntil(),
        customTone: customTone == null ? this.customTone : customTone(),
        customVibrate: customVibrate == null ? this.customVibrate : customVibrate(),
        theme: theme == null ? this.theme : theme(),
        wallpaper: wallpaper == null ? this.wallpaper : wallpaper(),
        markedUnread: markedUnread ?? this.markedUnread,
        clearedBeforeSeq:
            clearedBeforeSeq == null ? this.clearedBeforeSeq : clearedBeforeSeq(),
        hiddenUntilSeq: hiddenUntilSeq == null ? this.hiddenUntilSeq : hiddenUntilSeq(),
      );

  @override
  bool operator ==(Object other) =>
      other is ConversationPrefs &&
      other.pinnedAt == pinnedAt &&
      other.archived == archived &&
      other.mutedUntil == mutedUntil &&
      other.customTone == customTone &&
      other.customVibrate == customVibrate &&
      other.theme == theme &&
      other.wallpaper == wallpaper &&
      other.markedUnread == markedUnread &&
      other.clearedBeforeSeq == clearedBeforeSeq &&
      other.hiddenUntilSeq == hiddenUntilSeq;

  @override
  int get hashCode => Object.hash(pinnedAt, archived, mutedUntil, customTone, customVibrate,
      theme, wallpaper, markedUnread, clearedBeforeSeq, hiddenUntilSeq);
}

/// Mute durations offered by the chat list sheet. `null` = always.
enum MuteDuration {
  eightHours(Duration(hours: 8), '8 hours'),
  oneWeek(Duration(days: 7), '1 week'),
  always(null, 'Always');

  final Duration? length;
  final String label;
  const MuteDuration(this.length, this.label);

  /// The `muted_until` instant for this choice, from [now].
  DateTime until([DateTime? now]) =>
      length == null ? ConversationPrefs.alwaysUntil : (now ?? DateTime.now().toUtc()).add(length!);
}
