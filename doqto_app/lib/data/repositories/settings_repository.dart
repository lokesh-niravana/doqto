import '../../core/constants/api_routes.dart';
import '../../core/enums/app_enums.dart';
import '../api/api_client.dart';
import '../models/app_meta.dart';
import '../models/notification_settings.dart';
import '../models/session.dart';
import '../models/user.dart';

/// Batch 6 settings endpoints: notification prefs, linked devices, two-step
/// PIN, change number, account export, status under the name, screenshot
/// audit and the unauthenticated app metadata. Contract: docs/settings.md.
class SettingsRepository {
  final ApiClient _api;
  SettingsRepository(this._api);

  // --- Notifications ---

  Future<NotificationSettings> getNotifications() async =>
      NotificationSettings.fromJson(await _api.get(ApiRoutes.usersMeNotifications));

  /// Partial PATCH; `{"reset": true}` restores the defaults.
  Future<NotificationSettings> patchNotifications(Map<String, dynamic> patch) async =>
      NotificationSettings.fromJson(
          await _api.patch(ApiRoutes.usersMeNotifications, body: patch));

  Future<NotificationSettings> resetNotifications() =>
      patchNotifications({'reset': true});

  // --- Linked devices ---

  Future<List<DeviceSession>> listSessions() async {
    final rows = await _api.getList(ApiRoutes.usersMeSessions);
    return [
      for (final r in rows) DeviceSession.fromJson((r as Map).cast<String, dynamic>()),
    ];
  }

  Future<void> revokeSession(String id) async {
    await _api.delete(ApiRoutes.usersMeSession(id));
  }

  /// Signs out every other device; returns how many were revoked.
  Future<int> revokeOtherSessions() async {
    final j = await _api.post(ApiRoutes.usersMeSessionsRevokeOthers);
    return (j['revoked'] as num?)?.toInt() ?? 0;
  }

  // --- Two-step PIN ---

  Future<({bool enabled, DateTime? clearsAt})> getPin() async {
    final j = await _api.get(ApiRoutes.usersMePin);
    return _pinStatus(j);
  }

  /// Set (no [currentPin]) or change (with it) the 6-digit PIN.
  Future<void> setPin(String pin, {String? currentPin}) async {
    await _api.put(ApiRoutes.usersMePin, body: {
      'pin': pin,
      'current_pin': ?currentPin,
    });
  }

  Future<void> disablePin(String pin) async {
    await _api.delete(ApiRoutes.usersMePin, body: {'pin': pin});
  }

  /// Opens this device's PIN gate after sign-in.
  Future<void> verifyPin(String pin) async {
    await _api.post(ApiRoutes.authPinVerify, body: {'pin': pin});
  }

  /// Forgot PIN: starts the 7-day wait; returns when the PIN clears.
  Future<({bool enabled, DateTime? clearsAt})> requestPinReset() async {
    final j = await _api.post(ApiRoutes.authPinResetRequest);
    return _pinStatus(j);
  }

  static ({bool enabled, DateTime? clearsAt}) _pinStatus(Map<String, dynamic> j) => (
        enabled: (j['pin_enabled'] as bool?) ?? false,
        clearsAt: j['pin_clears_at'] is String
            ? DateTime.tryParse(j['pin_clears_at'] as String)?.toUtc()
            : null,
      );

  // --- Change number ---

  /// [idToken] is the Firebase token refreshed after `updatePhoneNumber`; its
  /// phone_number claim is the proof of the new number.
  Future<User> changePhone(String idToken) async =>
      User.fromJson(await _api.patch(ApiRoutes.usersMePhone, body: {'id_token': idToken}));

  // --- Account export ---

  Future<({String url, DateTime expiresAt})> requestExport() async {
    final j = await _api.post(ApiRoutes.usersMeExport);
    return (
      url: j['url'] as String,
      expiresAt: DateTime.tryParse((j['expires_at'] ?? '') as String)?.toUtc() ??
          DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );
  }

  // --- Status under the name ---

  /// Exactly one of [preset] / [text]; neither clears. [expiresInSec] is
  /// 3600 / 28800 / 86400 or null for never.
  Future<({StatusPreset? preset, String? text, DateTime? expiresAt})> setStatus({
    StatusPreset? preset,
    String? text,
    int? expiresInSec,
  }) async {
    final j = await _api.patch(ApiRoutes.usersMeStatus, body: {
      'preset': ?preset?.wire,
      'text': ?text,
      'expires_in_sec': expiresInSec,
    });
    return (
      preset: StatusPreset.fromWire(j['status_preset'] as String?),
      text: j['status_text'] as String?,
      expiresAt: j['status_expires_at'] is String
          ? DateTime.tryParse(j['status_expires_at'] as String)?.toUtc()
          : null,
    );
  }

  // --- Screenshot audit (iOS) ---

  Future<void> auditScreenshot(String conversationId) async {
    await _api.post(ApiRoutes.auditScreenshot, body: {'conversation_id': conversationId});
  }

  // --- App metadata (no auth) ---

  Future<MinVersion> minVersion() async =>
      MinVersion.fromJson(await _api.get(ApiRoutes.appMinVersion));

  Future<LegalLinks> legal() async => LegalLinks.fromJson(await _api.get(ApiRoutes.appLegal));
}
