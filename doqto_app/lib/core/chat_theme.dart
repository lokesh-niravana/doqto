import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens/colors.dart';

/// Chat colour themes + wallpapers (batch 6).
///
/// A [ChatTheme] is a sent / received bubble pair with light and dark
/// variants. The default (`prefs.theme == null`) is the device-wide choice in
/// `appSettingsProvider.chatTheme`, and when that is unset too, [ChatTheme.teal]
/// — the brand look every build before batch 6 shipped with. Per-chat picks
/// go to `PATCH /conversations/{id}/prefs {theme}`.
///
/// The thread wraps its body in a [ChatThemeScope]; [MessageBubble] and the
/// composer read it with [ChatThemeScope.of]. Without a scope (widget tests,
/// previews) the brand colours apply.
@immutable
class ChatTheme {
  final String id;
  final String name;
  final Color sentLight;
  final Color sentDark;
  final Color receivedLight;
  final Color receivedDark;

  /// Text on a sent bubble (light / dark). Received text follows the palette.
  final Color onSentLight;
  final Color onSentDark;

  const ChatTheme({
    required this.id,
    required this.name,
    required this.sentLight,
    required this.sentDark,
    required this.receivedLight,
    required this.receivedDark,
    this.onSentLight = const Color(0xFFFFFFFF),
    this.onSentDark = const Color(0xFFFFFFFF),
  });

  static const teal = ChatTheme(
    id: 'teal',
    name: 'Doqto teal',
    sentLight: Color(0xFF35878F),
    sentDark: Color(0xFF2E7078),
    receivedLight: Color(0xFFFFFFFF),
    receivedDark: Color(0xFF1A2540),
  );

  static const List<ChatTheme> all = [
    teal,
    ChatTheme(
      id: 'ocean',
      name: 'Ocean',
      sentLight: Color(0xFF1D6FD1),
      sentDark: Color(0xFF1E4F8F),
      receivedLight: Color(0xFFEAF2FF),
      receivedDark: Color(0xFF17243D),
    ),
    ChatTheme(
      id: 'forest',
      name: 'Forest',
      sentLight: Color(0xFF2F7D4F),
      sentDark: Color(0xFF285F40),
      receivedLight: Color(0xFFEAF7EE),
      receivedDark: Color(0xFF162A1F),
    ),
    ChatTheme(
      id: 'sunset',
      name: 'Sunset',
      sentLight: Color(0xFFE0633A),
      sentDark: Color(0xFFA7472A),
      receivedLight: Color(0xFFFFF1EA),
      receivedDark: Color(0xFF2E1C16),
    ),
    ChatTheme(
      id: 'plum',
      name: 'Plum',
      sentLight: Color(0xFF7C3AED),
      sentDark: Color(0xFF5B2DB3),
      receivedLight: Color(0xFFF4EDFF),
      receivedDark: Color(0xFF241A3A),
    ),
    ChatTheme(
      id: 'rose',
      name: 'Rose',
      sentLight: Color(0xFFD1366B),
      sentDark: Color(0xFF9B2A52),
      receivedLight: Color(0xFFFFEDF3),
      receivedDark: Color(0xFF2E1722),
    ),
    ChatTheme(
      id: 'slate',
      name: 'Slate',
      sentLight: Color(0xFF475569),
      sentDark: Color(0xFF334155),
      receivedLight: Color(0xFFF1F5F9),
      receivedDark: Color(0xFF1E293B),
    ),
    ChatTheme(
      id: 'sand',
      name: 'Sand',
      sentLight: Color(0xFFB7791F),
      sentDark: Color(0xFF8A5A14),
      receivedLight: Color(0xFFFBF4E4),
      receivedDark: Color(0xFF2B2314),
    ),
    ChatTheme(
      id: 'mint',
      name: 'Mint',
      sentLight: Color(0xFF0E9F8E),
      sentDark: Color(0xFF0B7A6D),
      receivedLight: Color(0xFFE6FAF6),
      receivedDark: Color(0xFF122E2A),
    ),
    ChatTheme(
      id: 'indigo',
      name: 'Indigo',
      sentLight: Color(0xFF4338CA),
      sentDark: Color(0xFF3730A3),
      receivedLight: Color(0xFFEEF0FF),
      receivedDark: Color(0xFF1B1E3F),
    ),
    ChatTheme(
      id: 'coral',
      name: 'Coral',
      sentLight: Color(0xFFE5484D),
      sentDark: Color(0xFFA8363A),
      receivedLight: Color(0xFFFFEEEE),
      receivedDark: Color(0xFF301818),
    ),
    ChatTheme(
      id: 'graphite',
      name: 'Graphite',
      sentLight: Color(0xFF1F2937),
      sentDark: Color(0xFF374151),
      receivedLight: Color(0xFFF3F4F6),
      receivedDark: Color(0xFF111827),
    ),
  ];

  static ChatTheme? byId(String? id) =>
      id == null ? null : all.where((t) => t.id == id).firstOrNull;

