import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';
import '../theme.dart';

/// Barra de título propia (la ventana se crea sin marco del OS).
/// Zona de arrastre + doble clic para maximizar + botones min/max/cerrar.
class TitleBar extends StatefulWidget {
  const TitleBar({super.key});
  @override
  State<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<TitleBar> with WindowListener {
  bool maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => maximized = false);

  Future<void> _toggleMax() async =>
      await windowManager.isMaximized()
          ? windowManager.unmaximize()
          : windowManager.maximize();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Pal.bg0,
      child: SizedBox(
        height: 36,
        child: Row(children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: _toggleMax,
              child: DragToMoveArea(
                child: Row(children: [
                  const SizedBox(width: 12),
                  Text('❯',
                      style: TextStyle(
                          fontSize: 14,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          color: Pal.accent)),
                  SizedBox(width: 8),
                  Text.rich(
                    TextSpan(
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Pal.muted),
                      children: [
                        TextSpan(text: 'Chat',
                            style: TextStyle(color: Pal.accent)),
                        TextSpan(text: 'Papol'),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          ),
          _WinBtn(LucideIcons.minus, 'Minimizar',
              () => windowManager.minimize()),
          _WinBtn(maximized ? LucideIcons.copy : LucideIcons.square,
              maximized ? 'Restaurar' : 'Maximizar', _toggleMax,
              iconSize: maximized ? 14 : 16),
          _WinBtn(LucideIcons.x, 'Cerrar', () => windowManager.close(),
              hoverColor: Pal.red),
        ]),
      ),
    );
  }
}

class _WinBtn extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final Color? hoverColor;
  final double iconSize;
  const _WinBtn(this.icon, this.tip, this.onTap,
      {this.hoverColor, this.iconSize = 16});

  @override
  Widget build(BuildContext context) {
    // Sin Tooltip visual: la cajita de Material bajo los botones de ventana
    // (en el borde de la pantalla) se ve fuera de lugar. Mantenemos solo la
    // etiqueta de accesibilidad (lectores de pantalla) vía Semantics.
    return Semantics(
      label: tip,
      button: true,
      child: InkWell(
        onTap: onTap,
        hoverColor: hoverColor ?? Pal.bg4,
        child: SizedBox(
          width: 46,
          height: double.infinity,
          child: Icon(icon, size: iconSize, color: Pal.muted),
        ),
      ),
    );
  }
}
