import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../theme.dart';

/// Pestaña "Apariencia" de Ajustes: el usuario elige el ACENTO (chips de color,
/// calcando el TweakColor del design system) y el MODO (claro / oscuro). Se
/// aplica al instante vía [ThemeController] y se recuerda en este equipo.
class AppearancePanel extends StatelessWidget {
  const AppearancePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final tc = ThemeController.instance;
    return ListenableBuilder(
      listenable: tc,
      builder: (context, _) => ListView(
        children: [
          const Text('Apariencia',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Elige el color de acento y el modo. Se aplica al instante y se '
            'recuerda en este equipo.',
            style: TextStyle(color: Pal.muted, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 24),
          _label('Acento'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final a in kAccents)
                _AccentChip(
                  def: a,
                  light: tc.light,
                  selected: tc.accentId == a.id,
                  onTap: () => tc.setAccent(a.id),
                ),
            ],
          ),
          const SizedBox(height: 28),
          _label('Modo'),
          const SizedBox(height: 12),
          _ModeToggle(light: tc.light, onChanged: tc.setLight),
          const SizedBox(height: 32),
          _label('Vista previa'),
          const SizedBox(height: 12),
          const _Preview(),
        ],
      ),
    );
  }

  static Widget _label(String t) => Text(
        t.toUpperCase(),
        style: TextStyle(
          color: Pal.faint,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      );
}

/// Chip de acento: cuadro con el color (resuelto para el modo activo), check +
/// glow cuando está seleccionado, y el nombre debajo.
class _AccentChip extends StatelessWidget {
  final AccentDef def;
  final bool light;
  final bool selected;
  final VoidCallback onTap;
  const _AccentChip({
    required this.def,
    required this.light,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = light ? def.lAccent : def.dAccent;
    final on = light ? def.lOn : def.dOn;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: Pal.durFast,
            curve: Pal.ease,
            width: 64,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? accent : Pal.borderDefault,
                width: selected ? 2 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                          color: accent.withValues(alpha: .5),
                          blurRadius: 16,
                          spreadRadius: -2),
                    ]
                  : null,
            ),
            child: selected
                ? Icon(LucideIcons.check, size: 20, color: on)
                : null,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          def.name,
          style: TextStyle(
            color: selected ? Pal.text : Pal.muted,
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Conmutador segmentado Oscuro / Claro.
class _ModeToggle extends StatelessWidget {
  final bool light;
  final ValueChanged<bool> onChanged;
  const _ModeToggle({required this.light, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Pal.inset,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Pal.borderDefault),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg('Oscuro', LucideIcons.moon, !light, () => onChanged(false)),
          _seg('Claro', LucideIcons.sun, light, () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _seg(String label, IconData icon, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Pal.durFast,
        curve: Pal.ease,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Pal.bg4 : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
              color: active ? Pal.borderStrong : Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: active ? Pal.accent : Pal.muted),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? Pal.text : Pal.muted,
                )),
          ],
        ),
      ),
    );
  }
}

/// Tarjeta de vista previa con tokens del tema activo (texto, acento, botón).
class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Pal.bg2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Pal.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 9, height: 9, decoration: BoxDecoration(
                  color: Pal.green, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text('ferservo98',
                  style: TextStyle(
                      color: Pal.accent,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('en línea',
                  style: TextStyle(color: Pal.faint, fontSize: 11.5)),
            ],
          ),
          const SizedBox(height: 8),
          Text('Así se ve el chat con este tema. El texto principal va claro y '
              'los detalles en gris.',
              style: TextStyle(color: Pal.text, fontSize: 13, height: 1.4)),
          const SizedBox(height: 4),
          Text('// comentario tenue de terminal',
              style: TextStyle(color: Pal.comment, fontSize: 12)),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Pal.accentDim,
                  borderRadius: BorderRadius.circular(5),
                  boxShadow: Pal.glowGreenSm,
                ),
                child: Text('Botón',
                    style: TextStyle(
                        color: Pal.greenInk,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Pal.borderStrong),
                ),
                child: Text('Secundario',
                    style: TextStyle(
                        color: Pal.accentDim,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
