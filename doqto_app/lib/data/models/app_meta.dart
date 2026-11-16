/// Unauthenticated app metadata (batch 6): `GET /app/min-version` and
/// `GET /app/legal`.
class MinVersion {
  final String ios;
  final String android;
  final String message;

  const MinVersion({
    required this.ios,
    required this.android,
    required this.message,
  });

  factory MinVersion.fromJson(Map<String, dynamic> j) => MinVersion(
        ios: (j['ios'] ?? '') as String,
        android: (j['android'] ?? '') as String,
        message: (j['message'] ?? '') as String,
      );

  /// Build number after `+` in "1.0.0+45"; 0 when there is none.
  static int buildNumber(String version) {
    final plus = version.indexOf('+');
    if (plus < 0) return 0;
    return int.tryParse(version.substring(plus + 1).trim()) ?? 0;
  }

  /// True when an app at [installedVersion] (pubspec form) on [platform]
  /// (`ios` | `android`) is below the minimum. Unknown / unparseable
  /// minimums never force an update.
  bool requiresUpdate({
    required String installedVersion,
    required String platform,
  }) {
    final min = platform == 'android' ? android : ios;
    final minBuild = buildNumber(min);
    if (minBuild <= 0) return false;
    final mine = buildNumber(installedVersion);
    if (mine <= 0) return false; // a dev build with no number is never gated
    return mine < minBuild;
  }
}

class LegalLinks {
  final String help;
  final String contact;
  final String terms;
  final String privacy;
  final String hipaa;

  const LegalLinks({
    required this.help,
    required this.contact,
    required this.terms,
    required this.privacy,
    required this.hipaa,
  });

  /// Mirrors LEGAL_URLS on the backend — shown while the fetch is in flight
  /// or offline.
  static const defaults = LegalLinks(
    help: 'https://doqto.ai/help',
    contact: 'mailto:support@doqto.ai',
    terms: 'https://doqto.ai/terms',
    privacy: 'https://doqto.ai/privacy',
    hipaa: 'https://doqto.ai/hipaa',
  );

  factory LegalLinks.fromJson(Map<String, dynamic> j) => LegalLinks(
        help: (j['help'] as String?) ?? defaults.help,
        contact: (j['contact'] as String?) ?? defaults.contact,
        terms: (j['terms'] as String?) ?? defaults.terms,
        privacy: (j['privacy'] as String?) ?? defaults.privacy,
        hipaa: (j['hipaa'] as String?) ?? defaults.hipaa,
      );
}
