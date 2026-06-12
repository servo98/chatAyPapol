// UI de los efectos de voz y del ambiente de sala. Fiel al design system
// (aypapol-design-system / ui_kits/chatpapol, sección "efectos de voz").
//
// Tres superficies:
//  - showVoiceFxPopover  → popover ✨ de la barra de voz (master + presets).
//  - showAmbiencePopover → popover ((·)) del ambiente de sala (cama compartida).
//  - VoiceFxSettings / AiVoiceSettings → pestañas de Ajustes (editor de cadena, IA).
//
// NOTA: los EFECTOS DE VOZ controlan el motor (estado + persistencia), pero solo
// transforman el audio en vivo cuando el hook de captura nativo llama a
// VoiceFxEngine.processFrame (paso de integración con el fork RNNoise — ver
// client/docs/voice-fx-integration.md). El AMBIENTE sí funciona end-to-end.
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../ambience.dart';
import '../audio/ai_voice_changer.dart';
import '../audio/voice_fx.dart';
import '../perms.dart';
import '../store.dart';
import '../theme.dart';
import '../voice.dart';
import 'widgets.dart';

// Washes locales (no viven en Pal): mismos que voice_panel.dart.
const _washGreen = Color(0x1A39FF14);
const _washCyan = Color(0x1A22D3EE);

// Categorías de preset (espejo de voice_fx_presets) → pestañas del diseño.
const _fxCats = <(String, String, IconData)>[
  ('room', 'ambiente', LucideIcons.waves),
  ('character', 'personajes', LucideIcons.venetianMask),
  ('gender', 'género', LucideIcons.userRound),
];

// Descripción corta por preset (sub-label de las cards, como en el diseño).
const _presetDesc = <String, String>{
  'troll': 'grave y sucio',
  'demonio': 'muy grave',
  'viejo': 'tembloroso',
  'ardilla': 'agudísimo',
  'nino': 'agudo',
  'hombre_a_mujer': 'voz más aguda',
  'mujer_a_hombre': 'voz más grave',
  'cueva': 'eco de caverna',
  'iglesia': 'reverb amplio',
  'sala': 'reverb corto',
  'eco': 'repeticiones',
  'radio': 'voz de radio',
  'telefono': 'banda estrecha',
  'megafono': 'metálico fuerte',
  'robot': 'anillo metálico',
  'scifi': 'futurista',
};

IconData _presetIcon(String id) => switch (id) {
      'troll' => LucideIcons.skull,
      'demonio' => LucideIcons.flame,
      'viejo' => LucideIcons.glasses,
      'ardilla' => LucideIcons.chevronsUp,
      'nino' => LucideIcons.chevronUp,
      'hombre_a_mujer' || 'mujer_a_hombre' => LucideIcons.userRound,
      'cueva' => LucideIcons.mountain,
      'iglesia' => LucideIcons.church,
      'sala' => LucideIcons.house,
      'eco' => LucideIcons.audioWaveform,
      'radio' || 'telefono' => LucideIcons.radio,
      'megafono' => LucideIcons.megaphone,
      'robot' => LucideIcons.bot,
      'scifi' => LucideIcons.rocket,
      _ => LucideIcons.sparkles,
    };

/// Etiqueta del preset activo (para el chip "hablas como X" y el badge del tile),
/// o null si no hay preset activo o el motor está apagado.
String? activeFxLabel() {
  final e = VoiceFxEngine.instance;
  if (!e.enabled) return null;
  final id = e.activePresetId;
  if (id == null) return null;
  return e.presetById(id)?.labelEs;
}

// ───────────────────────── popover flotante (sobre la barra) ─────────────────

