import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'primary_button.dart';

/// A list or sheet that failed to load: the reason and a Retry button, so
/// the user is never left with only a sentence and no way forward.
class LoadFailed extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  /// The retry is in flight: the button shows its spinner (and says so)
  /// instead of looking like the tap did nothing.
  final bool loading;
  const LoadFailed({
    super.key,
    required this.message,
    required this.onRetry,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Announced when it replaces the loading state.
          Semantics(
            container: true,
            liveRegion: true,
            child: Text(message, style: AppText.caption, textAlign: TextAlign.center),
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            key: const ValueKey('load-failed-retry'),
            label: Strings.retry,
            icon: Icons.refresh_rounded,
            variant: AppButtonVariant.secondary,
            loading: loading,
            onPressed: loading ? null : onRetry,
          ),
        ],
      ),
    );
  }
}
