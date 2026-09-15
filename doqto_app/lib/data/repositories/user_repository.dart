import 'dart:io';

import '../../core/constants/api_routes.dart';
import '../../core/enums/app_enums.dart';
import '../api/api_client.dart';
import '../models/user.dart';

class UserPatchBody {
  final String? fullName;
  final String? email;
  final String? specialty;
  final String? bio;
  final String? city;
  final String? state;
  final int? yearsOfExperience;
  final List<String>? skills;

  const UserPatchBody({
    this.fullName,
    this.email,
    this.specialty,
    this.bio,
    this.city,
    this.state,
    this.yearsOfExperience,
    this.skills,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (fullName != null) map['full_name'] = fullName;
    if (email != null) map['email'] = email;
    if (specialty != null) map['specialty'] = specialty;
    if (bio != null) map['bio'] = bio;
    if (city != null) map['city'] = city;
    if (state != null) map['state'] = state;
    if (yearsOfExperience != null) map['years_of_experience'] = yearsOfExperience;
    if (skills != null) map['skills'] = skills;
    return map;
  }
}

class UserRepository {
  final ApiClient _api;
  UserRepository(this._api);

  /// App Store 5.1.1(v). Irreversible: scrubs the profile, destroys authored
  /// content and the social graph server-side. The caller must sign out —
  /// every subsequent request 401s with `account_deleted`.
  Future<void> deleteAccount() async {
    await _api.delete(ApiRoutes.usersMe);
  }

  /// Attach a phone the client already proved through Firebase. [idToken] is
  /// the token refreshed after linking; its phone_number claim is the proof.
  /// Contract: docs/auth.md.
  Future<User> linkPhone(String idToken) async {
    final j = await _api.post(ApiRoutes.usersMePhone, body: {'id_token': idToken});
    return User.fromJson(j);
  }

  Future<User> updateMe(UserPatchBody patch) async {
    final j = await _api.patch(ApiRoutes.usersMe, body: patch.toJson());
    return User.fromJson(j);
  }

  Future<User> uploadAvatar(File file) async {
    final bytes = await file.readAsBytes();
    final filename = file.path.split('/').last;
    final mime = _mimeFor(filename);
    final j = await _api.postMultipart(
      ApiRoutes.usersMeAvatar,
      fileField: 'file',
      bytes: bytes,
      filename: filename,
      contentType: mime,
    );
    return User.fromJson(j);
  }

  Future<User> deleteAvatar() async {
    final j = await _api.delete(ApiRoutes.usersMeAvatar);
    return User.fromJson(j);
  }

  /// Register (upsert) this device's push token for the signed-in user.
  Future<void> registerPushToken({
    required String token,
    required DevicePlatform platform,
  }) async {
    await _api.post(ApiRoutes.usersMePushTokens, body: {
      'token': token,
      'platform': platform.wire,
    });
  }

  /// Best-effort removal on logout so a signed-out device stops being pushed.
  Future<void> unregisterPushToken({required String token}) async {
    await _api.delete(ApiRoutes.usersMePushTokens, body: {'token': token});
  }

  String _mimeFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }
}