Future<void> _showFloating(BuildContext context, Widget child,
    {double width = 470, double maxHeight = 560}) {
  return showDialog(
    context: context,
    barrierColor: const Color(0x40000000),
    builder: (ctx) => Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 92, left: 16, right: 16),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
            child: Container(
              decoration: BoxDecoration(
                color: Pal.bg1,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Pal.borderStrong),
                boxShadow: const [
                  BoxShadow(color: Color(0x66000000), blurRadius: 26, offset: Offset(0, 10)),
                ],
              ),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _sectionLabel(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(t.toUpperCase(),
          style: const TextStyle(
              fontSize: 10.5, color: Pal.faint, letterSpacing: 1.3, fontWeight: FontWeight.w700)),
    );

// ───────────────────────── popover ✨ efectos de voz ─────────────────────────

Future<void> showVoiceFxPopover(BuildContext context) {
  final engine = VoiceFxEngine.instance;
  return _showFloating(
    context,
    ListenableBuilder(
      listenable: engine,
      builder: (ctx, _) => _FxPopoverBody(engine: engine),
    ),
  );
}

class _FxPopoverBody extends StatefulWidget {
  const _FxPopoverBody({required this.engine});
  final VoiceFxEngine engine;
  @override
  State<_FxPopoverBody> createState() => _FxPopoverBodyState();
}

class _FxPopoverBodyState extends State<_FxPopoverBody> {
  String _cat = 'character';

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    final presets = e.presets.where((p) => p.category == _cat).toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: const [
            Icon(LucideIcons.sparkles, size: 16, color: Pal.accent),
            SizedBox(width: 8),
            Text('mis efectos de voz',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Pal.text)),
          ]),
          const SizedBox(height: 2),
          const Text('la sala me oye transformado · volver a mi voz al instante',
              style: TextStyle(fontSize: 11, color: Pal.comment)),
          const SizedBox(height: 14),
          // master toggle
          _MasterToggleRow(engine: e),
          const SizedBox(height: 12),
          _CategoryTabs(current: _cat, onChanged: (c) => setState(() => _cat = c)),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: _PresetGrid(engine: e, presets: presets, columns: 3),
            ),
          ),
          const SizedBox(height: 10),
          // monitor local (inerte hasta integrar el procesado de captura)
          Tooltip(
            message: 'Monitor local: disponible al integrar el procesado de captura',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Pal.bg0,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Pal.borderDefault),
              ),
              child: Row(children: const [
                Icon(LucideIcons.headphones, size: 15, color: Pal.muted),
                SizedBox(width: 8),
                Text('escucharme', style: TextStyle(fontSize: 12, color: Pal.muted)),
                Spacer(),
                Text('monitor local', style: TextStyle(fontSize: 10.5, color: Pal.comment)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _MasterToggleRow extends StatelessWidget {
  const _MasterToggleRow({required this.engine});
  final VoiceFxEngine engine;
  @override
  Widget build(BuildContext context) {
    final on = engine.enabled;
    final label = activeFxLabel();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: on ? _washGreen : Pal.bg0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: on ? Pal.accent : Pal.borderDefault),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(on && label != null ? 'hablas como $label' : 'efectos activos',
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: on ? Pal.accent : Pal.text)),
            const SizedBox(height: 2),
            Text(on ? 'la sala te oye transformado' : 'cuando está OFF hablas con tu voz normal',
                style: const TextStyle(fontSize: 11, color: Pal.faint)),
          ]),
        ),
        Switch(
          value: on,
          activeTrackColor: Pal.accent,
          onChanged: (v) => engine.setEnabled(v),
        ),
      ]),
    );
  }
}

class _CategoryTabs extends StatelessWidget {
  const _CategoryTabs({required this.current, required this.onChanged});
  final String current;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: Pal.bg0, borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          for (final (id, label, icon) in _fxCats)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => onChanged(id),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: current == id ? Pal.bg3 : null,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(icon, size: 13, color: current == id ? Pal.accent : Pal.muted),
                    const SizedBox(width: 6),
                    Text(label,
                        style: TextStyle(
                            fontSize: 12,
                            color: current == id ? Pal.text : Pal.muted,
                            fontWeight: current == id ? FontWeight.w700 : FontWeight.w500)),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PresetGrid extends StatelessWidget {
  const _PresetGrid({required this.engine, required this.presets, this.columns = 3});
  final VoiceFxEngine engine;
  final List<VoiceFxPreset> presets;
  final int columns;
  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.55,
      children: [
        for (final p in presets)
          _PresetCard(
            preset: p,
            selected: engine.enabled && engine.activePresetId == p.id,
            onTap: () {
              engine.loadPreset(p);
              engine.setEnabled(true);
            },
          ),
      ],
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.preset, required this.selected, required this.onTap});
  final VoiceFxPreset preset;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected ? _washGreen : Pal.bg3,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? Pal.accent : Pal.borderDefault),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(_presetIcon(preset.id), size: 16, color: selected ? Pal.accent : Pal.muted),
              const Spacer(),
              if (selected) const Icon(LucideIcons.circleCheck, size: 15, color: Pal.accent),
            ]),
            const Spacer(),
            Text(preset.labelEs,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: selected ? Pal.accent : Pal.text)),
            const SizedBox(height: 1),
            Text(_presetDesc[preset.id] ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: Pal.faint)),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── popover ((·)) ambiente de sala ────────────────────

