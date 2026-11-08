import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/enums/app_enums.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/session.dart';
import '../../../l10n/l10n.dart';
import '../../../state/sessions_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/settings_rows.dart';

/// Settings → Linked devices (batch 6): this device, then every other live
/// session with a per-row sign out, and "Sign out of all other devices".
class LinkedDevicesScreen extends ConsumerWidget {
  const LinkedDevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(sessionsProvider);
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.settingsLinkedDevices)),
      body: async.when(
        loading: () => const _Skeleton(),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(ErrorMessages.forApi(e), style: AppText.body, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  label: l.commonRetry,
                  variant: AppButtonVariant.secondary,
                  onPressed: () => ref.invalidate(sessionsProvider),
                ),
              ],
            ),
          ),
        ),
        data: (sessions) => _Body(sessions: sessions),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final List<DeviceSession> sessions;
  const _Body({required this.sessions});

  Future<bool> _confirm(BuildContext context, String title, String body, String action) async {
    final l = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(l.commonCancel)),
          TextButton(
            key: const ValueKey('devices-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref, DeviceSession s) async {
    final l = context.l10n;
    if (!await _confirm(context, l.devicesSignOutTitle(s.title), l.devicesSignOutBody, l.devicesSignOut)) {
      return;
    }
    try {
      await ref.read(sessionsProvider.notifier).revoke(s.id);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
    }
  }

  Future<void> _revokeOthers(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    if (!await _confirm(context, l.devicesSignOutOthers, l.devicesSignOutOthersBody, l.devicesSignOut)) {
      return;
    }
    try {
      final n = await ref.read(sessionsProvider.notifier).revokeOthers();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.devicesSignedOutCount(n))));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final current = sessions.where((s) => s.current).firstOrNull;
    final others = [for (final s in sessions) if (!s.current) s];
    return ListView(
      key: const ValueKey('devices-list'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      children: [
        if (current != null)
          FadeSlideIn.staggered(
            0,
            SettingsSection(
              title: l.devicesThisDevice,
              children: [_SessionRow(session: current, last: true)],
            ),
          ),
        FadeSlideIn.staggered(
          1,
          SettingsSection(
            title: l.devicesOtherDevices,
            footer: l.devicesFooter,
            children: [
              if (others.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    l.devicesNone,
                    key: const ValueKey('devices-empty'),
                    style: AppText.body,
                    textAlign: TextAlign.center,
                  ),
                )
              else
                for (var i = 0; i < others.length; i++)
                  _SessionRow(
                    session: others[i],
                    last: i == others.length - 1,
                    onRevoke: () => _revoke(context, ref, others[i]),
                  ),
            ],
          ),
        ),
        if (others.isNotEmpty)
          FadeSlideIn.staggered(
            2,
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: AppButton(
                key: const ValueKey('devices-revoke-others'),
                label: l.devicesSignOutOthers,
                icon: Icons.logout,
                variant: AppButtonVariant.danger,
                expand: true,
                onPressed: () => _revokeOthers(context, ref),
              ),
            ),
          ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final DeviceSession session;
  final bool last;
  final VoidCallback? onRevoke;
  const _SessionRow({required this.session, required this.last, this.onRevoke});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final s = session;
    final icon = switch (s.platform) {
      DevicePlatform.ios => Icons.phone_iphone_rounded,
      DevicePlatform.android => Icons.phone_android_rounded,
      null => Icons.devices_other_rounded,
    };
    final meta = [
      if (s.appVersion != null) 'Doqto ${s.appVersion}',
      s.current ? l.devicesActiveNow : formatLastActive(s.lastSeenAt),
    ].join(' · ');
    return Column(
      children: [
        ListTile(
          key: ValueKey('devices-row-${s.id}'),
          leading: Icon(icon, color: AppColors.medBlue),
          title: Text(s.title, style: AppText.bodyPrimary),
          subtitle: Text(meta, style: AppText.caption),
          trailing: onRevoke == null
              ? null
              : TextButton(
                  key: ValueKey('devices-revoke-${s.id}'),
                  onPressed: onRevoke,
                  child: Text(l.devicesSignOut, style: TextStyle(color: AppColors.red)),
                ),
        ),
        if (!last) const Divider(height: 1, indent: AppSpacing.lg),
      ],
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenHorizontal,
        vertical: AppSpacing.xl,
      ),
      children: [
        AppSkeleton.line(width: 120),
        const SizedBox(height: AppSpacing.sm),
        AppSkeleton.block(height: 72),
        const SizedBox(height: AppSpacing.lg),
        AppSkeleton.line(width: 96),
        const SizedBox(height: AppSpacing.sm),
        AppSkeleton.block(height: 160),
      ],
    );
  }
}
