import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/app_constants.dart';
import 'package:doqto_app/core/utils/avatar_urls.dart';
import 'package:doqto_app/data/models/group.dart';

/// Avatars load from a stable API URL (presigned S3 links expire in five
/// minutes, so pictures vanished on any screen painted from older state).
void main() {
  test('user avatar URL is stable per upload and null without a picture', () {
    expect(userAvatarUrl('u1', null), isNull);
    expect(userAvatarUrl('u1', ''), isNull);
    expect(userAvatarUrl(null, 'avatars/u1/a.jpg'), isNull);
    final a = userAvatarUrl('u1', 'avatars/u1/a.jpg')!;
    expect(a, '${AppConstants.apiBaseUrl}/api/v1/users/u1/avatar?v=a.jpg');
    expect(userAvatarUrl('u1', 'avatars/u1/a.jpg'), a, reason: 'same upload, same URL');
    expect(userAvatarUrl('u1', 'avatars/u1/b.jpg'), isNot(a), reason: 'new upload, new URL');
    expect(isApiImageUrl(a), isTrue);
    expect(isApiImageUrl('https://bucket.s3.amazonaws.com/x?X-Amz-Signature=1'), isFalse);
  });

  test('group avatar URL', () {
    expect(groupAvatarUrl('g1', 'groups/g1/p.png'),
        '${AppConstants.apiBaseUrl}/api/v1/groups/g1/avatar?v=p.png');
    expect(groupAvatarUrl('g1', null), isNull);
  });

  test('direct invites carry the invitee; links do not', () {
    final direct = GroupInvite.fromJson({
      'id': 'i2', 'group_id': 'g1', 'inviter_id': 'me', 'invitee_id': 'u2',
      'invitee_name': 'Dr. Sarah Kim', 'invitee_avatar_url': 'avatars/u2/x.jpg',
      'state': 'pending',
    });
    expect(direct.isDirect, isTrue);
    expect(direct.isLink, isFalse);
    expect(direct.inviteeInitials, 'SK');
    final link = GroupInvite.fromJson({
      'id': 'i1', 'group_id': 'g1', 'inviter_id': 'me', 'token': 't', 'state': 'pending',
    });
    expect(link.isDirect, isFalse);
    expect(link.isLink, isTrue);
  });
}
