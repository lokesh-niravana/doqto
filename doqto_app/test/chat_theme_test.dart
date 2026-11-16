import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/chat_theme.dart';

/// Chat theme / wallpaper model (batch 6): ids round-trip, the resolver
/// falls back per-chat → default → teal, and dim only applies in dark.
void main() {
  test('ChatTheme.all has 12 unique ids and byId finds each', () {
    expect(ChatTheme.all.length, 12);
    expect(ChatTheme.all.map((t) => t.id).toSet().length, 12);
    for (final t in ChatTheme.all) {
      expect(ChatTheme.byId(t.id), same(t));
    }
    expect(ChatTheme.byId('nope'), isNull);
    expect(ChatTheme.byId(null), isNull);
  });

  test('WallpaperPattern ids round-trip through fromId', () {
    expect(WallpaperPattern.values.length, 8);
    for (final p in WallpaperPattern.values) {
      expect(p.id, 'pattern:${p.name}');
      expect(WallpaperPattern.fromId(p.id), p);
    }
    expect(WallpaperPattern.fromId('pattern:stars'), isNull);
    expect(WallpaperPattern.fromId('solid:ff000000'), isNull);
  });

  test('WallpaperSpec parse/id round-trips patterns, solids, local, none', () {
    for (final p in WallpaperPattern.values) {
      expect(WallpaperSpec.parse(p.id).pattern, p);
      expect(WallpaperSpec.parse(p.id).id, p.id);
    }
    for (final c in WallpaperSpec.solids) {
      final id = WallpaperSpec.solidId(c);
      final spec = WallpaperSpec.parse(id);
      expect(spec.solid, c);
      expect(spec.id, id);
    }
    expect(WallpaperSpec.parse(null).isNone, isTrue);
    expect(WallpaperSpec.parse('').isNone, isTrue);
    expect(WallpaperSpec.parse('garbage').isNone, isTrue);
    expect(WallpaperSpec.parse('solid:zz').isNone, isTrue);
    // `local` is the plain background until this device has the file.
    expect(WallpaperSpec.parse('local').isNone, isTrue);
    final f = File('/tmp/doqto-wallpaper-test.jpg');
    final photo = WallpaperSpec.parse('local', localPhoto: f);
    expect(photo.localPhoto, f);
    expect(photo.id, 'local');
  });

  test('solidId is 8-digit lowercase hex', () {
    expect(WallpaperSpec.solidId(const Color(0xFF111827)), 'solid:ff111827');
    expect(WallpaperSpec.solidId(const Color(0x00000001)), 'solid:00000001');
  });

  test('resolver: per-chat theme wins, then default, then teal', () {
    final a = ChatTheme.all[3];
    final b = ChatTheme.all[5];
    expect(
      ChatThemeResolver.resolve(chatTheme: a.id, defaultTheme: b.id).theme,
      same(a),
    );
    expect(
      ChatThemeResolver.resolve(chatTheme: null, defaultTheme: b.id).theme,
      same(b),
    );
    expect(
      ChatThemeResolver.resolve(chatTheme: 'bogus', defaultTheme: 'bogus').theme,
      same(ChatTheme.teal),
    );
  });

  test('resolver: per-chat wallpaper wins; empty string falls back to default', () {
    final dots = WallpaperPattern.dots.id;
    final grid = WallpaperPattern.grid.id;
    expect(
      ChatThemeResolver.resolve(wallpaper: dots, defaultWallpaper: grid)
          .wallpaper
          .pattern,
      WallpaperPattern.dots,
    );
    expect(
      ChatThemeResolver.resolve(wallpaper: '', defaultWallpaper: grid)
          .wallpaper
          .pattern,
      WallpaperPattern.grid,
    );
    expect(
      ChatThemeResolver.resolve(wallpaper: null, defaultWallpaper: null)
          .wallpaper
          .isNone,
      isTrue,
    );
  });

  test('every theme has distinct, opaque sent/received colours', () {
    for (final t in ChatTheme.all) {
      expect(t.sent, isNot(t.received), reason: t.id);
      expect(t.sent.a, 1.0, reason: t.id);
      expect(t.received.a, 1.0, reason: t.id);
    }
  });
}
