import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../l10n/l10n.dart';
import '../../state/app_lock_state.dart';
import '../../state/auth_state.dart';
import 'confirm_sign_out.dart';
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
        // The lock screen and the privacy cover replace the app, they don't
        // float over it: while either is up, nothing underneath can be read
        // by VoiceOver or reached by a tap or a switch-control scan.
        AbsorbPointer(
          absorbing: lock.locked || lock.covered,
          child: ExcludeSemantics(
            excluding: lock.locked || lock.covered,
            child: child,
          ),
        ),
        if (lock.locked)
          // Its own Navigator: the gate sits above the app's (it is mounted
          // from MaterialApp.builder), and the app underneath is inert, so
          // the sign-out confirmation needs somewhere of its own to show.
          // (No hero controller: the app's Navigator owns the one in scope.)
          HeroControllerScope.none(
            child: Navigator(
              key: const ValueKey('app-lock-screen'),
              onGenerateRoute: (_) => PageRouteBuilder<void>(
                pageBuilder: (_, _, _) => const _LockScreen(),
              ),
            ),
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

class _LockScreen extends ConsumerWidget {
  const _LockScreen();

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final auth = ref.read(authProvider.notifier);
    final lock = ref.read(appLockProvider.notifier);
    if (!await confirmSignOut(context)) return;
    await auth.signOut();
    // The session and its cached chats are gone: nothing left to guard, and
    // the sign-in screen must be reachable.
    lock.clearLock();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final lock = ref.watch(appLockProvider);
    final busy = lock.prompting;
    final reason = switch (lock.failure) {
      null => null,
      AppLockFailure.notConfirmed => Strings.appLockFailed,
      AppLockFailure.unavailable => Strings.appLockUnavailable,
    };
    return Material(
      color: AppColors.appBg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
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
                // Always in the tree so the reason is announced when it
                // appears; empty until an attempt fails.
                Semantics(
                  container: true,
                  liveRegion: true,
                  child: reason == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.md),
                          child: Text(
                            reason,
                            key: const ValueKey('app-lock-failure'),
                            style: AppText.body.copyWith(color: AppColors.red),
                            textAlign: TextAlign.center,
                          ),
                        ),
                ),
                const SizedBox(height: AppSpacing.xl),
                AppButton(
                  key: const ValueKey('app-lock-unlock'),
                  label: l.appLockUnlock,
                  icon: Icons.fingerprint,
                  loading: busy,
                  onPressed: busy ? null : () => ref.read(appLockProvider.notifier).unlock(),
                ),
                const SizedBox(height: AppSpacing.sm),
                // The way out when the phone can no longer authenticate.
                TextButton(
                  key: const ValueKey('app-lock-sign-out'),
                  onPressed: () => _signOut(context, ref),
                  child: Text(l.settingsSignOut, style: TextStyle(color: AppColors.red)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
