import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Токены «Радиуса»: белый фон, тёплые серые поверхности и один бирюзовый акцент. Сетка 4 pt.
class Q {
  static const bg = Color(0xFFFFFFFF);
  static const surface = Color(0xFFF3F4F2);
  static const surface2 = Color(0xFFE9EBE8);
  static const line = Color(0xFFE3E6E2);
  static const ink = Color(0xFF17191A);
  static const ink2 = Color(0xFF5B6260);
  static const ink3 = Color(0xFF8A918F);
  static const accent = Color(0xFF0F7B6C);
  static const accentPress = Color(0xFF0B6659);
  static const accentInk = Color(0xFF0A5E53);
  static const accentSoft = Color(0xFFE4F2EF);
  static const card = Color(0xFF0C3F38);
  static const amberInk = Color(0xFF8A5300);
  static const amberSoft = Color(0xFFFBF0DC);
  static const danger = Color(0xFFC2362B);
  static const dangerSoft = Color(0xFFFBEAE8);
  static const onAccent = Color(0xFFFFFFFF);

  static const font = 'Onest';

  /// Поле экрана слева и справа.
  static const gutter = 20.0;

  /// Цифры одинаковой ширины: суммы не «прыгают» при обновлении и ровно стоят в столбик.
  static const tabular = [FontFeature.tabularFigures()];

  static const balance = TextStyle(fontSize: 40, height: 48 / 40, fontWeight: FontWeight.w700, letterSpacing: -0.8, fontFeatures: tabular);
  static const amountInput = TextStyle(fontSize: 50, height: 60 / 50, fontWeight: FontWeight.w700, letterSpacing: -1.0, fontFeatures: tabular);
  static const title = TextStyle(fontSize: 28, height: 36 / 28, fontWeight: FontWeight.w700, letterSpacing: -0.4);
  static const titleM = TextStyle(fontSize: 24, height: 32 / 24, fontWeight: FontWeight.w700, letterSpacing: -0.36);
  static const section = TextStyle(fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w700);
  static const appBar = TextStyle(fontSize: 17, height: 24 / 17, fontWeight: FontWeight.w600);
  static const body = TextStyle(fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w400, color: ink2);
  static const rowTitle = TextStyle(fontSize: 16, height: 20 / 16, fontWeight: FontWeight.w600);
  static const label = TextStyle(fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w600);
  static const secondary = TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400, color: ink2);
  static const tag = TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w600);
}

const lightOverlay = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Q.bg,
  systemNavigationBarIconBrightness: Brightness.dark,
);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Q.accent).copyWith(
    primary: Q.accent,
    onPrimary: Q.onAccent,
    surface: Q.bg,
    onSurface: Q.ink,
    onSurfaceVariant: Q.ink2,
    surfaceContainerHighest: Q.surface,
    outline: Q.line,
    outlineVariant: Q.line,
    error: Q.danger,
  );
  const buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16)));
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    fontFamily: Q.font,
    scaffoldBackgroundColor: Q.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Q.surface,
    textTheme: const TextTheme().apply(bodyColor: Q.ink, displayColor: Q.ink, fontFamily: Q.font),
    iconTheme: const IconThemeData(color: Q.ink, size: 24),
    appBarTheme: const AppBarTheme(
      backgroundColor: Q.bg,
      foregroundColor: Q.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 56,
      systemOverlayStyle: lightOverlay,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(56)),
        shape: const WidgetStatePropertyAll(buttonShape),
        elevation: const WidgetStatePropertyAll(0),
        textStyle: const WidgetStatePropertyAll(
            TextStyle(fontFamily: Q.font, fontSize: 17, height: 24 / 17, fontWeight: FontWeight.w600)),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return Q.surface2;
          if (states.contains(WidgetState.pressed)) return Q.accentPress;
          return Q.accent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled) ? Q.ink3 : Q.onAccent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Q.accentInk,
        textStyle: const TextStyle(fontFamily: Q.font, fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w600),
        shape: buttonShape,
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: Q.accent,
      selectionColor: Q.accent.withValues(alpha: 0.2),
      selectionHandleColor: Q.accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Q.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Q.accent, width: 2),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Q.bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: Q.appBar.copyWith(color: Q.ink, fontFamily: Q.font),
      contentTextStyle: Q.body.copyWith(color: Q.ink, fontFamily: Q.font),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Q.ink,
      actionTextColor: Q.accentSoft,
      contentTextStyle: const TextStyle(fontFamily: Q.font, color: Q.onAccent, fontSize: 15, height: 20 / 15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: Q.accent),
    // На iOS остаётся системный переход со свайпом назад, на остальных — горизонтальный сдвиг.
    pageTransitionsTheme: switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => const PageTransitionsTheme(),
      _ => const PageTransitionsTheme(builders: {
          TargetPlatform.android: _SlideTransitions(),
          TargetPlatform.windows: _SlideTransitions(),
          TargetPlatform.linux: _SlideTransitions(),
          TargetPlatform.fuchsia: _SlideTransitions(),
        }),
    },
  );
}

/// Переход между экранами: горизонтальный сдвиг, без масштаба и затемнения.
class _SlideTransitions extends PageTransitionsBuilder {
  const _SlideTransitions();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (MediaQuery.disableAnimationsOf(context)) return FadeTransition(opacity: animation, child: child);
    final enter = Tween(begin: const Offset(1, 0), end: Offset.zero)
        .chain(CurveTween(curve: Curves.easeOutCubic))
        .animate(animation);
    final leave = Tween(begin: Offset.zero, end: const Offset(-0.25, 0))
        .chain(CurveTween(curve: Curves.easeOutCubic))
        .animate(secondaryAnimation);
    return SlideTransition(position: leave, child: SlideTransition(position: enter, child: child));
  }
}
