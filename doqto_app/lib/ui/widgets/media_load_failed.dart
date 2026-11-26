import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';

/// A photo or video that could not be loaded, on the dark full-screen media
/// background: what happened in words, and a way to try again. White on
/// gray900 is 17.8:1.
class MediaLoadFailed extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const MediaLoadFailed({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ExcludeSemantics(
              child: Icon(Icons.error_outline_rounded, color: AppColors.white, size: 40),
            ),
            const SizedBox(height: AppSpacing.md),
            // Announced when it replaces the loading state.
            Semantics(
              container: true,
              liveRegion: true,
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.white),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton(
              key: const ValueKey('media-load-retry'),
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.white,
                side: const BorderSide(color: AppColors.white, width: 1.5),
                minimumSize: const Size(44, 44),
              ),
              child: const Text(Strings.tryAgain),
            ),
          ],
        ),
      ),
    );
  }
}
