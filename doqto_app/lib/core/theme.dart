import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens/colors.dart';
import 'tokens/radii.dart';
import 'tokens/spacing.dart';
import 'tokens/typography.dart';

/// Composes tokens into ThemeData. Light only: Doqto has one palette
/// ([DoqtoPalette.light]; docs/design.md says "No dark mode").
class AppTheme {
  AppTheme._();

  static ThemeData light() => _compose(DoqtoPalette.light);

  static ThemeData _compose(DoqtoPalette p) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.medBlue,
      primary: AppColors.medBlue,
      onPrimary: AppColors.onPrimary,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      brightness: p.brightness,
      error: AppColors.red,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: scheme,
      extensions: [DoqtoColors(p)],
      scaffoldBackgroundColor: AppColors.appBg,
      canvasColor: AppColors.surface,
      dialogTheme: DialogThemeData(backgroundColor: AppColors.surface),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
      ),
      // White on every snackbar fill the app uses: 5.03:1 on brand teal,
      // 5.30:1 on red, 13.4:1 on the default dark surface. The M3 default
      // content colour is 4.44:1 on teal, and its default action colour (a
      // pale teal) is unreadable there.
      // Floating: the Scaffold lifts it clear of the shell's raised mic
      // button (fixed, it sat on the tab bar's top edge, half under the
      // button). The fill is unchanged, so the contrast figures above hold.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        contentTextStyle: AppText.bodyPrimary.copyWith(color: AppColors.white),
        actionTextColor: AppColors.white,
      ),
      listTileTheme: ListTileThemeData(
        textColor: AppColors.textPrimary,
        iconColor: AppColors.textSecondary,
      ),
      textTheme: GoogleFonts.dmSansTextTheme(
        ThemeData.light().textTheme,
      ).apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textDisplay,
      ),
      // Chrome blends with the scaffold — no solid color slab under the notch.
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.appBg,
        foregroundColor: AppColors.textDisplay,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppText.navTitle,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.gray50,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md + 2,
          vertical: AppSpacing.md - 1,
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadii.rMd,
          borderSide: BorderSide(color: AppColors.gray200, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadii.rMd,
          borderSide: BorderSide(color: AppColors.gray200, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadii.rMd,
          borderSide: const BorderSide(color: AppColors.medBlue, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadii.rMd,
          borderSide: const BorderSide(color: AppColors.red, width: 1.5),
        ),
        hintStyle: AppText.body.copyWith(color: AppColors.textMuted),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.medBlue,
          foregroundColor: AppColors.white,
          textStyle: AppText.button,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: AppRadii.rFull),
          minimumSize: const Size(0, 44),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.medBlue,
          textStyle: AppText.button,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: AppRadii.rFull),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: AppColors.gray100,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: AppRadii.rLg),
      ),
    );
  }
}
