import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:permission_handler/permission_handler.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../data/models/notification_settings.dart';
import '../../../l10n/l10n.dart';
import '../../../state/notification_settings_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/settings_rows.dart';
import '../../../core/utils/async_retry.dart';

/// Settings → Notifications (batch 6). Messages and Groups each get a tone,
/// vibration (Android), preview and priority (Android); then reactions and
/// the in-app sounds / haptics. Every change is a one-field PATCH with an
/// optimistic flip and rollback toast. Keys: `notif-switch-<field>`,
/// `notif-row-<field>`, `notif-opt-<field>-<wire>`, `notif-reset`.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  /// Vibrate / priority are Android concepts; iOS shows the explanatory
  /// footer instead of a dead control.
  static bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(notificationSettingsProvider);
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.notifTitle)),
      body: Column(
        children: [
          // Nothing below can take effect while iOS itself has notifications
          // switched off for the app, so say so and offer the way to fix it.
          const _PermissionBanner(),
          Expanded(
            child: async.whenRetrying(
              loading: () => const _Skeleton(),
              error: (e, _) => _ErrorPane(
                onRetry: () => ref.invalidate(notificationSettingsProvider),
              ),
              data: (s) => _Body(settings: s),
            ),
          ),
        ],
      ),
    );
  }
}

final _pushDeniedProvider = FutureProvider.autoDispose<bool>((ref) async {
  try {
    return await ref.watch(pushTokenProviderProvider).permissionDenied();
  } catch (_) {
    return false;
  }
});

/// Shows [_PermissionOffBanner] while the system has notifications off, and
/// asks again each time the app comes back to the foreground: the user has
/// usually just been to Settings to turn them on.
class _PermissionBanner extends ConsumerStatefulWidget {
  const _PermissionBanner();

  @override
  ConsumerState<_PermissionBanner> createState() => _PermissionBannerState();
}

class _PermissionBannerState extends ConsumerState<_PermissionBanner> {
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: () => ref.invalidate(_pushDeniedProvider),
  );

  @override
  void initState() {
    super.initState();
    _lifecycle; // start listening
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final denied = ref.watch(_pushDeniedProvider).valueOrNull ?? false;
    return denied ? const _PermissionOffBanner() : const SizedBox.shrink();
  }
}

