import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Палитра и размеры Qasynda. Чёрный фон, один насыщенный цвет — лайм, остальное — оттенки серого.
class Q {
  static const bg = Color(0xFF0A0A0B);
  static const surface = Color(0xFF151517);
  static const raised = Color(0xFF1F1F23);
  static const line = Color(0xFF2A2A2F);
  static const text = Color(0xFFF4F4F5);
  static const muted = Color(0xFF8C8C96);
  static const faint = Color(0xFF5B5B64);
  static const accent = Color(0xFFC9F24B);
  static const onAccent = Color(0xFF111208);
  static const ok = Color(0xFF52D98A);
  static const danger = Color(0xFFFF6B6B);
  static const blue = Color(0xFF7FB0FF);
  static const radius = 22.0;

  /// Цифры одинаковой ширины: суммы не «прыгают» при обновлении и ровно стоят в столбик.
  static const tabular = [FontFeature.tabularFigures()];
}

const darkOverlay = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Q.bg,
  systemNavigationBarIconBrightness: Brightness.light,
);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Q.accent, brightness: Brightness.dark).copyWith(
    primary: Q.accent,
    onPrimary: Q.onAccent,
    surface: Q.surface,
    onSurface: Q.text,
    onSurfaceVariant: Q.muted,
    outline: Q.line,
    error: Q.danger,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: Q.bg,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Q.bg,
      foregroundColor: Q.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: darkOverlay,
      titleTextStyle: TextStyle(color: Q.text, fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.2),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Q.accent,
        foregroundColor: Q.onAccent,
        disabledBackgroundColor: Q.raised,
        disabledForegroundColor: Q.faint,
        minimumSize: const Size.fromHeight(58),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.1),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: Q.accent)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Q.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      labelStyle: const TextStyle(color: Q.muted),
      floatingLabelStyle: const TextStyle(color: Q.muted),
      // Underline-вариант держит всплывающую подпись внутри поля, а не на его верхней границе.
      border: UnderlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
    ),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: Q.accent),
    dialogTheme: DialogThemeData(
      backgroundColor: Q.raised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Q.radius)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Q.raised,
      contentTextStyle: const TextStyle(color: Q.text, fontSize: 15),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Q.line),
      ),
    ),
  );
}
