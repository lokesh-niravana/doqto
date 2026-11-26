import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'app_pressable.dart';

/// Shared chip: selectable filter chip / deletable input chip / static tag.
///
/// Consolidation target for the four private one-offs (skills_input._SkillChip,
/// create_group inline chips, profile._SkillTag, chat_thread._DateChip) —
/// those retrofits are deferred debt, not done in M0.
class AppChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final Widget? avatar;

  const AppChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.onDelete,
    this.avatar,
  });

  static const double _minTarget = 44;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.medBlueDark : AppColors.gray600;
    final chip = AnimatedContainer(
      duration: AppMotion.maybe(context, AppMotion.micro),
      curve: AppMotion.standard,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: selected ? AppColors.medBlueLight : AppColors.gray100,
        borderRadius: AppRadii.rFull,
        // Brand teal at 1.5pt: the lighter medBlueMid outline was 2.44:1.
        // Same width when unselected, so selecting never shifts the layout.
        border: Border.all(
          color: selected ? AppColors.medBlue : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (avatar != null) ...[
            avatar!,
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(label, style: AppText.badge.copyWith(color: fg, fontSize: 12)),
          if (onDelete != null) ...[
            // The cross is 14pt to look at and 44pt to touch, so a chip that
            // can be removed is taller than a plain one. A touch area cannot
            // extend past its own box, so the box has to be the full size.
            AppPressable(
              onTap: onDelete,
              minTarget: true,
              semanticLabel: 'Remove $label',
              child: Icon(Icons.close_rounded, size: 14, color: fg),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return chip;
    // The pill keeps its size, centred in a touch area at least 44pt each way
    // (a short label like "All" is only about 40pt wide).
    return AppPressable(
      onTap: onTap,
      selected: selected,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: _minTarget, minHeight: _minTarget),
        child: Align(widthFactor: 1, heightFactor: 1, child: chip),
      ),
    );
  }
}
