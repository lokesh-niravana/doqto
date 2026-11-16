import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/constants/app_constants.dart';

/// Shared secure-storage options: Android EncryptedSharedPreferences; iOS
/// keychain items unlock after first device unlock and never migrate to a
/// new device via backup (M7). Reused by [BoxKeyStorage].
const kSecureStorageOptions = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);

class TokenStorage {
  static const _storage = kSecureStorageOptions;

  /// In-memory mirror of the access token for code that cannot await
  /// secure storage (image loaders building request headers). Kept in step
  /// by every read, save and clear below.
  static String? cachedAccessToken;

  Future<String?> get accessToken async {
    final t = await _storage.read(key: AppConstants.kAccessToken);
    cachedAccessToken = t;
    return t;
  }
  Future<String?> get refreshToken => _storage.read(key: AppConstants.kRefreshToken);

  Future<void> saveTokens({required String access, required String refresh}) async {
    cachedAccessToken = access;
    await _storage.write(key: AppConstants.kAccessToken, value: access);
    await _storage.write(key: AppConstants.kRefreshToken, value: refresh);
  }

  Future<void> clear() async {
    cachedAccessToken = null;
    await _storage.delete(key: AppConstants.kAccessToken);
    await _storage.delete(key: AppConstants.kRefreshToken);
  }
}