Future<void> showAmbiencePopover(
    BuildContext context, VoiceManager voice, AppStore store, String channelId) {
  final amb = AmbienceService.instance;
  return _showFloating(
    context,
    ListenableBuilder(
      listenable: Listenable.merge([store, amb, voice]),
      builder: (ctx, _) {
        final cur = store.ambienceIn(channelId);
        final canControl = store.canI(P.controlAmbience, channelId);
        return _AmbiencePopoverBody(
            voice: voice, store: store, amb: amb, cur: cur, canControl: canControl);
      },
    ),
    maxHeight: 580,
  );
}

class _AmbiencePopoverBody extends StatelessWidget {
  const _AmbiencePopoverBody({
    required this.voice,
    required this.store,
    required this.amb,
    required this.cur,
    required this.canControl,
  });
  final VoiceManager voice;
  final AppStore store;
  final AmbienceService amb;
  final dynamic cur; // AmbienceState?
  final bool canControl;

  @override
  Widget build(BuildContext context) {
    final catalog = amb.catalog;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: const [
            Icon(LucideIcons.radioTower, size: 16, color: Pal.link),
            SizedBox(width: 8),
            Text('ambiente de sala',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Pal.text)),
          ]),
          const SizedBox(height: 2),
          const Text('lo oye TODA la sala · no es tu voz',
              style: TextStyle(fontSize: 11, color: Pal.comment)),
          const SizedBox(height: 14),
          if (cur != null) _AmbienceNowPlaying(voice: voice, store: store, amb: amb, cur: cur, canControl: canControl),
          if (cur != null) const SizedBox(height: 12),
          if (catalog.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                  child: Text('No hay ambientes.\nGenera el pack con scripts/gen_ambience.py.',
                      textAlign: TextAlign.center, style: TextStyle(color: Pal.muted))),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 3.0,
                  children: [
                    for (final a in catalog)
                      _AmbienceCard(
                        def: a,
                        selected: cur?.ambienceId == a.id,
                        paused: cur?.ambienceId == a.id && (cur?.paused ?? false),
                        enabled: canControl,
                        onTap: canControl ? () => voice.setAmbience(a.id) : null,
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          _AmbienceFooterControls(voice: voice, amb: amb, cur: cur, canControl: canControl),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Pal.bg0,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Pal.borderSubtle),
            ),
            child: Row(children: [
              const Icon(LucideIcons.shield, size: 13, color: Pal.faint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  canControl
                      ? 'tú puedes controlar el ambiente · lo oye toda la sala'
                      : 'solo quien tenga el permiso "Controlar ambiente" cambia el ambiente',
                  style: const TextStyle(fontSize: 11, color: Pal.comment),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _AmbienceNowPlaying extends StatelessWidget {
  const _AmbienceNowPlaying({
    required this.voice,
    required this.store,
    required this.amb,
    required this.cur,
    required this.canControl,
  });
  final VoiceManager voice;
  final AppStore store;
  final AmbienceService amb;
  final dynamic cur;
  final bool canControl;
  @override
  Widget build(BuildContext context) {
    final def = amb.def(cur.ambienceId as String);
    final byName = store.users[cur.byUser]?.username;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _washCyan,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Pal.link.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Text(def?.emoji ?? '♪', style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(def?.name ?? cur.ambienceId as String,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Pal.link)),
            Text(
                (cur.paused as bool ? 'en pausa' : 'sonando para la sala') +
                    (byName != null ? ' · activado por $byName' : ''),
                style: const TextStyle(fontSize: 10.5, color: Pal.faint)),
          ]),
        ),
        if (canControl) ...[
          SmallIconBtn(cur.paused as bool ? LucideIcons.play : LucideIcons.pause,
              cur.paused as bool ? 'Reanudar' : 'Pausar', voice.toggleAmbiencePause),
          SmallIconBtn(LucideIcons.square, 'Detener', voice.stopAmbience, color: Pal.red),
        ],
      ]),
    );
  }
}

