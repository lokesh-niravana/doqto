import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/typography.dart';
import 'app_pressable.dart';

enum AppButtonVariant { primary, secondary, ghost, danger }

class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final bool loading;
  final IconData? icon;
  final bool expand;

  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.loading = false,
    this.icon,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (variant) {
      AppButtonVariant.primary => (AppColors.medBlue, AppColors.white, null),
      AppButtonVariant.secondary => (AppColors.medBlueLight, AppColors.medBlueDark, null),
      AppButtonVariant.ghost => (Colors.transparent, AppColors.textSecondary, AppColors.gray200),
      AppButtonVariant.danger => (AppColors.redLight, AppColors.red, null),
    };

    final labelRow = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 8),
        ],
        // Wraps to two lines and then truncates, so a long or enlarged label
        // never overflows the row; the 44pt-minimum container grows with it.
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: AppText.button.copyWith(color: fg),
          ),
        ),
      ],
    );

    // Invisible label holds the width; visible content crossfades on top —
    // no width jump when swapping label ↔ spinner.
    final child = Stack(
      alignment: Alignment.center,
      children: [
        Visibility(
          visible: false,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: labelRow,
        ),
        AnimatedSwitcher(
          duration: AppMotion.maybe(context, AppMotion.micro),
          switchInCurve: AppMotion.curveEnter,
          switchOutCurve: AppMotion.curveExit,
          child: loading
              ? SizedBox(
                  key: const ValueKey('spinner'),
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                )
              : KeyedSubtree(key: const ValueKey('label'), child: labelRow),
        ),
      ],
    );

    final button = AppPressable(
      onTap: loading ? null : onPressed,
      enabled: onPressed != null,
      haptic: variant == AppButtonVariant.primary,
      // While loading the label is hidden behind the spinner; keep the name.
      semanticLabel: loading ? label : null,
      child: Material(
        color: bg,
        borderRadius: AppRadii.rFull,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: AppRadii.rFull,
            border: border != null ? Border.all(color: border, width: 1.5) : null,
          ),
          constraints: const BoxConstraints(minHeight: 44),
          child: child,
        ),
      ),
    );

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
