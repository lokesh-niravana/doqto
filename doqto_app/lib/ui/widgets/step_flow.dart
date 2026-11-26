import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'primary_button.dart';

/// Reusable multi-step "stepper chrome": a progress rail of pill segments up
/// top, the current step body in the middle (horizontal slide+fade between
/// steps), and a sticky Back / Next action bar in the thumb zone.
///
/// Token-only, reduced-motion aware. Owns no step state — the parent drives
/// [currentStep] and supplies [onBack]/[onNext]. Extracted so both the group
/// create flow and future stepped flows share one chrome.
class StepFlow extends StatelessWidget {
  final int currentStep;
  final List<String> stepTitles;
  final Widget child;

  /// Null disables the Back control (first step / busy).
  final VoidCallback? onBack;

  /// Null disables the primary action (invalid step / busy).
  final VoidCallback? onNext;

  final String nextLabel;
  final bool loading;

  const StepFlow({
    super.key,
    required this.currentStep,
    required this.stepTitles,
    required this.child,
    required this.onNext,
    this.onBack,
    this.nextLabel = 'Next',
    this.loading = false,
  }) : assert(stepTitles.length > 0);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // The segments are only drawn; say where the person is.
        Semantics(
          container: true,
          label: Strings.a11yStep(
            currentStep + 1,
            stepTitles.length,
            stepTitles[currentStep.clamp(0, stepTitles.length - 1)],
          ),
          child: ExcludeSemantics(
            child: _ProgressRail(current: currentStep, total: stepTitles.length),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: AnimatedSwitcher(
            duration: AppMotion.maybe(context, AppMotion.base),
            switchInCurve: AppMotion.curveEnter,
            switchOutCurve: AppMotion.curveExit,
            transitionBuilder: (child, anim) {
              final offset = Tween<Offset>(
                begin: const Offset(0.06, 0),
                end: Offset.zero,
              ).animate(anim);
              return FadeTransition(
                opacity: anim,
                child: SlideTransition(position: offset, child: child),
              );
            },
            child: KeyedSubtree(
              key: ValueKey<int>(currentStep),
              child: child,
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.screenHorizontal,
              AppSpacing.sm,
              AppSpacing.screenHorizontal,
              AppSpacing.md,
            ),
            child: Row(
              children: [
                if (onBack != null) ...[
                  AppButton(
                    label: 'Back',
                    variant: AppButtonVariant.ghost,
                    onPressed: loading ? null : onBack,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(
                  child: AppButton(
                    label: nextLabel,
                    expand: true,
                    loading: loading,
                    onPressed: onNext,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProgressRail extends StatelessWidget {
  final int current;
  final int total;
  const _ProgressRail({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screenHorizontal,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          for (var i = 0; i < total; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: AnimatedContainer(
                duration: AppMotion.maybe(context, AppMotion.base),
                curve: AppMotion.standard,
                height: 4,
                decoration: BoxDecoration(
                  color: i <= current ? AppColors.medBlue : AppColors.gray200,
                  borderRadius: AppRadii.rFull,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A selectable row with a title, a one-line consequence caption, and a
/// leading radio dot — used for the visibility / join-policy pickers in the
/// group create flow (spec's "each with a one-line consequence").
class SelectableRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  const SelectableRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    // A radio choice: VoiceOver hears which one is picked, not only sees the
    // filled dot.
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadii.rMd,
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.maybe(context, AppMotion.micro),
            curve: AppMotion.standard,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: selected ? AppColors.medBlueLight : AppColors.surface,
              borderRadius: AppRadii.rMd,
              border: Border.all(
                color: selected ? AppColors.medBlue : AppColors.gray200,
                width: selected ? 1.5 : 1.0,
              ),
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon,
                      size: 20,
                      color: selected ? AppColors.medBlueDark : AppColors.gray600),
                  const SizedBox(width: AppSpacing.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: AppText.subheading.copyWith(
                            color: selected
                                ? AppColors.medBlueDark
                                : AppColors.textPrimary,
                          )),
                      const SizedBox(height: 2),
                      Text(subtitle, style: AppText.caption),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                AnimatedContainer(
                  duration: AppMotion.maybe(context, AppMotion.micro),
                  curve: AppMotion.standard,
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? AppColors.medBlue : Colors.transparent,
                    border: Border.all(
                      color: selected ? AppColors.medBlue : AppColors.gray400,
                      width: 1.5,
                    ),
                  ),
                  child: selected
                      ? const Icon(Icons.check, size: 14, color: AppColors.white)
                      : null,
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}
