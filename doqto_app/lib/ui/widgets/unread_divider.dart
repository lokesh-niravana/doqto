import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';

/// "N unread messages" line the thread opens at (batch 4).
class UnreadDivider extends StatelessWidget {
  final int count;
  const UnreadDivider({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('unread-divider'),
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs + 2),
      color: AppColors.medBlueLight,
      child: Center(
        child: Text(
          Strings.chatUnreadDivider(count),
          style: AppText.timestamp.copyWith(
            color: AppColors.medBlueDark,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
