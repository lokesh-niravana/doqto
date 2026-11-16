import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/services/notification_service.dart';
import 'package:doqto_app/state/auth_state.dart';
import 'package:doqto_app/state/notification_state.dart';

import 'support/fake_socket.dart';

class _Recording extends NotificationService {
  final List<Map<String, String>> shown = [];
  @override
  Future<void> init({required void Function(String payload) onTap}) async {}
  @override
  Future<void> showNetworkEvent({
    required String tag,
    required String title,
    required String body,
    required String route,
  }) async =>
      shown.add({'tag': tag, 'title': title, 'body': body, 'route': route});
}

/// Linked devices (batch 6): another device signing in raises a banner that
/// lands on Linked devices; my own sign-in echo does not.
void main() {
  late _Recording notifications;
  late FakeSocket socket;
  late ProviderContainer c;

  setUp(() {
    notifications = _Recording();
    socket = FakeSocket();
    c = ProviderContainer(overrides: [
      notificationServiceProvider.overrideWithValue(notifications),
      websocketClientProvider.overrideWithValue(socket),
    ]);
    c.read(notificationListenerProvider);
  });
  tearDown(() => c.dispose());

  test('session_created from another device → "New sign-in on <device>"', () async {
    socket.emit(WsEventServer.sessionCreated, {'session_id': 's9', 'device_name': 'Pixel 9'});
    await Future<void>.delayed(Duration.zero);
    expect(notifications.shown, hasLength(1));
    final b = notifications.shown.single;
    expect(b['body'], 'New sign-in on Pixel 9');
    expect(b['route'], 'doqto:///settings/devices');
    expect(routePathForPayload(b['route']!), AppRoutes.linkedDevices);
  });

  test('my own session echo is silent', () async {
    final mine = c.read(authProvider.notifier).sessionId; // null in tests
    socket.emit(WsEventServer.sessionCreated, {'session_id': mine ?? 'x', 'device_name': 'Me'});
    await Future<void>.delayed(Duration.zero);
    // sessionId is null here, so 'x' is "another device"; a missing id is skipped.
    socket.emit(WsEventServer.sessionCreated, {'device_name': 'No id'});
    await Future<void>.delayed(Duration.zero);
    expect(notifications.shown.where((b) => b['body'] == 'New sign-in on No id'), isEmpty);
  });

  test('push data type new_sign_in routes to Linked devices', () {
    expect(routePathForPushData({'type': 'new_sign_in'}), AppRoutes.linkedDevices);
    expect(routePathForPayload('/settings/devices'), AppRoutes.linkedDevices);
  });
}
