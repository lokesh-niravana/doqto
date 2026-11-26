import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';

/// Semantic tone of an [InlineBanner] — amber / blue / gray / red pairs.
enum BannerTone { warn, info, neutral, danger }

/// Thin full-width strip that animates open/closed (26pt or taller ↔ 0), the same
/// collapse pattern as the original ConnectivityBanner. Tokens-only; respects
/// reduced motion via [AppMotion.maybe].
class InlineBanner extends StatelessWidget {
  final BannerTone tone;
  final String text;
  final IconData? icon;

  /// Optional leading widget (e.g. a small progress spinner). Wins over [icon].
  final Widget? leading;

  /// Optional trailing action (e.g. a small text button).
  final Widget? action;

  final bool visible;

  /// Line cap for [text]. Two suits one-line status strips; a full-sentence
  /// warning passes more so it is not cut off at large text sizes.
  final int maxLines;

  const InlineBanner({
    super.key,
    required this.tone,
    required this.text,
    this.icon,
    this.leading,
    this.action,
    this.visible = true,
    this.maxLines = 2,
  });

  static Color backgroundFor(BannerTone tone) => switch (tone) {
        BannerTone.warn => AppColors.amberLight,
        BannerTone.info => AppColors.medBlueLight,
        BannerTone.neutral => AppColors.gray100,
        BannerTone.danger => AppColors.redLight,
      };

  static Color foregroundFor(BannerTone tone) => switch (tone) {
        BannerTone.warn => AppColors.amberText,
        BannerTone.info => AppColors.medBlueDark,
        BannerTone.neutral => AppColors.gray600,
        BannerTone.danger => AppColors.red,
      };

  @override
  Widget build(BuildContext context) {
    final fg = foregroundFor(tone);
    // The strip is 26pt at the default text size and grows with the text:
    // a fixed 26 clipped the label above about 1.67x. AnimatedSize keeps
    // the open/close slide; the colour stays behind it while it closes.
    return ColoredBox(
      color: backgroundFor(tone),
      child: AnimatedSize(
        duration: AppMotion.maybe(context, AppMotion.base),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: !visible
            ? const SizedBox(width: double.infinity)
            : Container(
                constraints: const BoxConstraints(minHeight: 26),
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (leading != null) ...[
                      leading!,
                      const SizedBox(width: AppSpacing.sm),
                    ] else if (icon != null) ...[
                      Icon(icon, size: 13, color: fg),
                      const SizedBox(width: AppSpacing.xs),
                    ],
                    Flexible(
                      child: Text(
                        text,
                        maxLines: maxLines,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: AppText.caption.copyWith(color: fg),
                      ),
                    ),
                    if (action != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      action!,
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}
