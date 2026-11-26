import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import 'message_bubble.dart' show kOnSentInset;

class InviteCodeCard extends StatefulWidget {
  final String code;
  const InviteCodeCard({super.key, required this.code});

  @override
  State<InviteCodeCard> createState() => _InviteCodeCardState();
}

class _InviteCodeCardState extends State<InviteCodeCard> {
  bool _copied = false;
  Timer? _revertTimer;

  @override
  void dispose() {
    _revertTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    _revertTimer?.cancel();
    _revertTimer = Timer(AppMotion.confirmHold, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 14),
      decoration:
          BoxDecoration(color: AppColors.medBlue, borderRadius: AppRadii.rLg),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Strings.orgInviteCodeLabel,
                  style: AppText.label.copyWith(color: AppColors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.code,
                  style: GoogleFonts.sora(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 4,
                    color: AppColors.white,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              // A darker inset: white on it is 6.80:1. The white tint this
              // replaces lightened the teal to 3.77:1.
              backgroundColor: kOnSentInset,
              foregroundColor: AppColors.white,
            ),
            onPressed: _copy,
            // Success feedback: copy icon morphs to a check for a moment,
            // then reverts. Reduced-motion aware via AppMotion.maybe.
            icon: AnimatedSwitcher(
              duration: AppMotion.maybe(context, AppMotion.micro),
              switchInCurve: AppMotion.curveEnter,
              switchOutCurve: AppMotion.curveExit,
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                key: ValueKey<bool>(_copied),
                size: 16,
              ),
            ),
            label: Text(_copied ? 'Copied' : Strings.copy),
          ),
        ],
      ),
    );
  }
}
