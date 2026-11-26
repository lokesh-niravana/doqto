import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../l10n/l10n.dart';
import '../../../state/app_meta_state.dart';
import '../../widgets/primary_button.dart';

/// Full-screen "update required" (batch 6). No dismiss: the only way on is
/// the store. [message] is the server's copy, falling back to the default.
class ForceUpdateScreen extends ConsumerWidget {
  final String? message;
  const ForceUpdateScreen({super.key, this.message});

  /// Opens the store page. This button is the only way on from here, so a
  /// failure (no store app, no browser, a restricted device) is said, not
  /// swallowed.
  Future<void> _openStore(BuildContext context, WidgetRef ref) async {
    final platform = ref.read(platformNameProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var opened = false;
    try {
      opened = await ref.read(urlOpenerProvider).open(storeUrl(platform));
    } catch (_) {
      opened = false;
    }
    if (opened) return;
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        key: const ValueKey('force-update-open-failed'),
        content: Text(
          platform == 'android'
              ? Strings.playStoreOpenFailed
              : Strings.storeOpenFailed,
        ),
      ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.medBlue,
      // The message is the server's copy, of any length: fill the screen as
      // before, scroll when it does not fit (same pattern as the PIN gate).
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const SizedBox(
                height: 96,
                child: Image(image: AssetImage('assets/splash_logo_white.png')),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                l.forceUpdateTitle,
                style: AppText.display.copyWith(color: AppColors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                message ?? l.forceUpdateBody,
                key: const ValueKey('force-update-message'),
                style: AppText.body.copyWith(color: AppColors.white),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              AppButton(
                key: const ValueKey('force-update-button'),
                label: l.forceUpdateButton,
                icon: Icons.system_update_alt_rounded,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => _openStore(context, ref),
              ),
            ],
          ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
