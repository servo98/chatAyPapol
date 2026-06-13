import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Una paleta concreta (resuelta en runtime): combina un juego de SUPERFICIES
/// (oscuro o claro) con un ACENTO. El usuario elige acento + modo claro/oscuro
/// en Ajustes → Apariencia; ver [ThemeController]. Tokens calcados de
/// project/tokens/colors.css del design system.
class Palette {
  final bool isLight;
  // Fondos: en pasos cortos. bg0=más profundo (barras/popups), bg2=página.
  final Color bg0, bg1, bg2, bg3, bg4, inset;
  // Acento (EL color de marca) + variantes.
  final Color accent, accentDim, greenInk, green;
  // Texto.
  final Color text, muted, faint, comment;
  // Bordes hairline.
  final Color borderSubtle, borderDefault, borderStrong;
  // Secundarios.
  final Color link, magenta, yellow, red;
  // Rejilla de fondo (tinte del acento, muy tenue).
  final Color gridLine;
  const Palette({
    required this.isLight,
    required this.bg0,
    required this.bg1,
    required this.bg2,
    required this.bg3,
    required this.bg4,
    required this.inset,
    required this.accent,
    required this.accentDim,
    required this.greenInk,
    required this.green,
    required this.text,
    required this.muted,
    required this.faint,
    required this.comment,
    required this.borderSubtle,
    required this.borderDefault,
    required this.borderStrong,
    required this.link,
    required this.magenta,
    required this.yellow,
    required this.red,
    required this.gridLine,
  });
}

/// Un acento seleccionable: triples (acento, acento atenuado, color SOBRE el
/// acento) para modo oscuro y para modo claro (los neón puros son ilegibles
/// sobre blanco, así que el modo claro usa una variante más oscura).
class AccentDef {
  final String id, name;
  final Color dAccent, dDim, dOn; // oscuro
  final Color lAccent, lDim, lOn; // claro
  const AccentDef(this.id, this.name, this.dAccent, this.dDim, this.dOn,
      this.lAccent, this.lDim, this.lOn);
}

/// Catálogo de acentos (basado en colors.css del design system).
const kAccents = <AccentDef>[
  AccentDef('green', 'Papol', // verde neón — el original
      Color(0xFF39FF14), Color(0xFF2CE60F), Color(0xFF04140A),
      Color(0xFF15A012), Color(0xFF0C7A0A), Color(0xFFFFFFFF)),
  AccentDef('cyan', 'Cyan', //
      Color(0xFF22D3EE), Color(0xFF0FA9C4), Color(0xFF03171B),
      Color(0xFF0E8AA3), Color(0xFF0A6377), Color(0xFFFFFFFF)),
  AccentDef('amber', 'Ámbar', //
      Color(0xFFFFB627), Color(0xFFC98708), Color(0xFF1A1200),
      Color(0xFFB07400), Color(0xFF8A5B00), Color(0xFFFFFFFF)),
  AccentDef('magenta', 'Magenta', //
      Color(0xFFFF2E9A), Color(0xFFC41673), Color(0xFF1A0410),
      Color(0xFFC41673), Color(0xFF9C1059), Color(0xFFFFFFFF)),
  AccentDef('violet', 'Violeta', // p-chat #7c8cff
      Color(0xFF7C8CFF), Color(0xFF5566E0), Color(0xFF080B26),
      Color(0xFF4F5FD6), Color(0xFF3A48B0), Color(0xFFFFFFFF)),
];

