import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/state/notification_state.dart';

void main() {
  test('invite_joined opens the new connection, else the network tab', () {
    expect(routePathForPushData({'type': 'invite_joined', 'user_id': 'u1'}), '/people/u1');
    expect(routePathForPushData({'type': 'invite_joined', 'user_id': ''}), '/network');
    expect(routePathForPushData({'conversation_id': 'c1'}), '/chat/c1');
  });
}
