import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';

/// Bare three-dot bouncing animation. Reused in the chat thread (in a bubble)
/// and inline in the chat list row.
///
/// Each dot rises on a half-sine with a staggered phase and rests between
/// bounces so the rhythm reads as organic typing rather than a metronome.
/// Reduced-motion aware (static dots when animations are disabled).
class TypingDots extends StatefulWidget {
  /// null = the muted text colour of the current theme.
  final Color? color;
  final double size;
  const TypingDots({super.key, this.color, this.size = 7});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _dot(double lift) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.size * 0.35),
      child: Transform.translate(
        offset: Offset(0, -(widget.size * 0.62) * lift),
        child: Opacity(
          opacity: 0.45 + 0.55 * lift,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration:
                BoxDecoration(color: widget.color ?? AppColors.gray400, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (_) => _dot(0)),
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          // Staggered phase per dot; each dot is active for the first 55%
          // of its cycle (half-sine bounce), then rests — the pause between
          // waves is what makes it feel typed, not mechanical.
          final phase = (_c.value + i * 0.16) % 1.0;
          final active = (phase / 0.55).clamp(0.0, 1.0);
          final lift = math.sin(active * math.pi);
          return _dot(lift);
        }),
      ),
    );
  }
}

/// WhatsApp-style three-dot "typing…" bubble shown in the chat thread.
class TypingIndicator extends StatelessWidget {
  const TypingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(
            left: AppSpacing.lg, top: 2, bottom: AppSpacing.xs + 2),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md + 2, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: AppRadii.rLg,
          border: Border.all(color: AppColors.gray100),
        ),
        child: const TypingDots(),
      ),
    );
  }
}
