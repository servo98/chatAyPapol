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

  // Movimiento (readme §3): sobrio, easing con salida rápida.
  static const ease = Cubic(0.2, 0.8, 0.2, 1.0);
  static const durFast = Duration(milliseconds: 120);
  static const dur = Duration(milliseconds: 180);
  static const durSlow = Duration(milliseconds: 320);

  // Textura de fondo: rejilla verde muy tenue a 28px (readme §10 — bg-grid).
  static const gridLine = Color(0x0B39FF14); // rgba(57,255,20,0.043)
  static const gridSize = 28.0;
}

/// Rejilla verde tenue del "papol-canvas": líneas a [Pal.gridSize] px sobre
/// el fondo. Estática (sin animación) — coherente con readme §10.
class PapolGridPainter extends CustomPainter {
  const PapolGridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Pal.gridLine
      ..strokeWidth = 1;
    for (double x = 0; x <= size.width; x += Pal.gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y <= size.height; y += Pal.gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Envuelve un input (o cualquier subárbol enfocable) y enciende el glow neón
/// cuando él o un descendiente tiene foco. Material no soporta box-shadow en
/// los inputs nativos, así que el halo se aplica aquí (readme §3 — focus).
class GlowOnFocus extends StatefulWidget {
  final Widget child;
  final double radius;
  const GlowOnFocus({super.key, required this.child, this.radius = 5});
  @override
  State<GlowOnFocus> createState() => _GlowOnFocusState();
}

class _GlowOnFocusState extends State<GlowOnFocus> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: Pal.dur,
        curve: Pal.ease,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          boxShadow: _focused ? Pal.glowGreenSm : null,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Envuelve [child] con el fondo de página + la rejilla papol detrás.
class PapolCanvas extends StatelessWidget {
  final Widget child;
  final Color? color;
  const PapolCanvas({super.key, required this.child, this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: color ?? Pal.bg2,
      child: CustomPaint(
        painter: const PapolGridPainter(),
        child: child,
      ),
    );
  }
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
        borderSide: const BorderSide(color: Pal.accent),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: Pal.accentDim,
        foregroundColor: Pal.greenInk,
        elevation: 0,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ).copyWith(
        // glow neón en hover: sombra verde que florece (readme §3 — hover).
        shadowColor: const WidgetStatePropertyAll(Pal.accent),
        animationDuration: Pal.dur,
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.hovered) ? Pal.accent : Pal.accentDim),
        elevation: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.pressed)
                ? 2.0
                : s.contains(WidgetState.hovered)
                    ? 10.0
                    : 0.0),
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
      textStyle: const TextStyle(color: Pal.text, fontSize: 13),
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
