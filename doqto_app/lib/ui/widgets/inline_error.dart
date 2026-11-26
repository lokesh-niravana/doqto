import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'fade_slide_in.dart';

/// Reusable inline error row: warning icon + physician-friendly message in red.
/// Collapses to nothing when [message] is null/empty so callers can render it
/// unconditionally. The row animates in (fade + slide + size) when a message
/// appears; reduced-motion aware via AppMotion.
class InlineError extends StatelessWidget {
  final String? message;
  const InlineError(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    final text = message;
    final hasText = text != null && text.isNotEmpty;
    return AnimatedSize(
      duration: AppMotion.maybe(context, AppMotion.enter),
      curve: AppMotion.curveEnter,
      alignment: Alignment.topLeft,
      child: !hasText
          ? const SizedBox(width: double.infinity)
          : Padding(
              // Re-key on the message so a *new* error replays the entrance.
              key: ValueKey<String>(text),
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: FadeSlideIn(
                // Announced when it appears, not only drawn.
                child: Semantics(
                  container: true,
                  liveRegion: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 14,
                        color: AppColors.red,
                      ),
                      const SizedBox(width: AppSpacing.xs + 2),
                      Expanded(
                        child: Text(
                          text,
                          style: AppText.caption.copyWith(color: AppColors.red),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
