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

  group('a notification tap that launched the app', () {
    late bool signedIn;
    late bool onLaunch;
    late List<String> nav;
    late List<void Function()> frames;
    late NotificationRouteOpener opener;

    void runFrame() {
      final due = List.of(frames);
      frames.clear();
      for (final f in due) {
        f();
      }
    }

    setUp(() {
      signedIn = false;
      onLaunch = true;
      nav = [];
      frames = [];
      opener = NotificationRouteOpener(
        signedIn: () => signedIn,
        onLaunchScreen: () => onLaunch,
        push: (p) => nav.add('push $p'),
        goHome: () {
          nav.add('go chats');
          onLaunch = false;
        },
        afterFrame: frames.add,
      );
    });

    test('waits for sign-in, then opens over Chats so Back leads home', () {
      opener.open('/chat/c1');
      expect(nav, isEmpty, reason: 'the splash would replace it');
      expect(opener.pending, '/chat/c1');

      // Bootstrap settles; the splash does its own go(chats) this frame.
      signedIn = true;
      opener.flushSoon();
      expect(nav, isEmpty);
      runFrame();
      expect(nav, ['go chats']);
      runFrame();
      expect(nav, ['go chats', 'push /chat/c1']);
      expect(opener.pending, isNull);

      // Nothing replays on a later sign-in event.
      opener.flushSoon();
      runFrame();
      expect(nav.length, 2);
    });

    test('signed in but still on the splash: remembered, then opened', () {
      signedIn = true;
      opener.open('/people/u1');
      expect(nav, isEmpty);
      runFrame();
      runFrame();
      expect(nav, ['go chats', 'push /people/u1']);
    });

    test('a warm tap pushes at once', () {
      signedIn = true;
      onLaunch = false;
      opener.open('/chat/c2');
      expect(nav, ['push /chat/c2']);
      expect(opener.pending, isNull);
    });

    test('signing out drops a remembered tap', () {
      opener.open('/chat/c1');
      opener.clear();
      signedIn = true;
      opener.flushSoon();
      runFrame();
      expect(nav, isEmpty);
    });

    test('still not signed in when the frame runs: stays remembered', () {
      opener.open('/chat/c1');
      opener.afterFrame(opener.flush);
      runFrame();
      expect(nav, isEmpty);
      expect(opener.pending, '/chat/c1');
    });
  });
}
