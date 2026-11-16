/// Storage and data (batch 5): how photos are sized before upload and which
/// media downloads on its own per network. Stored in the encrypted chat cache
/// box, never in SharedPreferences.
enum UploadQuality {
  standard('standard', 1600, 'Standard'),
  hd('hd', 2560, 'HD'),
  original('original', null, 'Original');

  final String wire;

  /// Longest side in pixels; null = leave the picker's full resolution.
  final int? maxSide;
  final String label;
  const UploadQuality(this.wire, this.maxSide, this.label);

  static UploadQuality fromWire(String? s) =>
      UploadQuality.values.where((q) => q.wire == s).firstOrNull ?? UploadQuality.standard;
}

enum MediaDownloadKind {
  photos('photos', 'Photos'),
  voice('voice', 'Voice notes'),
  video('video', 'Videos'),
  documents('documents', 'Documents');

  final String wire;
  final String label;
  const MediaDownloadKind(this.wire, this.label);
}

/// When a kind of media downloads without a tap.
enum AutoDownloadRule {
  never('never', 'Never'),
  wifi('wifi', 'Wi-Fi only'),
  always('always', 'Wi-Fi and cellular');

  final String wire;
  final String label;
  const AutoDownloadRule(this.wire, this.label);

  static AutoDownloadRule fromWire(String? s) =>
      AutoDownloadRule.values.where((r) => r.wire == s).firstOrNull ?? AutoDownloadRule.never;

  bool allowsOn(NetworkType network) => switch (this) {
        AutoDownloadRule.never => false,
        AutoDownloadRule.wifi => network == NetworkType.wifi,
        AutoDownloadRule.always => network != NetworkType.none,
      };
}

enum NetworkType { wifi, cellular, none }

class MediaSettings {
  final UploadQuality uploadQuality;
  final Map<MediaDownloadKind, AutoDownloadRule> autoDownload;

  const MediaSettings({
    this.uploadQuality = UploadQuality.standard,
    this.autoDownload = const {},
  });

  /// Photos on Wi-Fi only; everything else waits for a tap.
  static const defaults = MediaSettings(
    autoDownload: {MediaDownloadKind.photos: AutoDownloadRule.wifi},
  );

  AutoDownloadRule ruleFor(MediaDownloadKind kind) =>
      autoDownload[kind] ?? (kind == MediaDownloadKind.photos ? AutoDownloadRule.wifi : AutoDownloadRule.never);

  bool shouldAutoDownload(MediaDownloadKind kind, NetworkType network) =>
      ruleFor(kind).allowsOn(network);

  MediaSettings copyWith({
    UploadQuality? uploadQuality,
    Map<MediaDownloadKind, AutoDownloadRule>? autoDownload,
  }) =>
      MediaSettings(
        uploadQuality: uploadQuality ?? this.uploadQuality,
        autoDownload: autoDownload ?? this.autoDownload,
      );

  MediaSettings withRule(MediaDownloadKind kind, AutoDownloadRule rule) =>
      copyWith(autoDownload: {...autoDownload, kind: rule});

  Map<String, dynamic> toJson() => {
        'upload_quality': uploadQuality.wire,
        'auto_download': {for (final e in autoDownload.entries) e.key.wire: e.value.wire},
      };

  factory MediaSettings.fromJson(Map<String, dynamic>? j) {
    if (j == null) return defaults;
    final raw = j['auto_download'];
    final rules = <MediaDownloadKind, AutoDownloadRule>{...defaults.autoDownload};
    if (raw is Map) {
      for (final k in MediaDownloadKind.values) {
        final v = raw[k.wire];
        if (v is String) rules[k] = AutoDownloadRule.fromWire(v);
      }
    }
    return MediaSettings(
      uploadQuality: UploadQuality.fromWire(j['upload_quality'] as String?),
      autoDownload: rules,
    );
  }
}
