import '../constants/api_routes.dart';
import '../constants/app_constants.dart';

/// Avatar image URLs the app can cache.
///
/// Presigned S3 links expire after five minutes, and screens paint avatars
/// from state that is often older than that (the chat list cache, a thread
/// opened an hour in). Every re-presign is also a new URL, so the image
/// cache missed on each refresh and the picture blinked back to initials.
/// The API now serves the bytes itself at a stable, authenticated URL; the
/// `v` query is the stored object's file name, so a new upload is a new URL
/// and the old one simply stops being asked for.
String? userAvatarUrl(String? userId, String? avatarKey) {
  if (userId == null || userId.isEmpty || avatarKey == null || avatarKey.isEmpty) {
    return null;
  }
  return '${AppConstants.apiBaseUrl}${ApiRoutes.userAvatar(userId)}?v=${_version(avatarKey)}';
}

String? groupAvatarUrl(String? groupId, String? avatarKey) {
  if (groupId == null || groupId.isEmpty || avatarKey == null || avatarKey.isEmpty) {
    return null;
  }
  return '${AppConstants.apiBaseUrl}${ApiRoutes.groupAvatar(groupId)}?v=${_version(avatarKey)}';
}

/// True for URLs our API serves, which need the bearer token.
bool isApiImageUrl(String url) => url.startsWith(AppConstants.apiBaseUrl);

String _version(String key) => Uri.encodeQueryComponent(key.split('/').last);
