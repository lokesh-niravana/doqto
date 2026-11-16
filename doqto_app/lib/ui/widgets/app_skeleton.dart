import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';

/// Shimmering skeleton placeholder for loading states. Pure Flutter — an
/// AnimationController drives a sweeping gradient (gray100 base, gray50
/// highlight, 1200ms loop). Reduced-motion aware (static block, no shimmer).
///
/// Shapes:
/// - `AppSkeleton.line(width: 120)` — a 12px-tall text line.
/// - `AppSkeleton.circle(size: 44)` — an avatar circle.
/// - `AppSkeleton.block(height: 80)` — a rounded rectangle.
class AppSkeleton extends StatefulWidget {
  final double? width;
  final double height;
  final BorderRadius borderRadius;
  final BoxShape shape;

  const AppSkeleton._({
    this.width,
    required this.height,
    this.borderRadius = BorderRadius.zero,
    this.shape = BoxShape.rectangle,
  });

  factory AppSkeleton.line({double? width, double height = 12}) =>
      AppSkeleton._(width: width, height: height, borderRadius: AppRadii.rXs);

  factory AppSkeleton.circle({double size = 44}) =>
      AppSkeleton._(width: size, height: size, shape: BoxShape.circle);

  factory AppSkeleton.block({double? width, double height = 80}) =>
      AppSkeleton._(width: width, height: height, borderRadius: AppRadii.rMd);

  @override
  State<AppSkeleton> createState() => _AppSkeletonState();
}

class _AppSkeletonState extends State<AppSkeleton>
    with SingleTickerProviderStateMixin {
  static const Duration _loop = Duration(milliseconds: 1200);

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: _loop);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            shape: widget.shape,
            borderRadius:
                widget.shape == BoxShape.circle ? null : widget.borderRadius,
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                AppColors.gray100,
                AppColors.gray50,
                AppColors.gray100,
              ],
              stops: const [0.25, 0.5, 0.75],
              transform: _SlideGradientTransform(t),
            ),
          ),
        );
      },
    );
  }
}

/// Slides the gradient horizontally across the box as t goes 0→1.
class _SlideGradientTransform extends GradientTransform {
  final double t;
  const _SlideGradientTransform(this.t);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 2 - 1), 0, 0);
}

/// Chat-list-shaped loading placeholder: N rows of avatar circle + two lines.
class SkeletonList extends StatelessWidget {
  final int rows;

  const SkeletonList({super.key, this.rows = 6});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenHorizontal,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            AppSkeleton.circle(size: 44),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSkeleton.line(width: 140),
                  const SizedBox(height: AppSpacing.sm),
                  AppSkeleton.line(width: 220),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
