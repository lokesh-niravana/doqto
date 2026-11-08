import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/state/notification_state.dart';

void main() {
  test('invite_joined opens the new connection, else the network tab', () {
    expect(routePathForPushData({'type': 'invite_joined', 'user_id': 'u1'}), '/people/u1');
    expect(routePathForPushData({'type': 'invite_joined', 'user_id': ''}), '/network');
    expect(routePathForPushData({'conversation_id': 'c1'}), '/chat/c1');
  });

  test('group_invite lands on Group info (where Accept lives)', () {
    expect(routePathForPushData({'type': 'group_invite', 'group_id': 'g1'}),
        '/groups/g1/info');
    expect(routePathForPushData({'type': 'group_invite'}), '/groups');
  });

  test('access_request push lands on My Org → Access requests', () {
    expect(routePathForPushData({'type': 'access_request', 'access_request_id': 'r1'}),
        '/my-org/access-requests');
  });

  test('universal-link paths route to the chat and the profile', () {
    expect(routePathForPayload('doqto:///c/c1'), '/chat/c1');
    expect(routePathForPayload('https://api.doqto.ai/c/c1'), '/chat/c1');
    expect(routePathForPayload('https://api.doqto.ai/u/u1'), '/people/u1');
    expect(routePathForPayload('https://api.doqto.ai/g/tok'), '/g/tok');
  });

  test('in-app payload routes: groups, group info, invite link', () {
    expect(routePathForPayload('doqto:///groups/g1'), '/groups/g1');
    expect(routePathForPayload('doqto:///groups/g1/info'), '/groups/g1/info');
    expect(routePathForPayload('doqto:///g/tok'), '/g/tok');
  });
}