class _AmbienceCard extends StatelessWidget {
  const _AmbienceCard({
    required this.def,
    required this.selected,
    required this.paused,
    required this.enabled,
    required this.onTap,
  });
  final AmbienceDef def;
  final bool selected;
  final bool paused;
  final bool enabled;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? _washCyan : Pal.bg3,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: selected ? Pal.link : Pal.borderDefault),
          ),
          child: Row(children: [
            Text(def.emoji ?? '♪', style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(def.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: selected ? Pal.link : Pal.text)),
                    const Text('bucle', style: TextStyle(fontSize: 10, color: Pal.faint)),
                  ]),
            ),
            Icon(
              selected ? (paused ? LucideIcons.pause : LucideIcons.circlePlay) : LucideIcons.play,
              size: 16,
              color: selected ? Pal.link : Pal.muted,
            ),
          ]),
        ),
      ),
    );
  }
}

class _AmbienceFooterControls extends StatelessWidget {
  const _AmbienceFooterControls(
      {required this.voice, required this.amb, required this.cur, required this.canControl});
  final VoiceManager voice;
  final AmbienceService amb;
  final dynamic cur;
  final bool canControl;
  @override
  Widget build(BuildContext context) {
    final loopOn = (cur?.loop as bool?) ?? true;
    return Row(children: [
      const Icon(LucideIcons.volume2, size: 16, color: Pal.muted),
      Expanded(
        child: Slider(
          value: amb.volume,
          activeColor: Pal.link,
          onChanged: (v) => amb.setVolume(v),
        ),
      ),
      SizedBox(
          width: 38,
          child: Text('${(amb.volume * 100).round()}%',
              style: const TextStyle(fontSize: 11, color: Pal.muted))),
      const SizedBox(width: 8),
      // loop toggle (estado de sala) — solo si controlas y hay algo sonando
      Opacity(
        opacity: (canControl && cur != null) ? 1 : 0.5,
        child: Row(children: [
          Switch(
            value: loopOn,
            activeTrackColor: Pal.link,
            onChanged: (canControl && cur != null) ? (v) => voice.setAmbienceLoop(v) : null,
          ),
          const Text('loop', style: TextStyle(fontSize: 11, color: Pal.muted)),
        ]),
      ),
    ]);
  }
}

// ═════════════════════════ Ajustes: efectos de voz ═══════════════════════════

class VoiceFxSettings extends StatefulWidget {
  const VoiceFxSettings({super.key});
  @override
  State<VoiceFxSettings> createState() => _VoiceFxSettingsState();
}

class _VoiceFxSettingsState extends State<VoiceFxSettings> {
  String _cat = 'character';
  final _expanded = <int>{};

  @override
  Widget build(BuildContext context) {
    final e = VoiceFxEngine.instance;
    return ListenableBuilder(
      listenable: e,
      builder: (ctx, _) {
        final presets = e.presets.where((p) => p.category == _cat).toList();
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          children: [
            const Text('// EFECTOS DE VOZ',
                style: TextStyle(fontSize: 12, color: Pal.accent, letterSpacing: 1.2)),
            const SizedBox(height: 6),
            const Text('efectos de mi voz',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Pal.text)),
            const SizedBox(height: 8),
            const Text(
                'transforma tu micrófono en vivo. la sala te oye con el efecto. OFF y vuelves a '
                'tu voz normal al instante — sin reconectar.',
                style: TextStyle(fontSize: 13, color: Pal.muted, height: 1.4)),
            const SizedBox(height: 14),
            Row(children: const [
              Expanded(
                  child: _InfoCard(
                      icon: LucideIcons.mic,
                      title: 'esto = TU voz',
                      body: 'solo cambia cómo te oyen a ti. cada quien controla la suya.')),
              SizedBox(width: 12),
              Expanded(
                  child: _InfoCard(
                      icon: LucideIcons.radioTower,
                      title: '¿buscas la cama de sonido?',
                      body: 'el ambiente compartido vive en el botón de voz · lo oye toda la sala.')),
            ]),
            const SizedBox(height: 16),
            _MasterToggleRow(engine: e),
            const SizedBox(height: 18),
            const Text('presets de un toque',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Pal.text)),
            const SizedBox(height: 10),
            _CategoryTabs(current: _cat, onChanged: (c) => setState(() => _cat = c)),
            const SizedBox(height: 12),
            _PresetGrid(engine: e, presets: presets, columns: 3),
            const SizedBox(height: 20),
            Row(children: const [
              Text('editor de cadena',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Pal.text)),
              SizedBox(width: 8),
              Text('— modo avanzado', style: TextStyle(fontSize: 12, color: Pal.faint)),
            ]),
            const SizedBox(height: 4),
            const Text('# el orden importa: la señal pasa de arriba a abajo, del mic a la sala.',
                style: TextStyle(fontSize: 11, color: Pal.comment)),
            const SizedBox(height: 12),
            _ChainEditor(
              engine: e,
              expanded: _expanded,
              onToggleExpand: (i) => setState(() {
                _expanded.contains(i) ? _expanded.remove(i) : _expanded.add(i);
              }),
            ),
          ],
        );
      },
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Pal.bg0,
        borderRadius: BorderRadius.circular(8),
        border: const Border(left: BorderSide(color: Pal.accent, width: 2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 14, color: Pal.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Pal.text)),
          ),
        ]),
        const SizedBox(height: 6),
        Text(body, style: const TextStyle(fontSize: 11, color: Pal.faint, height: 1.35)),
      ]),
    );
  }
}

