import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'app_pressable.dart';

/// Identity provider buttons for the login screen.
///
/// Full-width, white, bordered — deliberately quieter than [AppButton]'s
/// primary teal so the app's own sign-in stays the main action.
class SocialButton extends StatelessWidget {
  final String label;
  final Widget mark;
  final VoidCallback? onPressed;

  const SocialButton({
    super.key,
    required this.label,
    required this.mark,
    required this.onPressed,
  });

  /// Google: `Continue with Google` + the four-colour G.
  factory SocialButton.google({
    required String label,
    required VoidCallback? onPressed,
  }) =>
      SocialButton(
        label: label,
        mark: const _GoogleMark(),
        onPressed: onPressed,
      );

  /// Facebook: `Continue with Facebook` + the white f on brand blue.
  factory SocialButton.facebook({
    required String label,
    required VoidCallback? onPressed,
  }) =>
      SocialButton(
        label: label,
        mark: const _FacebookMark(),
        onPressed: onPressed,
      );

  /// Apple: required by App Store guideline 4.8 wherever a third-party social
  /// login is offered.
  factory SocialButton.apple({
    required String label,
    required VoidCallback? onPressed,
  }) =>
      SocialButton(
        label: label,
        mark: const _AppleMark(),
        onPressed: onPressed,
      );

  @override
  Widget build(BuildContext context) {
    return AppPressable(
      onTap: onPressed,
      enabled: onPressed != null,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadii.rMd,
          border: Border.all(color: AppColors.border, width: 1.5),
        ),
        child: Row(
          children: [
            SizedBox(width: 20, height: 20, child: mark),
            // The mark sits left; the label stays optically centred because
            // the same width is reserved on the right.
            Expanded(
              child: Center(
                child: Text(
                  label,
                  style: AppText.button.copyWith(color: AppColors.textPrimary),
                ),
              ),
            ),
            const SizedBox(width: 20),
          ],
        ),
      ),
    );
  }
}

// ponytail: both marks are drawn rather than shipped as assets — no new
// dependency, no image files. Swap in each provider's official artwork before
// the OAuth flows go live; their brand guidelines require it.

class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(painter: _GoogleGPainter());
}

class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();

  static const _blue = Color(0xFF4285F4);
  static const _red = Color(0xFFEA4335);
  static const _yellow = Color(0xFFFBBC05);
  static const _green = Color(0xFF34A853);

  static double _rad(double degrees) => degrees * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.22;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.width - stroke) / 2,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;

    // Angles run clockwise from east. The gap on the right is where the
    // crossbar leaves the ring.
    void arc(Color color, double startDeg, double sweepDeg) {
      canvas.drawArc(rect, _rad(startDeg), _rad(sweepDeg), false,
          paint..color = color);
    }

    arc(_green, 10, 120); // bottom right → bottom left
    arc(_yellow, 130, 70); // left
    arc(_red, 200, 100); // top left → top
    arc(_blue, 300, 52); // top right → down to the bar

    // Crossbar: a blue tongue from the middle out to the right edge.
    canvas.drawRect(
      Rect.fromLTRB(
        size.width * 0.5,
        size.height / 2 - stroke / 2,
        size.width,
        size.height / 2 + stroke / 2,
      ),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant _GoogleGPainter oldDelegate) => false;
}

class _FacebookMark extends StatelessWidget {
  const _FacebookMark();

  static const _blue = Color(0xFF1877F2);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: _blue, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        'f',
        style: AppText.button.copyWith(
          color: AppColors.white,
          fontSize: 15,
          fontWeight: FontWeight.w800,
          height: 1.1,
        ),
      ),
    );
  }
}


/// The Apple logo, drawn rather than shipped as an asset so it inherits the
/// text colour and needs no licence-bearing image file.
class _AppleMark extends StatelessWidget {
  const _AppleMark();

  @override
  Widget build(BuildContext context) => Icon(
        Icons.apple,
        size: 22,
        color: AppColors.textPrimary,
      );
}
