import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../data/services/settings_store.dart';

/// Font size choice (batch 6). The factor multiplies the platform's Dynamic
/// Type scale, so a Large system setting still grows the app.
enum AppFontSize {
  small(0.9, 'small'),
  medium(1.0, 'medium'),
  large(1.15, 'large');

  final double factor;
  final String wire;
  const AppFontSize(this.factor, this.wire);

  static AppFontSize fromWire(String? s) =>
      values.where((v) => v.wire == s).firstOrNull ?? AppFontSize.medium;
}

/// App lock re-auth timeout (batch 6).
enum AppLockTimeout {
  immediately(0),
  oneMinute(60),
  fifteenMinutes(900),
  oneHour(3600);

  final int seconds;
  const AppLockTimeout(this.seconds);

  static AppLockTimeout fromSeconds(int? s) =>
      values.where((v) => v.seconds == s).firstOrNull ??
      AppLockTimeout.immediately;
}

@immutable
class AppSettings {
  final AppFontSize fontSize;

  /// Default chat colour theme id (see core/chat_theme.dart); null = brand.
  final String? chatTheme;

  /// Default wallpaper id; null = plain thread background.
  final String? wallpaper;

  final bool enterIsSend;
  final bool voiceTranscript;

  /// null = follow the system language.
  final Locale? locale;
  final bool appLock;
  final AppLockTimeout appLockTimeout;

  const AppSettings({
    this.fontSize = AppFontSize.medium,
    this.chatTheme,
    this.wallpaper,
    this.enterIsSend = true,
    this.voiceTranscript = true,
    this.locale,
    this.appLock = false,
    this.appLockTimeout = AppLockTimeout.immediately,
  });

  static const defaults = AppSettings();

  AppSettings copyWith({
    AppFontSize? fontSize,
    String? Function()? chatTheme,
    String? Function()? wallpaper,
    bool? enterIsSend,
    bool? voiceTranscript,
    Locale? Function()? locale,
    bool? appLock,
    AppLockTimeout? appLockTimeout,
  }) =>
      AppSettings(
        fontSize: fontSize ?? this.fontSize,
        chatTheme: chatTheme == null ? this.chatTheme : chatTheme(),
        wallpaper: wallpaper == null ? this.wallpaper : wallpaper(),
        enterIsSend: enterIsSend ?? this.enterIsSend,
        voiceTranscript: voiceTranscript ?? this.voiceTranscript,
        locale: locale == null ? this.locale : locale(),
        appLock: appLock ?? this.appLock,
        appLockTimeout: appLockTimeout ?? this.appLockTimeout,
      );

  factory AppSettings.fromStore(SettingsStore s) => AppSettings(
        fontSize: AppFontSize.fromWire(s.fontSize),
        chatTheme: s.chatTheme,
        wallpaper: s.wallpaper,
        enterIsSend: s.enterIsSend ?? true,
        voiceTranscript: s.voiceTranscript ?? true,
        locale: (s.locale == null || s.locale!.isEmpty) ? null : Locale(s.locale!),
        appLock: s.appLock ?? false,
        appLockTimeout: AppLockTimeout.fromSeconds(s.appLockTimeoutSec),
      );
}

final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());

/// Device-local settings. Reads synchronously from the encrypted box on
/// first access; every setter writes through. The root widget watches this
/// for locale and text scale.
class AppSettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    try {
      return AppSettings.fromStore(ref.read(settingsStoreProvider));
    } catch (_) {
      return AppSettings.defaults; // box not open (unit tests)
    }
  }

  SettingsStore get _store => ref.read(settingsStoreProvider);

  Future<void> _persist(Future<void> Function(SettingsStore s) write) async {
    try {
      await write(_store);
    } catch (_) {}
  }

  Future<void> setFontSize(AppFontSize f) {
    state = state.copyWith(fontSize: f);
    return _persist((s) => s.setFontSize(f.wire));
  }

  Future<void> setChatTheme(String? id) {
    state = state.copyWith(chatTheme: () => id);
    return _persist((s) => s.setChatTheme(id));
  }

  Future<void> setWallpaper(String? id) {
    state = state.copyWith(wallpaper: () => id);
    return _persist((s) => s.setWallpaper(id));
  }

  Future<void> setEnterIsSend(bool v) {
    state = state.copyWith(enterIsSend: v);
    return _persist((s) => s.setEnterIsSend(v));
  }

  Future<void> setVoiceTranscript(bool v) {
    state = state.copyWith(voiceTranscript: v);
    return _persist((s) => s.setVoiceTranscript(v));
  }

  Future<void> setLocale(Locale? l) {
    state = state.copyWith(locale: () => l);
    return _persist((s) => s.setLocale(l?.languageCode));
  }

  Future<void> setAppLock(bool v) {
    state = state.copyWith(appLock: v);
    return _persist((s) => s.setAppLock(v));
  }

  Future<void> setAppLockTimeout(AppLockTimeout t) {
    state = state.copyWith(appLockTimeout: t);
    return _persist((s) => s.setAppLockTimeoutSec(t.seconds));
  }
}

final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettings>(AppSettingsNotifier.new);

/// Chat-prefs surfaces (thread, details) read this to know the default
/// theme / wallpaper without depending on the whole settings object.
final defaultChatThemeProvider =
    Provider<String?>((ref) => ref.watch(appSettingsProvider).chatTheme);
final defaultWallpaperProvider =
    Provider<String?>((ref) => ref.watch(appSettingsProvider).wallpaper);

/// Ensures providers.dart's token/api wiring is linked for consumers that
/// import only this file.
// ignore: unused_element
final _ = apiClientProvider;

/// Kept for symmetry with the other state files: a tiny debounce for
/// slider-driven writes (wallpaper dim) so Hive is not hit per pixel.
class SettingDebouncer {
  SettingDebouncer([this.delay = const Duration(milliseconds: 250)]);
  final Duration delay;
  Timer? _t;
  void call(void Function() fn) {
    _t?.cancel();
    _t = Timer(delay, fn);
  }

  void dispose() => _t?.cancel();
}
