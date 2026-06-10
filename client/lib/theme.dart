import 'package:flutter/material.dart';

/// Paleta aypapol — terminal/CLI: verde-negro profundo + verde neón "papol".
/// Tokens calcados de project/tokens/colors.css del design system.
/// Sin assets de color: 0 KB extra.
abstract final class Pal {
  // Fondos: casi-negro con tinte verde, suben en pasos cortos.
  static const bg0 = Color(0xFF06080A); // --void: barras, pozos, popups
  static const bg1 = Color(0xFF0C1110); // --ink-850: sidebar / members
  static const bg2 = Color(0xFF0A0D0C); // --ink-900: chat / página
  static const bg3 = Color(0xFF0F1413); // --ink-800: card / input / hover
  static const bg4 = Color(0xFF131918); // --ink-750: raised / seleccionado
  static const inset = Color(0xFF070A09); // --ink-inset: inputs, terminales

  // Verde papol — EL acento.
  static const accent = Color(0xFF39FF14); // --green-neon
  static const accentDim = Color(0xFF2CE60F); // --green-500: rellenos / texto
  static const greenInk = Color(0xFF04140A); // texto/icono SOBRE verde
  static const green = Color(0xFF39FF14); // presencia en línea / conectado

  // Texto: off-whites con tinte verde → gris de comentario CLI.
  static const text = Color(0xFFE9F5EC); // --fg-bright: titulares
  static const muted = Color(0xFF97A89E); // --fg-2: secundario / labels
  static const faint = Color(0xFF66786E); // --fg-3: metadata / dim
  static const comment = Color(0xFF4D5F56); // --fg-comment: placeholders

  // Bordes hairline (grises con tinte verde). El borde ES el contenedor.
  static const borderSubtle = Color(0xFF161D1A); // --line-900
  static const borderDefault = Color(0xFF1F2824); // --line-800
  static const borderStrong = Color(0xFF2A352F); // --line-700

  // Secundarios, con moderación.
  static const link = Color(0xFF22D3EE); // --cyan: links / info
  static const magenta = Color(0xFFFF2E9A); // proyecto Música / énfasis raro
  static const yellow = Color(0xFFFFB627); // --amber: avisos
  static const red = Color(0xFFFF4D4D); // --red: error / offline

  /// JetBrains Mono si está instalada en el sistema; si no, cae al mono nativo
  /// (Consolas en Windows, DejaVu en Linux, Menlo en macOS). El sistema entero
  /// se inclina al mono — ver readme §3.
  static const fontMono = 'JetBrains Mono';
  static const monoFallback = <String>[
    'JetBrainsMono Nerd Font',
    'Cascadia Code',
    'Consolas',
    'DejaVu Sans Mono',
    'Menlo',
    'monospace',
  ];

  // Glow neón — el estado de interacción firma (focus / hover).
  static List<BoxShadow> glowGreen = const [
    BoxShadow(color: Color(0x8C39FF14), blurRadius: 0, spreadRadius: 1),
    BoxShadow(color: Color(0x7339FF14), blurRadius: 18, spreadRadius: -2),
  ];
  static List<BoxShadow> glowGreenSm = const [
    BoxShadow(color: Color(0x8C39FF14), blurRadius: 12, spreadRadius: -2),
  ];
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Pal.accent,
    secondary: Pal.accent,
    surface: Pal.bg2,
    onSurface: Pal.text,
    error: Pal.red,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: Pal.fontMono,
    fontFamilyFallback: Pal.monoFallback,
  );
  return base.copyWith(
    scaffoldBackgroundColor: Pal.bg2,
    canvasColor: Pal.bg1,
    dividerColor: Pal.borderSubtle,
    textTheme: base.textTheme.apply(bodyColor: Pal.text, displayColor: Pal.text),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: Pal.bg0,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Pal.borderDefault),
      ),
      textStyle: const TextStyle(color: Pal.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Pal.inset,
      hintStyle: const TextStyle(color: Pal.comment),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: const BorderSide(color: Pal.borderDefault),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: const BorderSide(color: Pal.borderDefault),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: const BorderSide(color: Pal.accent, width: 1.5),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: Pal.accentDim,
        foregroundColor: Pal.greenInk,
        elevation: 0,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Pal.muted),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Pal.bg1,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Pal.borderDefault),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Pal.bg0,
      surfaceTintColor: Colors.transparent,
      textStyle: const TextStyle(color: Pal.text, fontSize: 13.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Pal.borderDefault),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: const WidgetStatePropertyAll(Pal.borderStrong),
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(999),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Pal.bg0,
      contentTextStyle: TextStyle(color: Pal.text),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
