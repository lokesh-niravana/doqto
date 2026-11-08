import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'doctor_avatar.dart';

/// A minimal spec for one overlapping mutual avatar.
class MutualAvatarSpec {
  final String initials;
  final int colorIndex;
  final String? imageUrl;
  const MutualAvatarSpec({
    required this.initials,
    this.colorIndex = 0,
    this.imageUrl,
  });
}

/// Overlapping (−8px) stack of [DoctorAvatar]s (28dp) followed by a caption
/// derived from `contextLabel` (server-provided) or a pluralized mutual count.
/// Shows a "+N" overflow bubble when the count exceeds the shown avatars.
/// Renders nothing when there is neither a label nor any mutuals.
class MutualsLine extends StatelessWidget {
  final List<MutualAvatarSpec> avatars;
  final int mutualCount;
  final String? contextLabel;
  final int maxAvatars;

  const MutualsLine({
    super.key,
    this.avatars = const [],
    this.mutualCount = 0,
    this.contextLabel,
    this.maxAvatars = 3,
  });

  static const double _size = 28;
  static const double _step = 20; // 28 − 8 overlap

  @override
  Widget build(BuildContext context) {
    final label = _label();
    if (label == null && avatars.isEmpty) return const SizedBox.shrink();

    final shown = avatars.length < maxAvatars ? avatars.length : maxAvatars;
    final total = mutualCount > 0 ? mutualCount : avatars.length;
    final overflow = total - shown;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (shown > 0) ...[
          _AvatarStack(
            specs: avatars.take(shown).toList(),
            overflow: overflow > 0 ? overflow : 0,
            step: _step,
            size: _size,
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
        if (label != null)
          Flexible(
            child: Text(
              label,
              style: AppText.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  String? _label() {
    final ctx = contextLabel?.trim();
    if (ctx != null && ctx.isNotEmpty) return ctx;
    if (mutualCount <= 0) return null;
    return mutualCount == 1
        ? '1 ${Strings.netMutualConnections.toLowerCase().replaceAll('connections', 'connection')}'
        : '$mutualCount ${Strings.netMutualConnections.toLowerCase()}';
  }
}

class _AvatarStack extends StatelessWidget {
  final List<MutualAvatarSpec> specs;
  final int overflow;
  final double step;
  final double size;

  const _AvatarStack({
    required this.specs,
    required this.overflow,
    required this.step,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final slots = specs.length + (overflow > 0 ? 1 : 0);
    final width = slots == 0 ? 0.0 : size + (slots - 1) * step;
    return SizedBox(
      width: width,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < specs.length; i++)
            Positioned(
              left: i * step,
              child: _Ring(
                child: DoctorAvatar(
                  initials: specs[i].initials,
                  colorIndex: specs[i].colorIndex,
                  imageUrl: specs[i].imageUrl,
                  size: AvatarSize.sm,
                ),
              ),
            ),
          if (overflow > 0)
            Positioned(
              left: specs.length * step,
              child: _Ring(
                child: Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.gray100,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '+$overflow',
                    style: AppText.badge.copyWith(color: AppColors.gray600),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// White ring behind each overlapping avatar so the stack reads as separated.
class _Ring extends StatelessWidget {
  final Widget child;
  const _Ring({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        shape: BoxShape.circle,
      ),
      padding: const EdgeInsets.all(1.5),
      child: child,
    );
  }
}
