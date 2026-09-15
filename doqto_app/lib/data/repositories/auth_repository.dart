import '../../core/constants/api_routes.dart';
import '../api/api_client.dart';
import '../api/token_storage.dart';
import '../models/user.dart';

class TokenPair {
  final String accessToken;
  final String refreshToken;
  final bool isRegistered;
  TokenPair(this.accessToken, this.refreshToken, this.isRegistered);
}

class AuthRepository {
  final ApiClient _api;
  final TokenStorage _tokens;
  AuthRepository(this._api, this._tokens);

  /// Exchange a Firebase ID token for a Doqto session. Every sign-in method
  /// ends here — the backend does not know or care which provider issued it.
  Future<TokenPair> signInWithFirebase(String idToken) async {
    final j = await _api.post(ApiRoutes.authFirebase, body: {'id_token': idToken});
    final pair = TokenPair(j['access_token'] as String, j['refresh_token'] as String,
        j['is_registered'] as bool);
    await _tokens.saveTokens(access: pair.accessToken, refresh: pair.refreshToken);
    return pair;
  }

  Future<User> register({
    required String fullName,
    required String? specialty,
    required String npiNumber,
  }) async {
    final j = await _api.post(ApiRoutes.authRegister, body: {
      'full_name': fullName,
      'specialty': specialty,
      'npi_number': npiNumber,
    });
    return User.fromJson(j);
  }

  Future<User> me() async {
    final j = await _api.get(ApiRoutes.usersMe);
    return User.fromJson(j);
  }

  Future<void> logout() async {
    try {
      await _api.post(ApiRoutes.authLogout);
    } catch (_) {}
    await _tokens.clear();
  }
}
