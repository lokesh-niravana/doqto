import 'package:hive_flutter/hive_flutter.dart';

/// Device-local app settings (batch 6): theme, font size, chat colour and
/// wallpaper defaults, Enter-is-send, voice transcript, app lock, language,
/// and this device's session id. Lives in its own AES-encrypted Hive box
/// (opened in main.dart with the shared box key), never SharedPreferences.
///
/// Unlike the PHI caches this box is NOT wiped on sign-out: a doctor who
/// signs back in expects their dark theme and app lock to still be there.
/// Nothing in it is PHI (no message text, no names).
class SettingsStore {
  static const boxName = 'settings_cache';

  /// Injectable box so unit tests can use a temp-dir Hive.
  SettingsStore({Box<dynamic>? box}) : _box = box;

  final Box<dynamic>? _box;
  Box<dynamic> get box => _box ?? Hive.box(boxName);

  static const _kFontSize = 'font_size'; // 'small' | 'medium' | 'large'
  static const _kChatTheme = 'chat_theme'; // chat theme id
  static const _kWallpaper = 'wallpaper'; // wallpaper id
  static const _kEnterIsSend = 'enter_is_send';
  static const _kVoiceTranscript = 'voice_transcript';
  static const _kLocale = 'locale'; // '' | 'en' | 'es'
  static const _kAppLock = 'app_lock';
  static const _kAppLockTimeout = 'app_lock_timeout_sec';
  static const _kSessionId = 'session_id';
  static const _kDeviceName = 'device_name';

  String? getString(String key) {
    final v = box.get(key);
    return v is String ? v : null;
  }

  bool? getBool(String key) {
    final v = box.get(key);
    return v is bool ? v : null;
  }

  int? getInt(String key) {
    final v = box.get(key);
    return v is int ? v : null;
  }

  double? getDouble(String key) {
    final v = box.get(key);
    return v is num ? v.toDouble() : null;
  }

  Future<void> put(String key, Object? value) =>
      value == null ? box.delete(key) : box.put(key, value);

  String? get fontSize => getString(_kFontSize);
  Future<void> setFontSize(String v) => put(_kFontSize, v);

  String? get chatTheme => getString(_kChatTheme);
  Future<void> setChatTheme(String? v) => put(_kChatTheme, v);

  String? get wallpaper => getString(_kWallpaper);
  Future<void> setWallpaper(String? v) => put(_kWallpaper, v);

  bool? get enterIsSend => getBool(_kEnterIsSend);
  Future<void> setEnterIsSend(bool v) => put(_kEnterIsSend, v);

  bool? get voiceTranscript => getBool(_kVoiceTranscript);
  Future<void> setVoiceTranscript(bool v) => put(_kVoiceTranscript, v);

  String? get locale => getString(_kLocale);
  Future<void> setLocale(String? v) => put(_kLocale, v);

  bool? get appLock => getBool(_kAppLock);
  Future<void> setAppLock(bool v) => put(_kAppLock, v);

  int? get appLockTimeoutSec => getInt(_kAppLockTimeout);
  Future<void> setAppLockTimeoutSec(int v) => put(_kAppLockTimeout, v);

  /// The server session id behind this device's tokens (linked devices).
  String? get sessionId => getString(_kSessionId);
  Future<void> setSessionId(String? v) => put(_kSessionId, v);

  String? get deviceName => getString(_kDeviceName);
  Future<void> setDeviceName(String? v) => put(_kDeviceName, v);

  Future<void> clear() => box.clear();
}