class _ChainEditor extends StatelessWidget {
  const _ChainEditor({required this.engine, required this.expanded, required this.onToggleExpand});
  final VoiceFxEngine engine;
  final Set<int> expanded;
  final ValueChanged<int> onToggleExpand;
  @override
  Widget build(BuildContext context) {
    final nodes = engine.nodes;
    return Container(
      decoration: BoxDecoration(
        color: Pal.inset,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Pal.borderSubtle),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: const [
          Icon(LucideIcons.mic, size: 13, color: Pal.muted),
          SizedBox(width: 6),
          Text('MIC', style: TextStyle(fontSize: 11, color: Pal.muted, letterSpacing: 1)),
          Spacer(),
          Text('SALA →', style: TextStyle(fontSize: 11, color: Pal.accent, letterSpacing: 1)),
        ]),
        const SizedBox(height: 8),
        if (nodes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('cadena vacía — añade un efecto abajo o aplica un preset',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Pal.comment)),
          ),
        for (var i = 0; i < nodes.length; i++)
          _ChainNodeRow(
            engine: engine,
            index: i,
            node: nodes[i],
            last: i == nodes.length - 1,
            expanded: expanded.contains(i),
            onToggleExpand: () => onToggleExpand(i),
          ),
        const SizedBox(height: 10),
        _sectionLabel('// añadir efecto'),
        _EffectPalette(engine: engine),
      ]),
    );
  }
}

class _ChainNodeRow extends StatelessWidget {
  const _ChainNodeRow({
    required this.engine,
    required this.index,
    required this.node,
    required this.last,
    required this.expanded,
    required this.onToggleExpand,
  });
  final VoiceFxEngine engine;
  final int index;
  final VoiceFxNode node;
  final bool last, expanded;
  final VoidCallback onToggleExpand;

  @override
  Widget build(BuildContext context) {
    final dim = node.bypass;
    // valor "destacado" del primer param (resumen como en el diseño)
    final firstParam = node.type.params.first;
    final firstVal = node.params[firstParam.id] ?? firstParam.defaultValue;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: Pal.bg3,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Pal.borderDefault),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(children: [
            const Icon(LucideIcons.gripVertical, size: 14, color: Pal.comment),
            const SizedBox(width: 6),
            SizedBox(
                width: 16,
                child: Text('${index + 1}',
                    style: const TextStyle(fontSize: 11, color: Pal.faint))),
            Icon(_fxTypeIcon(node.type), size: 14, color: dim ? Pal.comment : Pal.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(node.type.labelEs,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: dim ? Pal.faint : Pal.text)),
            ),
            Text(_fmtParam(firstParam, firstVal),
                style: const TextStyle(fontSize: 11, color: Pal.muted)),
            const SizedBox(width: 6),
            _miniBtn(LucideIcons.arrowUp, 'Subir',
                index == 0 ? null : () => engine.reorder(index, index - 1)),
            _miniBtn(LucideIcons.arrowDown, 'Bajar',
                last ? null : () => engine.reorder(index, index + 1)),
            _miniBtn(node.bypass ? LucideIcons.eyeOff : LucideIcons.eye,
                node.bypass ? 'Activar' : 'Silenciar', () => engine.setBypass(index, !node.bypass)),
            _miniBtn(LucideIcons.trash2, 'Quitar', () => engine.removeAt(index), color: Pal.red),
            _miniBtn(expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                expanded ? 'Cerrar' : 'Ajustar', onToggleExpand),
          ]),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(children: [
              const Divider(height: 1, color: Pal.borderSubtle),
              const SizedBox(height: 6),
              for (final p in node.type.params)
                _ParamSlider(
                  param: p,
                  value: node.params[p.id] ?? p.defaultValue,
                  onChanged: (v) => engine.setParam(index, p.id, v),
                ),
            ]),
          ),
      ]),
    );
  }

  Widget _miniBtn(IconData icon, String tip, VoidCallback? onTap, {Color? color}) => Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 14, color: onTap == null ? Pal.comment : (color ?? Pal.muted)),
          ),
        ),
      );
}

