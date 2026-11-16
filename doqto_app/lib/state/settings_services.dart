import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_settings_state.dart';
import 'screen_security_state.dart';

/// Root-level listeners for batch 6 (watched once from DoqtoApp.build):
/// screenshot audit, Android notification channels, FLAG_SECURE policy, …
/// Each feature adds a `ref.watch(...)` here instead of editing main.dart.
final settingsServicesProvider = Provider<void>((ref) {
  // Notification settings: loaded while signed in, patched by WS.
  ref.watch(notificationSettingsSyncProvider);
  ref.watch(screenshotAuditProvider); // iOS: audit + toast on screenshot
  ref.watch(flagSecureProvider); // Android: FLAG_SECURE per org policy
});
