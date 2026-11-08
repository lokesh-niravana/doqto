import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:doqto_app/data/services/settings_store.dart';
import 'package:doqto_app/state/settings_state.dart';

/// SettingsStore + AppSettings.fromStore (batch 6) against a real temp-dir
/// Hive box: every setter is read back, unknown wires fall back to defaults,
/// and the box survives clear() of the PHI caches (it has its own clear).
void main() {
  late Directory tmp;
  late Box<dynamic> box;
  late SettingsStore store;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('doqto-settings-store-');
    Hive.init(tmp.path);
    box = await Hive.openBox<dynamic>('settings_store_test');
  });

  setUp(() async {
    await box.clear();
    store = SettingsStore(box: box);
  });

  tearDownAll(() async {
    await box.close();
    await tmp.delete(recursive: true);
  });

  test('empty box → AppSettings.defaults', () {
    final s = AppSettings.fromStore(store);
    expect(s.themeMode, ThemeMode.system);
    expect(s.fontSize, AppFontSize.medium);
    expect(s.chatTheme, isNull);
    expect(s.wallpaper, isNull);
    expect(s.wallpaperDim, 0);
    expect(s.enterIsSend, isTrue);
    expect(s.voiceTranscript, isTrue);
    expect(s.locale, isNull);
    expect(s.appLock, isFalse);
    expect(s.appLockTimeout, AppLockTimeout.immediately);
  });

  test('setters write through and fromStore reads them back', () async {
    await store.setThemeMode('dark');
    await store.setFontSize('large');
    await store.setChatTheme('ocean');
    await store.setWallpaper('pattern:dots');
    await store.setWallpaperDim(0.4);
    await store.setEnterIsSend(false);
    await store.setVoiceTranscript(false);
    await store.setLocale('es');
    await store.setAppLock(true);
    await store.setAppLockTimeoutSec(3600);
    await store.setSessionId('sess-1');
    await store.setDeviceName('iPhone');

    expect(store.themeMode, 'dark');
    expect(store.sessionId, 'sess-1');
    expect(store.deviceName, 'iPhone');

    final s = AppSettings.fromStore(store);
    expect(s.themeMode, ThemeMode.dark);
    expect(s.fontSize, AppFontSize.large);
    expect(s.chatTheme, 'ocean');
    expect(s.wallpaper, 'pattern:dots');
    expect(s.wallpaperDim, closeTo(0.4, 1e-9));
    expect(s.enterIsSend, isFalse);
    expect(s.voiceTranscript, isFalse);
    expect(s.locale, const Locale('es'));
    expect(s.appLock, isTrue);
    expect(s.appLockTimeout, AppLockTimeout.oneHour);
  });

  test('null clears chat theme / wallpaper / locale', () async {
    await store.setChatTheme('ocean');
    await store.setWallpaper('local');
    await store.setLocale('es');
    await store.setChatTheme(null);
    await store.setWallpaper(null);
    await store.setLocale('');
    final s = AppSettings.fromStore(store);
    expect(s.chatTheme, isNull);
    expect(s.wallpaper, isNull);
    expect(s.locale, isNull, reason: 'empty string = system language');
  });

  test('unknown or mistyped values fall back instead of throwing', () async {
    await store.put('theme_mode', 'sepia');
    await store.put('font_size', 42);
    await store.put('wallpaper_dim', 7.5);
    await store.put('enter_is_send', 'yes');
    final s = AppSettings.fromStore(store);
    expect(s.themeMode, ThemeMode.system);
    expect(s.fontSize, AppFontSize.medium);
    expect(s.wallpaperDim, 1.0, reason: 'clamped to 0..1');
    expect(s.enterIsSend, isTrue, reason: 'non-bool ignored');
  });

  test('typed getters ignore values of the wrong type', () async {
    await store.put('k', 'text');
    expect(store.getString('k'), 'text');
    expect(store.getBool('k'), isNull);
    expect(store.getInt('k'), isNull);
    expect(store.getDouble('k'), isNull);
    await store.put('k', 3);
    expect(store.getInt('k'), 3);
    expect(store.getString('k'), isNull);
  });

  test('clear() empties the box', () async {
    await store.setThemeMode('light');
    await store.clear();
    expect(store.themeMode, isNull);
    expect(box.isEmpty, isTrue);
  });

  test('modeWire round-trips with fromStore', () async {
    for (final m in ThemeMode.values) {
      await store.setThemeMode(AppSettings.modeWire(m));
      expect(AppSettings.fromStore(store).themeMode, m);
    }
  });
}
