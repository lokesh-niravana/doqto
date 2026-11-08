import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens/colors.dart';
import 'tokens/radii.dart';
import 'tokens/spacing.dart';
import 'tokens/typography.dart';

/// Composes tokens into ThemeData. Light and dark since batch 6: both are
/// built from a [DoqtoPalette]; the caller (the root widget) swaps
/// [AppColors] to the same palette first so static token reads agree with
/// the ThemeData in the tree. See colors.dart for the approach.
class AppTheme {
  AppTheme._();

  static ThemeData light() => fromPalette(DoqtoPalette.light);

  static ThemeData dark() => fromPalette(DoqtoPalette.dark);

  /// The theme that goes with [mode] under the platform [brightness].
  static ThemeData resolve(ThemeMode mode, Brightness platformBrightness) {
    final dark = switch (mode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformBrightness == Brightness.dark,
    };
    return dark ? AppTheme.dark() : AppTheme.light();
  }

  static ThemeData fromPalette(DoqtoPalette p) {
    final previous = AppColors.current;
    // Token getters must read [p] while this ThemeData is composed.
    AppColors.setPalette(p);
    try {
      return _compose(p);
    } finally {
      // The root widget sets the palette it wants; building a ThemeData for
      // the other brightness (tests, previews) must not leak it.
      AppColors.setPalette(previous);
    }
  }

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
      listTileTheme: ListTileThemeData(
        textColor: AppColors.textPrimary,
        iconColor: AppColors.textSecondary,
      ),
      textTheme: GoogleFonts.dmSansTextTheme(
        p.isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
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
        systemOverlayStyle:
            p.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
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
