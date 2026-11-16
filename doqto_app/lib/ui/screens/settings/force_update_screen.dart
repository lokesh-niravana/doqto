import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.medBlue,
      body: SafeArea(
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
                style: AppText.body.copyWith(color: AppColors.white.withValues(alpha: .85)),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              AppButton(
                key: const ValueKey('force-update-button'),
                label: l.forceUpdateButton,
                icon: Icons.system_update_alt_rounded,
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => ref
                    .read(urlOpenerProvider)
                    .open(storeUrl(ref.read(platformNameProvider))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