/// Construye la paleta efectiva a partir de un acento + modo.
Palette buildPalette(String accentId, bool light) {
  final a = kAccents.firstWhere((x) => x.id == accentId,
      orElse: () => kAccents.first);
  final accent = light ? a.lAccent : a.dAccent;
  final accentDim = light ? a.lDim : a.dDim;
  final onAccent = light ? a.lOn : a.dOn;
  if (light) {
    return Palette(
      isLight: true,
      bg0: const Color(0xFFFFFFFF),
      bg1: const Color(0xFFECEFEA),
      bg2: const Color(0xFFF5F7F4),
      bg3: const Color(0xFFE6EAE4),
      bg4: const Color(0xFFDBE0D8),
      inset: const Color(0xFFFFFFFF),
      accent: accent,
      accentDim: accentDim,
      greenInk: onAccent,
      green: const Color(0xFF15A012),
      text: const Color(0xFF0A0D0C),
      muted: const Color(0xFF42514A),
      faint: const Color(0xFF66786E),
      comment: const Color(0xFF8A9A90),
      borderSubtle: const Color(0xFFE3E7E1),
      borderDefault: const Color(0xFFD2D8D0),
      borderStrong: const Color(0xFFB9C1B6),
      link: const Color(0xFF0FA9C4),
      magenta: const Color(0xFFC41673),
      yellow: const Color(0xFFC98708),
      red: const Color(0xFFD23030),
      gridLine: const Color(0x0A000000),
    );
  }
  return Palette(
    isLight: false,
    bg0: const Color(0xFF06080A),
    bg1: const Color(0xFF0C1110),
    bg2: const Color(0xFF0A0D0C),
    bg3: const Color(0xFF0F1413),
    bg4: const Color(0xFF131918),
    inset: const Color(0xFF070A09),
    accent: accent,
    accentDim: accentDim,
    greenInk: onAccent,
    green: const Color(0xFF39FF14),
    text: const Color(0xFFE9F5EC),
    muted: const Color(0xFF97A89E),
    faint: const Color(0xFF66786E),
    comment: const Color(0xFF4D5F56),
    borderSubtle: const Color(0xFF161D1A),
    borderDefault: const Color(0xFF1F2824),
    borderStrong: const Color(0xFF2A352F),
    link: const Color(0xFF22D3EE),
    magenta: const Color(0xFFFF2E9A),
    yellow: const Color(0xFFFFB627),
    red: const Color(0xFFFF4D4D),
    gridLine: accent.withValues(alpha: 0.043),
  );
}

/// Estado global del tema: acento + modo claro/oscuro, persistido en local
/// (SharedPreferences, igual que mic/EQ en voice.dart). Notifica para repintar
/// en vivo — main.dart envuelve el MaterialApp en un ListenableBuilder de este.
class ThemeController extends ChangeNotifier {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _kAccent = 'theme_accent';
  static const _kLight = 'theme_light';

  String _accentId = 'green';
  bool _light = false;
  Palette _palette = buildPalette('green', false);

  Palette get palette => _palette;
  String get accentId => _accentId;
  bool get light => _light;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _accentId = prefs.getString(_kAccent) ?? 'green';
      _light = prefs.getBool(_kLight) ?? false;
      _palette = buildPalette(_accentId, _light);
    } catch (_) {/* sin prefs: queda el default papol oscuro */}
  }

  Future<void> setAccent(String id) async {
    if (_accentId == id) return;
    _accentId = id;
    _apply();
  }

  Future<void> setLight(bool v) async {
    if (_light == v) return;
    _light = v;
    _apply();
  }

  void _apply() {
    _palette = buildPalette(_accentId, _light);
    notifyListeners();
    () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kAccent, _accentId);
        await prefs.setBool(_kLight, _light);
      } catch (_) {}
    }();
  }
}

/// Fachada de tokens. Los colores son GETTERS que leen la paleta activa de
/// [ThemeController] → cambian en vivo al cambiar de tema. Lo no-cromático
/// (fuentes, duraciones, rejilla) sigue siendo `const`.
abstract final class Pal {
  static Palette get _p => ThemeController.instance.palette;
  static bool get isLight => _p.isLight;

  static Color get bg0 => _p.bg0;
  static Color get bg1 => _p.bg1;
  static Color get bg2 => _p.bg2;
  static Color get bg3 => _p.bg3;
  static Color get bg4 => _p.bg4;
  static Color get inset => _p.inset;

  static Color get accent => _p.accent;
  static Color get accentDim => _p.accentDim;
  static Color get greenInk => _p.greenInk;
  static Color get green => _p.green;

  static Color get text => _p.text;
  static Color get muted => _p.muted;
  static Color get faint => _p.faint;
  static Color get comment => _p.comment;

  static Color get borderSubtle => _p.borderSubtle;
  static Color get borderDefault => _p.borderDefault;
  static Color get borderStrong => _p.borderStrong;

