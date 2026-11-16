import 'package:flutter/material.dart';

/// All colors from docs/design.md. Never inline a Color(...) outside this file.
///
/// One palette, light only ([DoqtoPalette.light]; docs/design.md: "No dark
/// mode"). Role / neutral / tint colours on [AppColors] are static getters
/// that read it; brand constants (teal, red, amber, green, purple, white,
/// presence dots, the avatar cycle) stay `const` for const constructors.
@immutable
class DoqtoPalette {
  final Brightness brightness;

  // Brand tints that shift with the theme.
  final Color medBlueDark;
  final Color medBlueMid;
  final Color medBlueLight;
  final Color medTealLight;

  // Neutrals — a 7-step scale that inverts in dark mode.
  final Color gray50;
  final Color gray100;
  final Color gray200;
  final Color gray400;
  final Color gray600;
  final Color gray800;
  final Color gray900;

  // Semantic tints + their on-tint text.
  final Color greenLight;
  final Color greenDark;
  final Color amberText;
  final Color amberLight;
  final Color redLight;
  final Color purpleText;
  final Color purpleLight;
  final Color tealBadgeText;

  // Chat surfaces.
  final Color receivedBubble;
  final Color threadBg;

  const DoqtoPalette({
    required this.brightness,
    required this.medBlueDark,
    required this.medBlueMid,
    required this.medBlueLight,
    required this.medTealLight,
    required this.gray50,
    required this.gray100,
    required this.gray200,
    required this.gray400,
    required this.gray600,
    required this.gray800,
    required this.gray900,
    required this.greenLight,
    required this.greenDark,
    required this.amberText,
    required this.amberLight,
    required this.redLight,
    required this.purpleText,
    required this.purpleLight,
    required this.tealBadgeText,
    required this.receivedBubble,
    required this.threadBg,
  });

  static const DoqtoPalette light = DoqtoPalette(
    brightness: Brightness.light,
    medBlueDark: Color(0xFF1E2A5A), // brand navy: headings, pressed states
    medBlueMid: Color(0xFF5FA5AB), // lighter teal: focused inputs
    medBlueLight: Color(0xFFE6F1F2), // pale teal tint: input bg, tinted surfaces
    medTealLight: Color(0xFFE0FAF7),
    gray50: Color(0xFFF8FAFD),
    gray100: Color(0xFFEEF2F8),
    gray200: Color(0xFFD6DDF0),
    gray400: Color(0xFF8A9CC4),
    gray600: Color(0xFF4A5E8C),
    gray800: Color(0xFF1C2B4A),
    gray900: Color(0xFF0D1829),
    greenLight: Color(0xFFDCFCE7),
    greenDark: Color(0xFF15803D),
    amberText: Color(0xFF92400E),
    amberLight: Color(0xFFFEF3C7),
    redLight: Color(0xFFFEF2F2),
    purpleText: Color(0xFF6B21A8),
    purpleLight: Color(0xFFF3E8FF),
    tealBadgeText: Color(0xFF0D6B62),
    receivedBubble: Color(0xFFFFFFFF),
    threadBg: Color(0xFFF8FAFD),
  );

  /// The surface colour.
  Color get surface => const Color(0xFFFFFFFF);

  @override
  bool operator ==(Object other) =>
      other is DoqtoPalette && other.brightness == brightness;

  @override
  int get hashCode => brightness.hashCode;
}

/// The palette as a ThemeExtension, so code with a BuildContext can resolve it
/// through `Theme.of(context)` instead of the process-wide static.
@immutable
class DoqtoColors extends ThemeExtension<DoqtoColors> {
  final DoqtoPalette palette;
  const DoqtoColors(this.palette);

  static DoqtoColors of(BuildContext context) =>
      Theme.of(context).extension<DoqtoColors>() ??
      DoqtoColors(AppColors.current);

  @override
  DoqtoColors copyWith({DoqtoPalette? palette}) =>
      DoqtoColors(palette ?? this.palette);

  @override
  DoqtoColors lerp(ThemeExtension<DoqtoColors>? other, double t) =>
      t < 0.5 || other is! DoqtoColors ? this : other;
}

class AppColors {
  AppColors._();

  static const DoqtoPalette _current = DoqtoPalette.light;

  /// The palette every getter below reads.
  static DoqtoPalette get current => _current;

  // --- Primary palette (brand teal — matches logo + landing --color-primary) ---
  static const Color medBlue = Color(0xFF35878F); // brand teal: primary actions, nav bar, sent bubbles
  static Color get medBlueDark => _current.medBlueDark; // brand navy: headings, pressed states
  static Color get medBlueMid => _current.medBlueMid; // lighter teal: focused inputs, secondary highlights
  static Color get medBlueLight => _current.medBlueLight; // pale teal tint: input bg, tinted surfaces

  // --- Accent (med-teal) ---
  static const Color medTeal = Color(0xFF0ABFAD);
  static Color get medTealLight => _current.medTealLight;

  // --- Neutrals ---
  static Color get gray50 => _current.gray50;
  static Color get gray100 => _current.gray100;
  static Color get gray200 => _current.gray200;
  static Color get gray400 => _current.gray400;
  static Color get gray600 => _current.gray600;
  static Color get gray800 => _current.gray800;
  static Color get gray900 => _current.gray900;

  /// Pure white — text and icons on brand colour. For a card or sheet
  /// background use [surface], which darkens with the theme.
  static const Color white = Color(0xFFFFFFFF);

  // --- Semantic ---
  static const Color green = Color(0xFF22C55E);
  static Color get greenLight => _current.greenLight;
  static Color get greenDark => _current.greenDark;
  static const Color amber = Color(0xFFF59E0B);
  static Color get amberText => _current.amberText;
  static Color get amberLight => _current.amberLight;
  static const Color red = Color(0xFFEF4444);
  static Color get redLight => _current.redLight;
  static const Color purple = Color(0xFF7C3AED);
  static Color get purpleText => _current.purpleText;
  static Color get purpleLight => _current.purpleLight;
  static Color get tealBadgeText => _current.tealBadgeText;

  // --- Role semantics (named after design.md usage, not hex) ---
  static Color get appBg => gray50;
  static Color get surface => _current.surface;
  static Color get surfaceTinted => medBlueLight;
  static Color get divider => gray100;
  static Color get border => gray200;
  static Color get textPrimary => gray800;
  static Color get textSecondary => gray600;
  static Color get textMuted => gray400;
  static Color get textDisplay => gray900;
  static Color get primary => medBlue;
  static Color get onPrimary => white;

  /// Chat thread surfaces (batch 6): the default background behind
  /// wallpapers and the received-bubble fill when no chat theme is picked.
  static Color get threadBg => _current.threadBg;
  static Color get receivedBubble => _current.receivedBubble;

  // --- Avatar color cycle — index 0..4 ---
  // Order avoids two teals adjacent (medBlue + medTeal are both teal now).
  // Avatar fills are identity colours and do not change with the theme.
  static const List<Color> avatarCycle = [
    Color(0xFF1E2A5A), // navy
    medTeal, // bright teal
    purple,
    amber,
    medBlue, // brand teal
  ];

  static Color avatarColorFor(int index) => avatarCycle[index % avatarCycle.length];

  // --- Presence dot colors ---
  static const Color presenceOnline = green;
  static const Color presenceAway = amber;
  static Color get presenceOffline => gray400;
}
