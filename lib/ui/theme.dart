import 'package:flutter/material.dart';

class RunTheme {
  RunTheme._();
  static const Color background = Color(0xFF0E1116);
  static const Color surface = Color(0xFF171B22);
  static const Color surfaceHigh = Color(0xFF212733);
  static const Color running = Color(0xFF22C55E);
  static const Color paused = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFEF4444);
  static const Color textPrimary = Color(0xFFF3F5F7);
  static const Color textSecondary = Color(0xFF9AA4B2);
  static const Color route = Color(0xFF38BDF8);

  static ThemeData build() {
    const scheme = ColorScheme.dark(
      primary: running,
      secondary: route,
      surface: surface,
      error: danger,
      onPrimary: Color(0xFF06240F),
      onSurface: textPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: const CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surfaceHigh,
        contentTextStyle: TextStyle(color: textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: const DialogThemeData(backgroundColor: surface),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          textStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          foregroundColor: textPrimary,
          side: const BorderSide(color: surfaceHigh, width: 1.5),
          textStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }

  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];
}