  Color sent(bool dark) => dark ? sentDark : sentLight;
  Color received(bool dark) => dark ? receivedDark : receivedLight;
  Color onSent(bool dark) => dark ? onSentDark : onSentLight;
}

/// Bundled wallpaper patterns, painted with [WallpaperPainter] — no assets.
enum WallpaperPattern {
  dots,
  grid,
  waves,
  diagonal,
  hex,
  plus,
  circles,
  triangles;

  String get id => 'pattern:$name';
  String get label => switch (this) {
        WallpaperPattern.dots => 'Dots',
        WallpaperPattern.grid => 'Grid',
        WallpaperPattern.waves => 'Waves',
        WallpaperPattern.diagonal => 'Diagonal',
        WallpaperPattern.hex => 'Hex',
        WallpaperPattern.plus => 'Plus',
        WallpaperPattern.circles => 'Circles',
        WallpaperPattern.triangles => 'Triangles',
      };

  static WallpaperPattern? fromId(String? id) {
    if (id == null || !id.startsWith('pattern:')) return null;
    final n = id.substring(8);
    return values.where((p) => p.name == n).firstOrNull;
  }
}

/// A wallpaper choice as stored in `prefs.wallpaper` / the device default:
/// `pattern:<name>`, `solid:<AARRGGBB hex>`, `local` (own photo on this
/// device only), or null for the plain thread background.
@immutable
class WallpaperSpec {
  final WallpaperPattern? pattern;
  final Color? solid;
  final File? localPhoto;

  const WallpaperSpec._({this.pattern, this.solid, this.localPhoto});

  static const none = WallpaperSpec._();
  const WallpaperSpec.pattern(WallpaperPattern p) : this._(pattern: p);
  const WallpaperSpec.solid(Color c) : this._(solid: c);
  const WallpaperSpec.photo(File f) : this._(localPhoto: f);

  bool get isNone => pattern == null && solid == null && localPhoto == null;

  static const String localId = 'local';

  /// Solid colour choices offered by the picker.
  static const List<Color> solids = [
    Color(0xFFE6F1F2),
    Color(0xFFEAF2FF),
    Color(0xFFEAF7EE),
    Color(0xFFFFF1EA),
    Color(0xFFF4EDFF),
    Color(0xFFFFEDF3),
    Color(0xFFF1F5F9),
    Color(0xFFFBF4E4),
    Color(0xFF17243D),
    Color(0xFF162A1F),
    Color(0xFF241A3A),
    Color(0xFF111827),
  ];

  static String solidId(Color c) =>
      'solid:${c.toARGB32().toRadixString(16).padLeft(8, '0')}';

  /// Parses a stored id. [localPhoto] resolves the `local` marker (null when
  /// the file is missing on this device → plain background).
  static WallpaperSpec parse(String? id, {File? localPhoto}) {
    if (id == null || id.isEmpty) return none;
    if (id == localId) return localPhoto == null ? none : WallpaperSpec.photo(localPhoto);
    final p = WallpaperPattern.fromId(id);
    if (p != null) return WallpaperSpec.pattern(p);
    if (id.startsWith('solid:')) {
      final v = int.tryParse(id.substring(6), radix: 16);
      if (v != null) return WallpaperSpec.solid(Color(v));
    }
    return none;
  }

  String? get id {
    if (pattern != null) return pattern!.id;
    if (solid != null) return solidId(solid!);
    if (localPhoto != null) return localId;
    return null;
  }
}

/// Everything a thread needs to paint itself.
@immutable
class ChatThemeData {
  final ChatTheme theme;
  final bool dark;
  final WallpaperSpec wallpaper;

  /// 0..1 darkening over the wallpaper (dark mode only).
  final double dim;

  const ChatThemeData({
    required this.theme,
    required this.dark,
    this.wallpaper = WallpaperSpec.none,
    this.dim = 0,
  });

  static const brandLight = ChatThemeData(theme: ChatTheme.teal, dark: false);

  Color get sentBg => theme.sent(dark);
  Color get sentFg => theme.onSent(dark);
  Color get receivedBg => theme.received(dark);
  Color get receivedFg => AppColors.textPrimary;

  /// Border around received bubbles — only on a white bubble over a plain
  /// light background, where it is the one thing separating the two.
  Color? get receivedBorder =>
      !dark && receivedBg == const Color(0xFFFFFFFF) ? AppColors.gray100 : null;

  /// The colour behind the wallpaper (and the whole body when there is none).
  Color get background => wallpaper.solid ?? AppColors.threadBg;

  /// Pattern stroke colour: a tint of the sent colour, subtle on both ends.
  Color get patternInk => theme.sent(dark).withValues(alpha: dark ? 0.22 : 0.16);
}

/// Resolves the effective theme for one conversation.
class ChatThemeResolver {
  ChatThemeResolver._();