class _ParamSlider extends StatelessWidget {
  const _ParamSlider({required this.param, required this.value, required this.onChanged});
  final VoiceFxParam param;
  final double value;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) {
    final isType = param.jsonKey == 'type'; // biquad: discreto 0..3
    return Row(children: [
      SizedBox(
        width: 110,
        child: Text(param.labelEs,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Pal.muted)),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(param.min, param.max),
          min: param.min,
          max: param.max,
          divisions: isType ? 3 : null,
          activeColor: Pal.accent,
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 56,
        child: Text(_fmtParam(param, value),
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11, color: Pal.muted)),
      ),
    ]);
  }
}

class _EffectPalette extends StatelessWidget {
  const _EffectPalette({required this.engine});
  final VoiceFxEngine engine;
  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final t in VoiceFxType.values)
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => engine.add(t),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Pal.bg0,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Pal.borderDefault),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_fxTypeIcon(t), size: 13, color: Pal.muted),
                const SizedBox(width: 6),
                Text(t.labelEs, style: const TextStyle(fontSize: 11.5, color: Pal.text)),
              ]),
            ),
          ),
      ],
    );
  }
}

IconData _fxTypeIcon(VoiceFxType t) => switch (t) {
      VoiceFxType.reverb => LucideIcons.waves,
      VoiceFxType.delay => LucideIcons.repeat,
      VoiceFxType.biquad => LucideIcons.filter,
      VoiceFxType.ringmod => LucideIcons.circleDot,
      VoiceFxType.distortion => LucideIcons.zap,
      VoiceFxType.pitch => LucideIcons.arrowUpDown,
      VoiceFxType.noise => LucideIcons.radio,
      VoiceFxType.tremolo => LucideIcons.activity,
      VoiceFxType.chorus => LucideIcons.layers,
    };

String _fmtParam(VoiceFxParam p, double v) {
  if (p.jsonKey == 'type') {
    const names = ['LP', 'HP', 'BP', 'Notch'];
    final i = v.round().clamp(0, 3);
    return names[i];
  }
  if (p.unit == 'st') return '${v >= 0 ? '+' : ''}${v.toStringAsFixed(0)}';
  if (p.unit == 'Hz' || p.unit == 'ms') return '${v.round()}${p.unit}';
  if (p.unit == '×') return '${v.toStringAsFixed(2)}×';
  // adimensional 0..1 → porcentaje
  if (p.min >= 0 && p.max <= 1.0) return '${(v * 100).round()}%';
  return v.toStringAsFixed(2);
}

// ═════════════════════════ Ajustes: cambiador de voz IA ══════════════════════

class AiVoiceSettings extends StatefulWidget {
  const AiVoiceSettings({super.key});
  @override
  State<AiVoiceSettings> createState() => _AiVoiceSettingsState();
}

class _AiVoiceSettingsState extends State<AiVoiceSettings> {
  AiBackend _sim = AiBackend.cuda;

  @override
  void initState() {
    super.initState();
    AiVoiceChanger.instance.init();
    _sim = AiVoiceChanger.instance.capability.backend;
  }

