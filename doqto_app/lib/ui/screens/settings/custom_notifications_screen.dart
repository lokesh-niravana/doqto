import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/conversation_prefs.dart';
import '../../../data/models/notification_settings.dart';
import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../chat/chat_list_screen.dart';
import '../../widgets/settings_rows.dart';

/// Chat info → Custom notifications (batch 6). Writes `prefs.custom_tone` /
/// `prefs.custom_vibrate` through the optimistic `setPrefs`; a custom tone
/// beats the global one when the server builds a push. Keys: `chatnotif-*`.
class CustomNotificationsScreen extends ConsumerWidget {
  final String conversationId;
  const CustomNotificationsScreen({super.key, required this.conversationId});

  static bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

  Future<void> _patch(
    BuildContext context,
    WidgetRef ref,
    ConversationPrefs prefs, {
    required ConversationPrefs optimistic,
    required Map<String, dynamic> patch,
  }) async {
    try {
      await ref
          .read(conversationsProvider.notifier)
          .setPrefs(conversationId, optimistic: optimistic, patch: patch);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.commonSaveFailed)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final conv = ref
        .watch(conversationsProvider)
        .valueOrNull
        ?.where((c) => c.id == conversationId)
        .firstOrNull;
    final prefs = conv?.prefs ?? ConversationPrefs.defaults;
    final custom = prefs.customTone != null || prefs.customVibrate != null;
    final vibrate = VibratePattern.fromWire(prefs.customVibrate);
    final android = isAndroid;

    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.chatNotifTitle)),
      body: ListView(
        key: const ValueKey('chatnotif-list'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        children: [
          SettingsSection(
            title: l.notifTitle,
            footer: android ? null : l.notifVibrateIosFooter,
            children: [
              SettingsSwitchRow(
                keyPrefix: 'chatnotif',
                field: 'use_custom',
                title: l.chatNotifUseCustom,
                subtitle: l.chatNotifUseCustomHint,
                value: custom,
                onChanged: (v) {
                  if (v) {
                    // On: start from an explicit "default" tone so the row
                    // shows as custom until a tone is picked.
                    _patch(
                      context,
                      ref,
                      prefs,
                      optimistic: prefs.copyWith(
                        customVibrate: () => VibratePattern.defaultPattern.wire,
                      ),
                      patch: {'custom_vibrate': VibratePattern.defaultPattern.wire},
                    );
                  } else {
                    _patch(
                      context,
                      ref,
                      prefs,
                      optimistic: prefs.copyWith(
                        customTone: () => null,
                        customVibrate: () => null,
                      ),
                      patch: {'custom_tone': null, 'custom_vibrate': null},
                    );
                  }
                },
              ),
              Column(
                children: [
                  ListTile(
                    key: const ValueKey('chatnotif-row-tone'),
                    enabled: custom,
                    title: Text(l.notifTone, style: AppText.bodyPrimary),
                    subtitle: Text(
                      NotificationTones.label(
                        prefs.customTone ?? NotificationTones.systemDefault,
                      ),
                      key: const ValueKey('chatnotif-value-tone'),
                      style: AppText.caption.copyWith(
                        color: custom ? AppColors.medBlue : AppColors.textMuted,
                      ),
                    ),
                    trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                    onTap: custom
                        ? () => context.push(AppRoutes.tonePicker(conversationId))
                        : null,
                  ),
                  const Divider(height: 1, indent: AppSpacing.lg),
                ],
              ),
              if (android && custom)
                SettingsChoiceRow<VibratePattern>(
                  keyPrefix: 'chatnotif',
                  field: 'vibrate',
                  title: l.notifVibrate,
                  value: vibrate,
                  options: [
                    (VibratePattern.defaultPattern, l.notifVibrateDefault),
                    (VibratePattern.short, l.notifVibrateShort),
                    (VibratePattern.long, l.notifVibrateLong),
                    (VibratePattern.off, l.notifVibrateOff),
                  ],
                  wire: (v) => v.wire,
                  last: true,
                  onPick: (v) => _patch(
                    context,
                    ref,
                    prefs,
                    optimistic: prefs.copyWith(customVibrate: () => v.wire),
                    patch: {'custom_vibrate': v.wire},
                  ),
                )
              else
                ListTile(
                  key: const ValueKey('chatnotif-row-vibrate'),
                  enabled: false,
                  title: Text(l.notifVibrate, style: AppText.bodyPrimary),
                  subtitle: Text(
                    android ? l.notifVibrateDefault : l.notifVibrateDefault,
                    style: AppText.caption,
                  ),
                ),
            ],
          ),
          SettingsSection(
            title: l.chatNotifMute,
            children: [
              ListTile(
                key: const ValueKey('chatnotif-row-mute'),
                title: Text(l.chatNotifMute, style: AppText.bodyPrimary),
                subtitle: Text(
                  prefs.isMuted() ? l.chatNotifMuted : l.chatNotifNotMuted,
                  key: const ValueKey('chatnotif-value-mute'),
                  style: AppText.caption.copyWith(color: AppColors.medBlue),
                ),
                trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                onTap: conv == null
                    ? null
                    : () => _toggleMute(context, ref, conv),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Reuses the chat list's mute duration sheet (8 hours / 1 week / Always).
  Future<void> _toggleMute(
    BuildContext context,
    WidgetRef ref,
    Conversation conv,
  ) =>
      ConversationActions.toggleMute(context, ref, conv);
}
