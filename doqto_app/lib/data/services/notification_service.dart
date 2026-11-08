import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Thin wrapper around local notifications.
///
/// Local-first push: banners are driven by our own WebSocket while the app is
/// running (foreground or briefly backgrounded). When FCM/APNs is added later,
/// this same surface shows the remote payloads — which must be PHI-free
/// (sender/content only ever appear in LOCAL notifications, never in remote
/// payloads that transit Apple/Google).
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _channel = AndroidNotificationDetails(
    'messages',
    'Messages',
    channelDescription: 'New secure messages',
    importance: Importance.high,
    priority: Priority.high,
  );

  static const _groupsChannel = AndroidNotificationDetails(
    'groups',
    'Groups',
    channelDescription: 'New group messages',
    importance: Importance.high,
    priority: Priority.high,
  );

  static const _networkChannel = AndroidNotificationDetails(
    'network',
    'Network',
    channelDescription: 'Connection requests and network activity',
    importance: Importance.high,
    priority: Priority.high,
  );

  /// Android notification channels (batch 6). Created up front so the user
  /// sees Messages / Groups / Invitations in system settings before the first
  /// banner, and so an FCM payload's `android_channel_id` resolves. Creating
  /// an existing channel is a no-op on Android, so this is idempotent.
  ///
  /// Limitation: a channel's sound is fixed at creation, so per-tone sounds
  /// on Android O+ would need one channel per tone; these use the default.
  Future<void> ensureChannels() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    const channels = [
      AndroidNotificationChannel(
        'messages',
        'Messages',
        description: 'New secure messages',
        importance: Importance.high,
      ),
      AndroidNotificationChannel(
        'groups',
        'Groups',
        description: 'New group messages',
        importance: Importance.high,
      ),
      AndroidNotificationChannel(
        'invitations',
        'Invitations',
        description: 'Connection and group invitations',
        importance: Importance.high,
      ),
    ];
    for (final c in channels) {
      try {
        await android.createNotificationChannel(c);
      } catch (_) {
        // Never let a channel hiccup block init.
      }
    }
  }

  /// [onTap] receives the notification payload (a conversation id).
  Future<void> init({required void Function(String payload) onTap}) async {
    if (_initialized) return;
    _initialized = true;
    await _plugin.initialize(
      settings: const InitializationSettings(
        iOS: DarwinInitializationSettings(),
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload != null && payload.isNotEmpty) onTap(payload);
      },
    );
    // iOS runtime permission (no-op elsewhere).
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await ensureChannels();
  }

  /// [channelId] picks the Android channel (`messages` or `groups`);
  /// [showPreview] false replaces [body] with a generic label so the banner
  /// never carries content when the user turned previews off.
  Future<void> showMessage({
    required String conversationId,
    required String title,
    required String body,
    String channelId = 'messages',
    bool showPreview = true,
  }) async {
    await _plugin.show(
      // One notification per conversation — newest replaces older.
      id: conversationId.hashCode,
      title: title,
      body: showPreview ? body : 'New message',
      notificationDetails: NotificationDetails(
        iOS: const DarwinNotificationDetails(),
        android: channelId == 'groups' ? _groupsChannel : _channel,
      ),
      payload: conversationId,
    );
  }

  /// Networking banner (connection requests and the like). A name is not PHI,
  /// and this is a LOCAL notification either way — see the class doc.
  ///
  /// [tag] dedupes: a second banner with the same tag replaces the first, so a
  /// re-sent request never stacks. [route] is a `doqto:///…` deep link opened
  /// on tap.
  Future<void> showNetworkEvent({
    required String tag,
    required String title,
    required String body,
    required String route,
  }) async {
    await _plugin.show(
      id: tag.hashCode,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        iOS: DarwinNotificationDetails(),
        android: _networkChannel,
      ),
      payload: route,
    );
  }

  Future<void> cancelForConversation(String conversationId) =>
      _plugin.cancel(id: conversationId.hashCode);
}
