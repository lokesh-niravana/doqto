import 'package:flutter/material.dart';

/// All colors from docs/design.md. Never inline a Color(...) outside this file.
///
/// Theme-aware since batch 6. Two token sets exist — [DoqtoPalette.light] and
/// [DoqtoPalette.dark] — and every role / neutral / tint colour on [AppColors]
/// is a static getter that reads the process-wide [AppColors.current]
/// palette. The theme controller (`appSettingsProvider` → `AppTheme`) swaps
/// the palette with [AppColors.setPalette] *before* MaterialApp rebuilds with
/// the matching ThemeData, so the hundreds of `AppColors.x` call sites keep
/// compiling and simply read the right value on their next build. Widgets
/// that need to rebuild on a palette swap without a MaterialApp rebuild can
/// listen to [AppColors.palette]; code that has a BuildContext can also use
/// [DoqtoColors.of] (a ThemeExtension holding the same palette).
///
/// Brand colours that do not change between themes (teal, red, amber, green,
/// purple, pure white, presence dots, the avatar cycle) stay `const` so they
/// remain usable in const constructors.
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

  bool get isDark => brightness == Brightness.dark;

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

  /// Dark token set (batch 6): the neutral scale inverts, tints become deep
  /// washes and on-tint text lightens so the semantic pairs keep contrast.
  static const DoqtoPalette dark = DoqtoPalette(
    brightness: Brightness.dark,
    medBlueDark: Color(0xFFB9C6F0),
    medBlueMid: Color(0xFF5FA5AB),
    medBlueLight: Color(0xFF15353A),
    medTealLight: Color(0xFF0F3A36),
    gray50: Color(0xFF0B1220), // app background
    gray100: Color(0xFF1B2740), // dividers
    gray200: Color(0xFF26345A), // borders
    gray400: Color(0xFF7B8BB0), // muted text
    gray600: Color(0xFFA9B6D6), // secondary text
    gray800: Color(0xFFE3E9F7), // primary text
    gray900: Color(0xFFF3F6FC), // display text
    greenLight: Color(0xFF0F3A24),
    greenDark: Color(0xFF4ADE80),
    amberText: Color(0xFFFCD34D),
    amberLight: Color(0xFF3A2A0B),
    redLight: Color(0xFF3A1515),
    purpleText: Color(0xFFC4B5FD),
    purpleLight: Color(0xFF2A1A47),
    tealBadgeText: Color(0xFF5EEAD4),
    receivedBubble: Color(0xFF1A2540),
    threadBg: Color(0xFF0B1220),
  );

  /// The surface colour: white in light, a raised navy in dark.
  Color get surface => isDark ? const Color(0xFF121B2E) : const Color(0xFFFFFFFF);

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

  static DoqtoPalette _current = DoqtoPalette.light;

  /// The palette every getter below reads. Swapped by [setPalette].
  static DoqtoPalette get current => _current;

  /// Fires on every palette swap (the MaterialApp rebuilds on it too).
  static final ValueNotifier<DoqtoPalette> palette =
      ValueNotifier<DoqtoPalette>(DoqtoPalette.light);

  static void setPalette(DoqtoPalette p) {
    if (identical(p, _current)) return;
    _current = p;
    palette.value = p;
  }

  static bool get isDark => _current.isDark;

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
