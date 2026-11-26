import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/shadows.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';

/// Segmented control sharing the nav-pill visual language of main_shell:
/// a white thumb with a teal outline slides under the active segment.
/// Optional per-segment count badges (e.g. "Requests (3)").
///
/// Respects reduced motion — thumb snaps with zero duration.
class AppSegmented extends StatelessWidget {
  final List<String> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  /// Optional per-segment count badge; null entries (or a null list) hide it.
  final List<int?>? badges;

  const AppSegmented({
    super.key,
    required this.tabs,
    required this.index,
    required this.onChanged,
    this.badges,
  }) : assert(tabs.length > 0);

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.maybe(context, AppMotion.micro);
    // The pill is 36pt tall; the touch row over it is 44pt. Text inside a
    // fixed-height control stops growing at 1.3x so it never clips.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: SizedBox(
        height: 44,
        child: Stack(
          children: [
            Center(
              child: Container(
                height: 36,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: AppColors.gray100,
                  borderRadius: AppRadii.rFull,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final segWidth = constraints.maxWidth / tabs.length;
                    return Stack(
                      children: [
                        AnimatedPositioned(
                          duration: duration,
                          curve: AppMotion.standard,
                          left: segWidth * index,
                          top: 0,
                          bottom: 0,
                          width: segWidth,
                          child: Container(
                            // White with a teal outline: the old pale-teal
                            // thumb was 1.03:1 against the gray track, so the
                            // selected segment was told apart by text weight
                            // alone. The outline is 4.47:1 on the track.
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: AppRadii.rFull,
                              border: Border.all(color: AppColors.medBlue),
                              boxShadow: AppShadows.card,
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            for (var i = 0; i < tabs.length; i++)
                              Expanded(child: _segment(context, i, duration)),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            // Full-height touch targets, one per segment, which also carry
            // the name and selected state for VoiceOver.
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Row(
                  children: [
                    for (var i = 0; i < tabs.length; i++)
                      Expanded(
                        child: Semantics(
                          container: true,
                          button: true,
                          selected: i == index,
                          label: _semanticLabel(i),
                          onTap: () => onChanged(i),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            excludeFromSemantics: true,
                            onTap: () => onChanged(i),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _semanticLabel(int i) {
    final count = (badges != null && i < badges!.length) ? badges![i] : null;
    return (count != null && count > 0) ? '${tabs[i]}, $count' : tabs[i];
  }

  Widget _segment(BuildContext context, int i, Duration duration) {
    final selected = i == index;
    final color = selected ? AppColors.medBlueDark : AppColors.gray600;
    final count = (badges != null && i < badges!.length) ? badges![i] : null;
    // Drawing only: taps and semantics live on the overlay row in build().
    return ExcludeSemantics(
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedDefaultTextStyle(
              duration: duration,
              curve: AppMotion.standard,
              style: AppText.button.copyWith(
                fontSize: 13,
                color: color,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
              child: Text(tabs[i], maxLines: 1, overflow: TextOverflow.fade),
            ),
            if (count != null && count > 0) ...[
              const SizedBox(width: AppSpacing.xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xs,
                  vertical: 1,
                ),
                constraints: const BoxConstraints(minWidth: 16),
                decoration: BoxDecoration(
                  color: AppColors.medBlue,
                  borderRadius: AppRadii.rFull,
                ),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  textAlign: TextAlign.center,
                  style: AppText.badge.copyWith(
                    color: AppColors.white,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
