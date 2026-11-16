import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../l10n/l10n.dart';
import '../../../state/app_lock_state.dart';
import '../../../state/settings_state.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/settings_rows.dart';

/// Settings → Privacy → App lock (batch 6). Turning the lock on requires one
/// successful Face ID / Touch ID / passcode prompt first, so nobody locks
/// themselves out of a phone that cannot authenticate.
class AppLockScreen extends ConsumerWidget {
  const AppLockScreen({super.key});

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool on) async {
    final l = context.l10n;
    final settings = ref.read(appSettingsProvider.notifier);
    if (!on) {
      await settings.setAppLock(false);
      ref.read(appLockProvider.notifier).clearLock();
      return;
    }
    final auth = ref.read(localAuthenticatorProvider);
    if (!await auth.canAuthenticate()) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.appLockUnavailable)));
      return;
    }
    final ok = await auth.authenticate(l.appLockEnableReason);
    if (!ok) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.appLockNotVerified)));
      return;
    }
    await settings.setAppLock(true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final settings = ref.watch(appSettingsProvider);
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: Text(l.settingsAppLock)),
      body: ListView(
        key: const ValueKey('app-lock-list'),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        children: [
          FadeSlideIn.staggered(
            0,
            SettingsSection(
              title: l.settingsAppLock,
              footer: l.appLockFooter,
              children: [
                SettingsSwitchRow(
                  keyPrefix: 'app-lock',
                  field: 'enabled',
                  title: l.appLockSwitch,
                  subtitle: l.appLockSwitchHint,
                  value: settings.appLock,
                  onChanged: (v) => _toggle(context, ref, v),
                  last: !settings.appLock,
                ),
                if (settings.appLock)
                  SettingsChoiceRow<AppLockTimeout>(
                    keyPrefix: 'app-lock',
                    field: 'timeout',
                    title: l.appLockAfter,
                    value: settings.appLockTimeout,
                    options: [
                      (AppLockTimeout.immediately, l.appLockImmediately),
                      (AppLockTimeout.oneMinute, l.appLockOneMinute),
                      (AppLockTimeout.fifteenMinutes, l.appLockFifteenMinutes),
                      (AppLockTimeout.oneHour, l.appLockOneHour),
                    ],
                    wire: (t) => '${t.seconds}',
                    onPick: (t) =>
                        ref.read(appSettingsProvider.notifier).setAppLockTimeout(t),
                    last: true,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