  @override
  Widget build(BuildContext context) {
    final ai = AiVoiceChanger.instance;
    return ListenableBuilder(
      listenable: ai,
      builder: (ctx, _) {
        final simCap = AiVoiceChanger.capabilityFor(_sim);
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          children: [
            const Text('// CAMBIADOR DE VOZ IA',
                style: TextStyle(fontSize: 12, color: Pal.accent, letterSpacing: 1.2)),
            const SizedBox(height: 6),
            const Text('cambiador de voz IA',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Pal.text)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0x1FFFB627),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Pal.yellow.withValues(alpha: 0.5)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(LucideIcons.triangleAlert, size: 13, color: Pal.yellow),
                SizedBox(width: 8),
                Text('EXPERIMENTAL · PROCESO EXTERNO LOCAL',
                    style: TextStyle(
                        fontSize: 11, color: Pal.yellow, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ]),
            ),
            const SizedBox(height: 14),
            const Text(
                'conversión de voz por IA (estilo RVC): hombre↔mujer realista o la voz de un '
                'personaje. es pesado y de mayor latencia que los efectos normales — pensado para '
                'equipos potentes.',
                style: TextStyle(fontSize: 13, color: Pal.muted, height: 1.4)),
            const SizedBox(height: 16),
            const Text('tu equipo',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Pal.text)),
            const SizedBox(height: 8),
            _HardwareCard(cap: ai.capability),
            const SizedBox(height: 14),
            const Text('# simula otro backend para ver el estado honesto en cada caso:',
                style: TextStyle(fontSize: 11, color: Pal.comment)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final b in AiBackend.values)
                _backendChip(b, _sim == b, () => setState(() => _sim = b)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _statCard('BACKEND', AiVoiceChanger.backendLabel(simCap.backend),
                  simCap.isRecommended ? Pal.accent : Pal.text)),
              const SizedBox(width: 10),
              Expanded(child: _statCard('LATENCIA ESTIMADA',
                  simCap.backend == AiBackend.none ? '—' : '~${simCap.expectedLatencyMs} ms', Pal.text)),
              const SizedBox(width: 10),
              Expanded(child: _statCard('VEREDICTO', simCap.isRecommended ? 'recomendado' : 'no ideal',
                  simCap.isRecommended ? Pal.accent : Pal.yellow)),
            ]),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x14FFB627),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Pal.yellow.withValues(alpha: 0.4)),
              ),
              child: Row(children: [
                const Icon(LucideIcons.triangleAlert, size: 15, color: Pal.yellow),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      'con IA, tu voz llegará ~${simCap.expectedLatencyMs}ms después. notarás desfase '
                      'al hablar. desactívala para volver a baja latencia.',
                      style: const TextStyle(fontSize: 12, color: Pal.muted, height: 1.35)),
                ),
              ]),
            ),
            const SizedBox(height: 18),
            const Text('motor',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Pal.text)),
            const SizedBox(height: 10),
            _aiField(LucideIcons.folder, 'ruta del motor', ai.exePath,
                'p. ej. ~/.papol/rvc/engine', (v) => ai.setExePath(v)),
            const SizedBox(height: 8),
            _aiField(LucideIcons.sparkles, 'modelo de voz', ai.modelPath, 'papol-fem-v2.pth',
                (v) => ai.setModelPath(v)),
            const SizedBox(height: 8),
            _aiField(LucideIcons.mic, 'entrada virtual', ai.inputDevice, ai.virtualMicHint,
                (v) => ai.setInputDevice(v)),
            const SizedBox(height: 14),
            Row(children: [
              ElevatedButton.icon(
                onPressed: ai.isRunning ? ai.stop : () => ai.start(),
                icon: Icon(ai.isRunning ? LucideIcons.square : LucideIcons.play, size: 16),
                label: Text(ai.isRunning ? 'detener motor' : 'iniciar motor'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: ai.isRunning ? Pal.red : Pal.accentDim,
                    foregroundColor: ai.isRunning ? Pal.text : Pal.greenInk),
              ),
              const SizedBox(width: 12),
              Text(_statusLabel(ai.status),
                  style: TextStyle(fontSize: 12, color: _statusColor(ai.status))),
            ]),
            const SizedBox(height: 12),
            _LogPanel(lines: ai.log, status: ai.status),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: Pal.bg0,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Pal.borderSubtle),
              ),
              child: Text('Guía de instalación: client/docs/voice-fx-ai-setup.md\n${ai.routingSummary}',
                  style: const TextStyle(fontSize: 11, color: Pal.comment, height: 1.4)),
            ),
          ],
        );
      },
    );
  }

  Widget _backendChip(AiBackend b, bool on, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: on ? _washGreen : Pal.bg0,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: on ? Pal.accent : Pal.borderDefault),
          ),
          child: Text(AiVoiceChanger.backendLabel(b),
              style: TextStyle(
                  fontSize: 11.5,
                  color: on ? Pal.accent : Pal.muted,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500)),
        ),
      );

  Widget _statCard(String label, String value, Color valueColor) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Pal.bg0,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Pal.borderSubtle),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(fontSize: 10, color: Pal.faint, letterSpacing: 1)),
          const SizedBox(height: 6),
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: valueColor)),
        ]),
      );

  Widget _aiField(IconData icon, String label, String value, String hint,
          ValueChanged<String> onChanged) =>
      Row(children: [
        SizedBox(
          width: 130,
          child: Row(children: [
            Icon(icon, size: 14, color: Pal.muted),
            const SizedBox(width: 8),
            Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 12, color: Pal.muted))),
          ]),
        ),
        Expanded(
          child: TextField(
            controller: TextEditingController(text: value)
              ..selection = TextSelection.collapsed(offset: value.length),
            onSubmitted: onChanged,
            style: const TextStyle(fontSize: 12, color: Pal.text),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: const TextStyle(fontSize: 12, color: Pal.comment),
            ),
          ),
        ),
      ]);
}

