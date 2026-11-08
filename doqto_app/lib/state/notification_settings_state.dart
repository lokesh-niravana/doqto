import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/di/providers.dart';
import '../core/enums/app_enums.dart';
import '../data/models/notification_settings.dart';
import 'auth_state.dart';

/// My notification settings (batch 6). Optimistic like privacy_state: the
/// row flips at once, the server gets a one-field PATCH, and the row flips
/// back if that fails. The WS `notification_settings_updated` frame (sent to
/// my own devices only, payload = the full set) replaces the state so two
/// phones stay in step.
class NotificationSettingsNotifier extends AsyncNotifier<NotificationSettings> {
  @override
  Future<NotificationSettings> build() {
    final ws = ref.read(websocketClientProvider);
    final sub = ws.events.listen((e) {
      if (e.type != WsEventServer.notificationSettingsUpdated) return;
      try {
        state = AsyncData(NotificationSettings.fromJson(e.data));
      } catch (_) {}
    });
    ref.onDispose(sub.cancel);
    return ref.read(settingsRepositoryProvider).getNotifications();
  }

  /// [apply] produces the optimistic value; [patch] is what the server gets.
  Future<void> change({
    required NotificationSettings Function(NotificationSettings current) apply,
    required Map<String, dynamic> patch,
  }) async {
    final current = state.valueOrNull ?? NotificationSettings.defaults;
    state = AsyncData(apply(current));
    try {
      final confirmed =
          await ref.read(settingsRepositoryProvider).patchNotifications(patch);
      state = AsyncData(confirmed);
    } catch (e) {
      state = AsyncData(current);
      rethrow;
    }
  }

  /// "Reset notification settings": the server drops the row; the answer is
  /// the effective defaults (preview resolved from the org rule).
  Future<void> reset() async {
    final confirmed =
        await ref.read(settingsRepositoryProvider).resetNotifications();
    state = AsyncData(confirmed);
  }
}

final notificationSettingsProvider =
    AsyncNotifierProvider<NotificationSettingsNotifier, NotificationSettings>(
  NotificationSettingsNotifier.new,
);

/// Keeps the settings (and their WS patching) alive while signed in, so
/// banners built in notification_state read the current preview / tone
/// choices without waiting on a screen to open them. Watched from
/// settings_services.dart.
final notificationSettingsSyncProvider = Provider<void>((ref) {
  final stage = ref.watch(authProvider.select((s) => s.stage));
  if (stage == AuthStage.signedIn) {
    ref.watch(notificationSettingsProvider);
  } else if (stage == AuthStage.signedOut) {
    ref.invalidate(notificationSettingsProvider);
  }
});
