import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';

/// A white busy spinner on a dark translucent disc, for use over photos: a
/// bare white ring disappears on a white picture.
class ScrimSpinner extends StatelessWidget {
  const ScrimSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.gray900.withValues(alpha: 0.65),
        shape: BoxShape.circle,
      ),
      child: const CircularProgressIndicator(
        color: AppColors.white,
        strokeWidth: 3,
        semanticsLabel: Strings.loading,
      ),
    );
  }
}
