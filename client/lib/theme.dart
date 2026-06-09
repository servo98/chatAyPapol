import 'package:flutter/material.dart';

/// Paleta propia (oscura, violeta profundo). Sin assets: 0 KB extra.
abstract final class Pal {
  static const bg0 = Color(0xFF0D0E13); // fondo más profundo (barras)
  static const bg1 = Color(0xFF14161E); // sidebar
  static const bg2 = Color(0xFF1A1D27); // chat
  static const bg3 = Color(0xFF232736); // cards / inputs / hover
  static const bg4 = Color(0xFF2C3142); // hover fuerte
  static const accent = Color(0xFF8B7CF7);
  static const accentDim = Color(0xFF6557C9);
  static const text = Color(0xFFE5E7EF);
  static const muted = Color(0xFF9AA0B4);
  static const faint = Color(0xFF6B7186);
  static const green = Color(0xFF4ADE80);
  static const red = Color(0xFFF24A50);
  static const yellow = Color(0xFFFFC857);
  static const link = Color(0xFF6FA8FF);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Pal.accent,
    secondary: Pal.accent,
    surface: Pal.bg2,
    onSurface: Pal.text,
    error: Pal.red,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  return base.copyWith(
    scaffoldBackgroundColor: Pal.bg2,
    canvasColor: Pal.bg1,
    dividerColor: Colors.white.withValues(alpha: .06),
    textTheme: base.textTheme.apply(bodyColor: Pal.text, displayColor: Pal.text),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: Pal.bg0, borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(color: Pal.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Pal.bg0,
      hintStyle: const TextStyle(color: Pal.faint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Pal.accent, width: 1.5),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: Pal.accent,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Pal.muted),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Pal.bg1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Pal.bg0,
      textStyle: const TextStyle(color: Pal.text, fontSize: 13.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: .15)),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Pal.bg0,
      contentTextStyle: TextStyle(color: Pal.text),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
