import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'colors.dart';

/// Typography tokens from docs/design.md §3.
/// Sora → display/headings. DM Sans → body/UI. Never use Inter or Roboto.
///
/// Getters, not fields (batch 6): each style resolves its colour from the
/// current [AppColors] palette at build time, so a theme swap recolours text.
class AppText {
  AppText._();

  // Sora family
  static TextStyle get display => GoogleFonts.sora(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1.2,
    color: AppColors.textDisplay,
  );

  static TextStyle get heading => GoogleFonts.sora(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.3,
    color: AppColors.textPrimary,
  );

  static TextStyle get navTitle => GoogleFonts.sora(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: AppColors.gray900, // app bars are light chrome; dark title
  );

  static TextStyle get inviteCode => GoogleFonts.sora(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: 4,
    color: AppColors.medBlueDark,
  );

  // DM Sans family
  static TextStyle get subheading => GoogleFonts.dmSans(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.4,
    color: AppColors.textPrimary,
  );

  static TextStyle get body => GoogleFonts.dmSans(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: AppColors.textSecondary,
  );

  static TextStyle get bodyPrimary => GoogleFonts.dmSans(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
    color: AppColors.textPrimary,
  );

  static TextStyle get messageBody => GoogleFonts.dmSans(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: AppColors.textPrimary,
  );

  static TextStyle get caption => GoogleFonts.dmSans(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textMuted,
  );

  static TextStyle get timestamp => GoogleFonts.dmSans(
    fontSize: 10,
    fontWeight: FontWeight.w400,
    color: AppColors.textMuted,
  );

  static TextStyle get label => GoogleFonts.dmSans(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.5,
    color: AppColors.medBlue,
  );

  static TextStyle get button => GoogleFonts.dmSans(
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );

  static TextStyle get badge => GoogleFonts.dmSans(
    fontSize: 11,
    fontWeight: FontWeight.w600,
  );
}
