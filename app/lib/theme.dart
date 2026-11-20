import 'package:material_ui/material_ui.dart';

/// Палитра и размеры Qasynda.
class Q {
  static const bg = Color(0xFFF3F4F6);
  static const surface = Colors.white;
  static const ink = Color(0xFF17181C);
  static const muted = Color(0xFF8B8E98);
  static const line = Color(0xFFE6E7EB);
  static const accent = Color(0xFFC9F24B);
  static const ok = Color(0xFF1FA463);
  static const danger = Color(0xFFE5484D);
  static const blue = Color(0xFF3B6CF6);
  static const radius = 24.0;
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Q.accent).copyWith(
    primary: Q.ink,
    onPrimary: Colors.white,
    surface: Q.surface,
    onSurface: Q.ink,
    error: Q.danger,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Q.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: Q.bg,
      foregroundColor: Q.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: Q.ink, fontSize: 22, fontWeight: FontWeight.w800),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Q.accent,
        foregroundColor: Q.ink,
        disabledBackgroundColor: Q.line,
        disabledForegroundColor: Q.muted,
        minimumSize: const Size.fromHeight(58),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Q.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      labelStyle: const TextStyle(color: Q.muted),
      // Underline-вариант держит всплывающую подпись внутри поля, а не на его верхней границе.
      border: UnderlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Q.ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}