  static ChatThemeData resolve({
    required bool dark,
    String? chatTheme,
    String? wallpaper,
    String? defaultTheme,
    String? defaultWallpaper,
    double dim = 0,
    File? localPhoto,
  }) {
    final theme = ChatTheme.byId(chatTheme) ?? ChatTheme.byId(defaultTheme) ?? ChatTheme.teal;
    final wpId = (wallpaper != null && wallpaper.isNotEmpty) ? wallpaper : defaultWallpaper;
    return ChatThemeData(
      theme: theme,
      dark: dark,
      wallpaper: WallpaperSpec.parse(wpId, localPhoto: localPhoto),
      dim: dark ? dim.clamp(0.0, 1.0) : 0,
    );
  }
}

/// Makes a [ChatThemeData] available to the bubbles below it.
class ChatThemeScope extends InheritedWidget {
  final ChatThemeData data;
  const ChatThemeScope({super.key, required this.data, required super.child});

  static ChatThemeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatThemeScope>()?.data;

  /// Brand teal under the current palette when no scope is present.
  static ChatThemeData of(BuildContext context) =>
      maybeOf(context) ?? ChatThemeData(theme: ChatTheme.teal, dark: AppColors.isDark);

  @override
  bool updateShouldNotify(ChatThemeScope old) =>
      old.data.theme != data.theme ||
      old.data.dark != data.dark ||
      old.data.wallpaper.id != data.wallpaper.id ||
      old.data.dim != data.dim;
}

/// Paints the wallpaper (pattern, solid or photo, plus the dark dim) behind
/// [child]. Sized by its parent; the thread puts the whole body in it.
class ChatWallpaperBackground extends StatelessWidget {
  final ChatThemeData data;
  final Widget child;
  const ChatWallpaperBackground({super.key, required this.data, required this.child});

  @override
  Widget build(BuildContext context) {
    final wp = data.wallpaper;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: data.background),
        if (wp.localPhoto != null)
          Image.file(wp.localPhoto!, fit: BoxFit.cover, gaplessPlayback: true)
        else if (wp.pattern != null)
          CustomPaint(
            painter: WallpaperPainter(wp.pattern!, data.patternInk),
          ),
        if (data.dim > 0)
          ColoredBox(color: Colors.black.withValues(alpha: data.dim * 0.7)),
        child,
      ],
    );
  }
}

/// Eight subtle repeating patterns, drawn with strokes — no bitmap assets.
class WallpaperPainter extends CustomPainter {
  final WallpaperPattern pattern;
  final Color ink;
  const WallpaperPainter(this.pattern, this.ink);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ink
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final fill = Paint()..color = ink;
    const step = 28.0;
    switch (pattern) {
      case WallpaperPattern.dots:
        for (var y = step / 2; y < size.height; y += step) {
          for (var x = step / 2; x < size.width; x += step) {
            canvas.drawCircle(Offset(x, y), 1.6, fill);
          }
        }
      case WallpaperPattern.grid:
        for (var x = 0.0; x <= size.width; x += step) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
        for (var y = 0.0; y <= size.height; y += step) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      case WallpaperPattern.waves:
        for (var y = 0.0; y <= size.height + step; y += step) {
          final path = Path()..moveTo(0, y);
          for (var x = 0.0; x <= size.width; x += 4) {
            path.lineTo(x, y + math.sin(x / step * math.pi) * 5);
          }
          canvas.drawPath(path, paint);
        }
      case WallpaperPattern.diagonal:
        for (var d = -size.height; d < size.width; d += step) {
          canvas.drawLine(Offset(d, 0), Offset(d + size.height, size.height), paint);
        }
      case WallpaperPattern.hex:
        const r = 14.0;
        final w = r * math.sqrt(3);
        var row = 0;
        for (var y = 0.0; y < size.height + r; y += r * 1.5, row++) {
          final offset = row.isOdd ? w / 2 : 0.0;
          for (var x = offset; x < size.width + w; x += w) {
            final path = Path();
            for (var i = 0; i < 6; i++) {
              final a = math.pi / 6 + i * math.pi / 3;
              final p = Offset(x + r * math.cos(a), y + r * math.sin(a));
              i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
            }
            path.close();
            canvas.drawPath(path, paint);
          }
        }
      case WallpaperPattern.plus:
        for (var y = step / 2; y < size.height; y += step) {
          for (var x = step / 2; x < size.width; x += step) {
            canvas.drawLine(Offset(x - 4, y), Offset(x + 4, y), paint);
            canvas.drawLine(Offset(x, y - 4), Offset(x, y + 4), paint);
          }
        }
      case WallpaperPattern.circles:
        const big = step * 1.5;
        for (var y = 0.0; y < size.height + big; y += big) {
          for (var x = 0.0; x < size.width + big; x += big) {
            canvas.drawCircle(Offset(x, y), big / 2, paint);
          }
        }
      case WallpaperPattern.triangles:
        for (var y = 0.0; y < size.height + step; y += step) {
          for (var x = 0.0; x < size.width + step; x += step) {
            final path = Path()
              ..moveTo(x, y + step)
              ..lineTo(x + step / 2, y)
              ..lineTo(x + step, y + step)
              ..close();
            canvas.drawPath(path, paint);
          }
        }
    }
  }

  @override
  bool shouldRepaint(WallpaperPainter old) =>
      old.pattern != pattern || old.ink != ink;
}