class _HardwareCard extends StatelessWidget {
  const _HardwareCard({required this.cap});
  final AiCapability cap;
  @override
  Widget build(BuildContext context) {
    final ok = cap.isRecommended;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Pal.bg0,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ok ? Pal.accent.withValues(alpha: 0.5) : Pal.borderDefault),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: ok ? _washGreen : Pal.bg3,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(LucideIcons.cpu, size: 22, color: ok ? Pal.accent : Pal.muted),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${AiVoiceChanger.backendLabel(cap.backend)} · ${ok ? 'listo' : 'limitado'}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Pal.text)),
              const SizedBox(width: 8),
              if (ok)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: _washGreen, borderRadius: BorderRadius.circular(10)),
                  child: const Text('recomendado',
                      style: TextStyle(fontSize: 10.5, color: Pal.accent, fontWeight: FontWeight.w700)),
                ),
            ]),
            const SizedBox(height: 4),
            Text(
                ok
                    ? '${AiVoiceChanger.backendLabel(cap.backend)} detectado — buena opción en este equipo.'
                    : AiVoiceChanger.instance.unavailableReason,
                style: const TextStyle(fontSize: 11.5, color: Pal.faint, height: 1.35)),
          ]),
        ),
      ]),
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.lines, required this.status});
  final List<String> lines;
  final AiVcStatus status;
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 130,
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Pal.inset,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Pal.borderSubtle),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(LucideIcons.circle,
              size: 8, color: status == AiVcStatus.running ? Pal.green : Pal.comment),
          const SizedBox(width: 6),
          const Text('log del motor',
              style: TextStyle(fontSize: 11, color: Pal.faint, letterSpacing: 0.5)),
        ]),
        const SizedBox(height: 6),
        Expanded(
          child: lines.isEmpty
              ? const Text('# motor detenido\n  pulsa «iniciar motor» para arrancar la conversión por IA',
                  style: TextStyle(fontSize: 11, color: Pal.comment, height: 1.4))
              : ListView.builder(
                  reverse: true,
                  itemCount: lines.length,
                  itemBuilder: (c, i) => Text(lines[lines.length - 1 - i],
                      style: const TextStyle(fontSize: 10.5, color: Pal.muted)),
                ),
        ),
      ]),
    );
  }
}

String _statusLabel(AiVcStatus s) => switch (s) {
      AiVcStatus.stopped => 'detenido',
      AiVcStatus.starting => 'arrancando…',
      AiVcStatus.running => 'corriendo',
      AiVcStatus.error => 'error',
    };

Color _statusColor(AiVcStatus s) => switch (s) {
      AiVcStatus.running => Pal.green,
      AiVcStatus.error => Pal.red,
      _ => Pal.muted,
    };