class _PermissionOffBanner extends StatelessWidget {
  const _PermissionOffBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('notif-permission-off'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.amberLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Notifications are turned off for Doqto in Settings, so you '
            "won't be alerted to new messages.",
            style: AppText.bodyPrimary.copyWith(color: AppColors.amberText),
          ),
          TextButton(
            onPressed: openAppSettings,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 44),
              foregroundColor: AppColors.amberText,
            ),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final NotificationSettings settings;
  const _Body({required this.settings});

  Future<void> _save(
    BuildContext context,
    WidgetRef ref, {
    required NotificationSettings Function(NotificationSettings) apply,
    required Map<String, dynamic> patch,
  }) async {
    try {
      await ref
          .read(notificationSettingsProvider.notifier)
          .change(apply: apply, patch: patch);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.commonSaveFailed)));
    }
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.notifResetTitle),
        content: Text(l.notifResetBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.commonCancel),
          ),
          TextButton(
            key: const ValueKey('notif-reset-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.notifResetConfirm),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    try {
      await ref.read(notificationSettingsProvider.notifier).reset();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.notifResetDone)));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.commonSaveFailed)));
    }
  }

  List<(VibratePattern, String)> _vibrateOptions(BuildContext context) {
    final l = context.l10n;
    return [
      (VibratePattern.defaultPattern, l.notifVibrateDefault),
      (VibratePattern.short, l.notifVibrateShort),
      (VibratePattern.long, l.notifVibrateLong),
      (VibratePattern.off, l.notifVibrateOff),
    ];
  }

  /// One section per kind (messages / groups).
  Widget _kindSection(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String kind,
    required String tone,
    required VibratePattern vibrate,
    required bool showPreview,
    required bool highPriority,
  }) {
    final l = context.l10n;
    final android = NotificationsScreen.isAndroid;
    return SettingsSection(
      title: title,
      footer: android ? null : l.notifVibrateIosFooter,
      children: [
        Column(
          children: [
            ListTile(
              key: ValueKey('notif-row-${kind}_tone'),
              title: Text(l.notifTone, style: AppText.bodyPrimary),
              subtitle: Text(
                NotificationTones.label(tone),
                key: ValueKey('notif-value-${kind}_tone'),
                style: AppText.caption.copyWith(color: AppColors.medBlue),
              ),
              trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
              onTap: () => context.push(AppRoutes.tonePicker(kind)),
            ),
            const Divider(height: 1, indent: AppSpacing.lg),
          ],
        ),
        if (android)
          SettingsChoiceRow<VibratePattern>(
            keyPrefix: 'notif',
            field: '${kind}_vibrate',
            title: l.notifVibrate,
            value: vibrate,
            options: _vibrateOptions(context),
            wire: (v) => v.wire,
            onPick: (v) => _save(
              context,
              ref,
              apply: (s) => kind == 'messages'
                  ? s.copyWith(messagesVibrate: v)
                  : s.copyWith(groupsVibrate: v),
              patch: {'${kind}_vibrate': v.wire},
            ),
          )
        else
          Column(
            children: [
              ListTile(
                key: ValueKey('notif-row-${kind}_vibrate'),
                enabled: false,
                // Not adjustable on iOS: drawn in the disabled colour (the
                // explicit text styles would otherwise keep it at full
                // strength). The section footer says why.
                title: Text(
                  l.notifVibrate,
                  style: AppText.bodyPrimary.copyWith(color: Theme.of(context).disabledColor),
                ),
                subtitle: Text(
                  l.notifVibrateDefault,
                  style: AppText.caption.copyWith(color: Theme.of(context).disabledColor),
                ),
              ),
              const Divider(height: 1, indent: AppSpacing.lg),
            ],
          ),
        SettingsSwitchRow(
          keyPrefix: 'notif',
          field: '${kind}_show_preview',
          title: l.notifShowPreview,
          subtitle: l.notifShowPreviewHint,
          value: showPreview,
          last: !android,
          onChanged: (v) => _save(
            context,
            ref,
            apply: (s) => kind == 'messages'
                ? s.copyWith(messagesShowPreview: v)
                : s.copyWith(groupsShowPreview: v),
            patch: {'${kind}_show_preview': v},
          ),
        ),
        if (android)
          SettingsSwitchRow(
            keyPrefix: 'notif',
            field: '${kind}_high_priority',
            title: l.notifHighPriority,
            subtitle: l.notifHighPriorityHint,
            value: highPriority,
            last: true,
            onChanged: (v) => _save(
              context,
              ref,
              apply: (s) => kind == 'messages'
                  ? s.copyWith(messagesHighPriority: v)
                  : s.copyWith(groupsHighPriority: v),
              patch: {'${kind}_high_priority': v},
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final s = settings;
    return ListView(
      key: const ValueKey('notif-list'),
      // Explicit padding drops the automatic safe-area inset; add it back so
      // the last row clears the home indicator.
      padding: EdgeInsets.only(
        top: AppSpacing.lg,
        bottom: AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        FadeSlideIn.staggered(
          0,
          _kindSection(
            context,
            ref,
            title: l.notifMessages,
            kind: 'messages',
            tone: s.messagesTone,
            vibrate: s.messagesVibrate,
            showPreview: s.messagesShowPreview,
            highPriority: s.messagesHighPriority,
          ),
        ),
        FadeSlideIn.staggered(
          1,
          _kindSection(
            context,
            ref,
            title: l.notifGroups,
            kind: 'groups',
            tone: s.groupsTone,
            vibrate: s.groupsVibrate,
            showPreview: s.groupsShowPreview,
            highPriority: s.groupsHighPriority,
          ),
        ),
        FadeSlideIn.staggered(
          2,
          SettingsSection(
            title: l.notifReactions,
            children: [
              SettingsSwitchRow(
                keyPrefix: 'notif',
                field: 'reaction_notifications',
                title: l.notifReactionNotifications,
                subtitle: l.notifReactionNotificationsHint,
                value: s.reactionNotifications,
                last: true,
                onChanged: (v) => _save(
                  context,
                  ref,
                  apply: (x) => x.copyWith(reactionNotifications: v),
                  patch: {'reaction_notifications': v},
                ),
              ),
            ],
          ),
        ),
        FadeSlideIn.staggered(
          3,
          SettingsSection(
            title: l.notifInApp,
            children: [
              SettingsSwitchRow(
                keyPrefix: 'notif',
                field: 'conversation_tones',
                title: l.notifConversationTones,
                subtitle: l.notifConversationTonesHint,
                value: s.conversationTones,
                onChanged: (v) => _save(
                  context,
                  ref,
                  apply: (x) => x.copyWith(conversationTones: v),
                  patch: {'conversation_tones': v},
                ),
              ),
              SettingsSwitchRow(
                keyPrefix: 'notif',
                field: 'haptics',
                title: l.notifHaptics,
                subtitle: l.notifHapticsHint,
                value: s.haptics,
                last: true,
                onChanged: (v) => _save(
                  context,
                  ref,
                  apply: (x) => x.copyWith(haptics: v),
                  patch: {'haptics': v},
                ),
              ),
            ],
          ),
        ),
        FadeSlideIn.staggered(
          4,
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: AppButton(
              key: const ValueKey('notif-reset'),
              label: l.notifReset,
              variant: AppButtonVariant.secondary,
              expand: true,
              onPressed: () => _reset(context, ref),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

const _kLoadFailed =
    "Your notification settings couldn't be loaded. Check your connection and try again.";

class _ErrorPane extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorPane({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 48, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.md),
            // Says what went wrong; an icon alone is silent to VoiceOver.
            // Announced when it replaces the loading state.
            Semantics(
              container: true,
              liveRegion: true,
              child: Text(
                _kLoadFailed,
                key: const ValueKey('notifications-load-failed'),
                style: AppText.caption,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: context.l10n.commonRetry,
              onPressed: onRetry,
              variant: AppButtonVariant.secondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    // The grey blocks are only drawn; a screen reader hears "Loading" once.
    return Semantics(
      container: true,
      label: Strings.loading,
      liveRegion: true,
      child: ExcludeSemantics(
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenHorizontal,
            vertical: AppSpacing.xl,
          ),
          children: [
            AppSkeleton.line(width: 120),
            const SizedBox(height: AppSpacing.sm),
            AppSkeleton.block(height: 220),
            const SizedBox(height: AppSpacing.lg),
            AppSkeleton.line(width: 96),
            const SizedBox(height: AppSpacing.sm),
            AppSkeleton.block(height: 220),
          ],
        ),
      ),
    );
  }
}
