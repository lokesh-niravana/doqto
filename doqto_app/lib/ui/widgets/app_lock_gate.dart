import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../l10n/l10n.dart';
import '../../state/app_lock_state.dart';
import 'primary_button.dart';

/// App lock overlay (batch 6). Wraps the whole app (MaterialApp.builder):
/// - while the app is not in the foreground, an opaque brand cover sits over
///   the content, so neither the task switcher snapshot (AppDelegate blurs
///   it too) nor a quick peek shows PHI;
/// - while a re-auth is owed, a lock screen with an Unlock button replaces
///   the content until Face ID / Touch ID / passcode succeeds.
class AppLockGate extends ConsumerWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (lock.locked)
          _LockScreen(
            key: const ValueKey('app-lock-screen'),
            onUnlock: () => ref.read(appLockProvider.notifier).unlock(),
            busy: lock.prompting,
          )
        else if (lock.covered)
          const _PrivacyCover(key: ValueKey('app-lock-cover')),
      ],
    );
  }
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.medBlue,
      child: Center(
        child: SizedBox(
          width: 96,
          child: Image(image: AssetImage('assets/splash_logo_white.png')),
        ),
      ),
    );
  }
}

class _LockScreen extends StatelessWidget {
  final VoidCallback onUnlock;
  final bool busy;
  const _LockScreen({super.key, required this.onUnlock, required this.busy});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Material(
      color: AppColors.appBg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: AppColors.medBlueLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.lock_rounded, size: 40, color: AppColors.medBlue),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(l.appLockLockedTitle, style: AppText.display, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.sm),
              Text(l.appLockLockedBody, style: AppText.body, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                key: const ValueKey('app-lock-unlock'),
                label: l.appLockUnlock,
                icon: Icons.fingerprint,
                loading: busy,
                onPressed: busy ? null : onUnlock,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