  static Color get link => _p.link;
  static Color get magenta => _p.magenta;
  static Color get yellow => _p.yellow;
  static Color get red => _p.red;

  /// JetBrains Mono si está instalada; si no, cae al mono nativo. Ver readme §3.
  static const fontMono = 'JetBrains Mono';
  static const monoFallback = <String>[
    'JetBrainsMono Nerd Font',
    'Cascadia Code',
    'Consolas',
    'DejaVu Sans Mono',
    'Menlo',
    'monospace',
  ];

  // Glow del acento — el estado de interacción firma (focus / hover). Deriva del
  // acento activo (antes era verde fijo).
  static List<BoxShadow> get glowGreen => [
        BoxShadow(
            color: _p.accent.withValues(alpha: .55),
            blurRadius: 0,
            spreadRadius: 1),
        BoxShadow(
            color: _p.accent.withValues(alpha: .45),
            blurRadius: 18,
            spreadRadius: -2),
      ];
  static List<BoxShadow> get glowGreenSm => [
        BoxShadow(
            color: _p.accent.withValues(alpha: .55),
            blurRadius: 12,
            spreadRadius: -2),
      ];

  // Movimiento (readme §3): sobrio, easing con salida rápida.
  static const ease = Cubic(0.2, 0.8, 0.2, 1.0);
  static const durFast = Duration(milliseconds: 120);
  static const dur = Duration(milliseconds: 180);
  static const durSlow = Duration(milliseconds: 320);

  // Textura de fondo: rejilla muy tenue a 28px (readme §10 — bg-grid).
  static Color get gridLine => _p.gridLine;
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

ThemeData buildTheme(Palette p) {
  final scheme = p.isLight
      ? ColorScheme.light(
          primary: p.accent,
          secondary: p.accent,
          surface: p.bg2,
          onSurface: p.text,
          error: p.red,
        )
      : ColorScheme.dark(
          primary: p.accent,
          secondary: p.accent,
          surface: p.bg2,
          onSurface: p.text,
          error: p.red,
        );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: Pal.fontMono,
    fontFamilyFallback: Pal.monoFallback,
  );
  return base.copyWith(
    scaffoldBackgroundColor: p.bg2,
    canvasColor: p.bg1,
    dividerColor: p.borderSubtle,
    textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.bg0,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: p.borderDefault),
      ),
      textStyle: TextStyle(color: p.text, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.inset,
      hintStyle: TextStyle(color: p.comment),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: p.borderDefault),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: p.borderDefault),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: p.accent),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.accentDim,
        foregroundColor: p.greenInk,
        elevation: 0,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ).copyWith(
        // glow del acento en hover: sombra que florece (readme §3 — hover).
        shadowColor: WidgetStatePropertyAll(p.accent),
        animationDuration: Pal.dur,
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.hovered) ? p.accent : p.accentDim),
        elevation: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.pressed)
                ? 2.0
                : s.contains(WidgetState.hovered)
                    ? 10.0
                    : 0.0),
      ),
    ),
    // Botón SECUNDARIO (acciones tipo "Cambiar avatar"): coherente con el
    // primario pero en versión outline — mono, borde que se vuelve acento y
    // florece con glow en hover (readme §3). Antes caían al default genérico.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.accentDim,
        textStyle: const TextStyle(
            fontFamily: Pal.fontMono,
            fontFamilyFallback: Pal.monoFallback,
            fontSize: 12.5,
            fontWeight: FontWeight.w700),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ).copyWith(
        animationDuration: Pal.dur,
        shadowColor: WidgetStatePropertyAll(p.accent),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(
            color: s.contains(WidgetState.disabled)
                ? p.borderDefault
                : s.contains(WidgetState.hovered)
                    ? p.accent
                    : p.borderStrong)),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.disabled)
                ? p.faint
                : s.contains(WidgetState.hovered)
                    ? p.accent
                    : p.accentDim),
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.hovered)
                ? p.accentDim.withValues(alpha: .12)
                : Colors.transparent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.hovered) ? 8.0 : 0.0),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.muted),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.bg1,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: p.borderDefault),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.bg0,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(color: p.text, fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: p.borderDefault),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.borderStrong),
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(999),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.bg0,
      contentTextStyle: TextStyle(color: p.text),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
