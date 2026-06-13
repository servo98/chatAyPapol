// Popover de ajustes de audio POR USUARIO — fiel al diseño de
// /aypapo-design-system/ui_kits/chatpapol/voz-ajustes-popover.html
//
// Se muestra con showUserAudioPopover() desde onSecondaryTap / onLongPress
// sobre el tile del participante en VoicePanel.
//
// INCIERTO: la funcionalidad de EQ nativa (setUserEq/clearUserEq en WebrtcApm)
// depende del resultado del "probe de fase 0" — si el nativo no entrega PCM
// remoto vía AddSink, la curva y los faders son solo UI visual sin efecto real.
// El slider de VOLUMEN siempre funciona (usa la ruta ya probada setUserVolume).

library;

import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../audio/user_eq.dart';
import '../theme.dart';
import '../voice.dart';

// ─── Punto de entrada ─────────────────────────────────────────────────────────

/// Muestra el popover de ajustes de audio para [identity] ([name] para la
/// cabecera) anclado cerca de [anchorContext] si está disponible.
///
/// Uso en voice_panel.dart:
/// ```dart
/// onSecondaryTap: () => showUserAudioPopover(ctx, voice, userId, user?.username),
/// onLongPress:   () => showUserAudioPopover(ctx, voice, userId, user?.username),
/// ```
void showUserAudioPopover(
  BuildContext anchorContext,
  VoiceManager voice,
  String identity,
  String? name,
) {
  // Calcular posición del tile para anclar el popover cerca.
  Offset origin = const Offset(80, 80);
  try {
    final rb = anchorContext.findRenderObject() as RenderBox?;
    if (rb != null && rb.attached) {
      final pos = rb.localToGlobal(Offset.zero);
      final size = rb.size;
      origin = Offset(pos.dx + size.width / 2, pos.dy + size.height);
    }
  } catch (_) {}

  showDialog<void>(
    context: anchorContext,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    builder: (ctx) => _AnchoredPopover(
      origin: origin,
      screenSize: MediaQuery.sizeOf(anchorContext),
      child: _UserAudioPopover(
        voice: voice,
        identity: identity,
        name: name,
        onClose: () => Navigator.of(ctx).pop(),
      ),
    ),
  );
}

// ─── Wrapper de posicionamiento ───────────────────────────────────────────────

class _AnchoredPopover extends StatelessWidget {
  final Offset origin;
  final Size screenSize;
  final Widget child;

  const _AnchoredPopover({
    required this.origin,
    required this.screenSize,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    const w = 336.0;
    // Intentar poner a la derecha del tile; si no cabe, a la izquierda.
    double left = origin.dx - w / 2;
    left = left.clamp(12.0, screenSize.width - w - 12);
    // Poner debajo si cabe; si no, encima.
    double top = origin.dy + 8;
    const estimatedH = 460.0; // alto máximo aproximado del popover
    if (top + estimatedH > screenSize.height - 12) {
      top = origin.dy - estimatedH - 8;
    }
    top = top.clamp(12.0, screenSize.height - estimatedH - 12);

    return Stack(children: [
      // Toque en zona oscura → cerrar
      Positioned.fill(child: GestureDetector(onTap: () => Navigator.of(context).pop())),
      Positioned(left: left, top: top, width: w, child: child),
    ]);
  }
}

// ─── El popover en sí ─────────────────────────────────────────────────────────

class _UserAudioPopover extends StatefulWidget {
  final VoiceManager voice;
  final String identity;
  final String? name;
  final VoidCallback onClose;

  const _UserAudioPopover({
    required this.voice,
    required this.identity,
    required this.name,
    required this.onClose,
  });

  @override
  State<_UserAudioPopover> createState() => _UserAudioPopoverState();
}

class _UserAudioPopoverState extends State<_UserAudioPopover> {
  late double _vol;
  late UserEqSettings _eq;

  @override
  void initState() {
    super.initState();
    _vol = widget.voice.userVolume(widget.identity);
    _eq = widget.voice.userEq(widget.identity);
  }

  // Debounce: cada cambio de drag aplica al nativo pero solo cada ~60 ms para
  // no saturar el MethodChannel. Los callbacks notifyListeners del voice ya
  // reconstruyen el VoicePanel cuando importa.
  DateTime _lastApply = DateTime.fromMillisecondsSinceEpoch(0);

  void _applyVol(double v) {
    setState(() => _vol = v);
    final now = DateTime.now();
    if (now.difference(_lastApply).inMilliseconds >= 60) {
      _lastApply = now;
      widget.voice.setUserVolume(widget.identity, v);
    }
  }

  void _applyEq(UserEqSettings eq) {
    setState(() => _eq = eq);
    final now = DateTime.now();
    if (now.difference(_lastApply).inMilliseconds >= 60) {
      _lastApply = now;
      widget.voice.setUserEq(widget.identity, eq);
    }
  }

  void _flushVol() => widget.voice.setUserVolume(widget.identity, _vol);
  void _flushEq() => widget.voice.setUserEq(widget.identity, _eq);

  void _reset() {
    setState(() {
      _vol = 1.0;
      _eq = const UserEqSettings();
    });
    widget.voice.setUserVolume(widget.identity, 1.0);
    widget.voice.setUserEq(widget.identity, const UserEqSettings());
  }

  @override
  Widget build(BuildContext context) {
    // Iniciales del nombre para el avatar.
    final displayName = widget.name ?? widget.identity;
    final initials = displayName.isNotEmpty
        ? displayName.substring(0, math.min(2, displayName.length)).toUpperCase()
        : '?';

    final muted = _vol < 0.01;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 336,
        decoration: BoxDecoration(
          color: Pal.bg0,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Pal.borderStrong),
          boxShadow: const [
            BoxShadow(color: Color(0xCC000000), blurRadius: 40, offset: Offset(0, 18), spreadRadius: -14),
            BoxShadow(color: Color(0x1439FF14), blurRadius: 26, spreadRadius: -10),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(children: [
            // Scanlines sutiles (efecto terminal del design system)
            Positioned.fill(child: CustomPaint(painter: _ScanlinesPainter())),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(initials, displayName, muted),
                _buildDivider(),
                _buildVolumeSection(muted),
                _buildDivider(),
                _buildEqSection(),
                _buildDivider(),
                _buildPresetsSection(),
                _buildDivider(),
                _buildFooter(),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  // ── Cabecera ──────────────────────────────────────────────────────────────

  Widget _buildHeader(String initials, String displayName, bool muted) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // Avatar (círculo con iniciales, color acento)
          Container(
            width: 28,
            height: 28,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Pal.accentDim,
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Pal.greenInk,
                height: 1,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: Pal.text,
                letterSpacing: -0.01,
              ),
            ),
          ),
          // Icono de altavoz (rojo si muted)
          Icon(
            muted ? LucideIcons.volumeX : LucideIcons.volume2,
            size: 14,
            color: muted ? Pal.red : Pal.faint,
          ),
        ]),
        const SizedBox(height: 8),
        // Chip "solo tú oyes estos ajustes"
        Container(
          height: 21,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: const Color(0x1239FF14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0x4239FF14)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Pal.accent,
                boxShadow: Pal.glowGreenSm,
              ),
            ),
            const SizedBox(width: 6),
            const Text(
              '// sólo tú oyes estos ajustes',
              style: TextStyle(fontSize: 10.5, color: Pal.accentDim, letterSpacing: 0.01),
            ),
          ]),
        ),
      ]),
    );
  }

  // ── Volumen ───────────────────────────────────────────────────────────────

  Widget _buildVolumeSection(bool muted) {
    // _vol en [0, 2]; mostrar como porcentaje 0..200.
    final pct = (_vol * 100).round();
    // fill: 0% → left=0; 100% → left=50%; 200% → left=100%
    final fillFraction = (_vol / 2.0).clamp(0.0, 1.0);
    // tick de referencia al 50% (100%)
    const centerFraction = 0.5;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Label + valor
        Row(children: [
          const Text('VOLUMEN',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.16,
                  color: Pal.faint)),
          const Spacer(),
          Text(
            muted ? 'silenciado · 0%' : '$pct%',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: muted ? Pal.red : Pal.accent,
            ),
          ),
        ]),
        const SizedBox(height: 9),
        // Track + slider
        Row(children: [
          Icon(
            muted
                ? LucideIcons.volumeX
                : _vol <= 0.6
                    ? LucideIcons.volume1
                    : LucideIcons.volume2,
            size: 18,
            color: muted ? Pal.red : Pal.muted,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: _VolTrack(
              value: _vol,
              fillFraction: fillFraction,
              centerFraction: centerFraction,
              muted: muted,
              onChanged: _applyVol,
              onChangeEnd: (_) => _flushVol(),
            ),
          ),
        ]),
        const SizedBox(height: 5),
        // Escala 0% / 100% / 200%
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('0%', style: TextStyle(fontSize: 9, color: Pal.comment)),
            Text('100%',
                style: TextStyle(
                    fontSize: 9,
                    color: Pal.faint,
                    fontWeight: FontWeight.w500)),
            Text('200%', style: TextStyle(fontSize: 9, color: Pal.comment)),
          ],
        ),
      ]),
    );
  }

  // ── EQ ────────────────────────────────────────────────────────────────────

  Widget _buildEqSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('ECUALIZADOR',
            style: TextStyle(fontSize: 10, letterSpacing: 0.16, color: Pal.faint)),
        const SizedBox(height: 9),
        // Curva EQ SVG
        _EqCurveWidget(bass: _eq.bass, mid: _eq.mid, treble: _eq.treble),
        const SizedBox(height: 12),
        // 3 faders verticales
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _EqBand(
                  label: 'GRAVES',
                  value: _eq.bass,
                  onChanged: (v) => _applyEq(_eq.copyWith(bass: v, clearPreset: true)),
                  onChangeEnd: (_) => _flushEq(),
                ),
              ),
              Expanded(
                child: _EqBand(
                  label: 'MEDIOS',
                  value: _eq.mid,
                  onChanged: (v) => _applyEq(_eq.copyWith(mid: v, clearPreset: true)),
                  onChangeEnd: (_) => _flushEq(),
                ),
              ),
              Expanded(
                child: _EqBand(
                  label: 'AGUDOS',
                  value: _eq.treble,
                  onChanged: (v) => _applyEq(_eq.copyWith(treble: v, clearPreset: true)),
                  onChangeEnd: (_) => _flushEq(),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  // ── Presets ───────────────────────────────────────────────────────────────

  Widget _buildPresetsSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('PRESETS',
            style: TextStyle(fontSize: 10, letterSpacing: 0.16, color: Pal.faint)),
        const SizedBox(height: 9),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final entry in kEqPresets.entries)
            _PresetChip(
              label: kEqPresetLabels[entry.key] ?? entry.key,
              active: _eq.preset == entry.key,
              onTap: () {
                final eq = entry.value;
                setState(() => _eq = eq);
                widget.voice.setUserEq(widget.identity, eq);
              },
            ),
        ]),
      ]),
    );
  }

  // ── Footer ────────────────────────────────────────────────────────────────

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      child: Row(children: [
        // Restablecer
        _FooterBtn(
          icon: LucideIcons.rotateCcw,
          label: 'restablecer',
          onTap: _reset,
        ),
        const Spacer(),
        // Listo
        GestureDetector(
          onTap: () {
            _flushVol();
            _flushEq();
            widget.onClose();
          },
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Pal.accentDim,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: const Color(0xFF2CE60F)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: const [
              Icon(LucideIcons.check, size: 14, color: Pal.greenInk),
              SizedBox(width: 7),
              Text('listo',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Pal.greenInk,
                  )),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildDivider() =>
      const Divider(height: 1, thickness: 1, color: Pal.borderSubtle);
}

// ─── _VolTrack — slider horizontal custom ─────────────────────────────────────

class _VolTrack extends StatelessWidget {
  final double value;       // 0..2
  final double fillFraction;
  final double centerFraction;
  final bool muted;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  const _VolTrack({
    required this.value,
    required this.fillFraction,
    required this.centerFraction,
    required this.muted,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 5,
        activeTrackColor: muted ? Pal.red : Pal.accentDim,
        inactiveTrackColor: const Color(0xFF131918),
        thumbColor: muted ? Pal.red : Pal.accent,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        overlayColor: Color(muted ? 0x2FFF4D4D : 0x2F39FF14),
        trackShape: const _VolTrackShape(),
      ),
      child: Slider(
        value: value,
        min: 0,
        max: 2,
        divisions: 80,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );
  }
}

// Forma del track sin padding horizontal implícito de Flutter.
class _VolTrackShape extends RoundedRectSliderTrackShape {
  const _VolTrackShape();
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 5;
    final trackLeft = offset.dx;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    return Rect.fromLTWH(trackLeft, trackTop, parentBox.size.width, trackHeight);
  }
}

// ─── _EqCurveWidget — mini curva del EQ ──────────────────────────────────────

class _EqCurveWidget extends StatelessWidget {
  final double bass, mid, treble; // −12..+12

  const _EqCurveWidget({
    required this.bass,
    required this.mid,
    required this.treble,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: Pal.inset,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Pal.borderSubtle),
      ),
      child: Stack(children: [
        // Línea 0 dB
        Positioned(
          left: 0,
          right: 0,
          top: 27, // mitad de 56 − 1px
          child: Container(height: 1, color: const Color(0x8C4D5F56)),
        ),
        // Label "0 dB"
        const Positioned(
          right: 5,
          top: 15,
          child: Text('0 dB',
              style: TextStyle(fontSize: 8, color: Pal.comment, letterSpacing: 0.04)),
        ),
        // Curva SVG
        Positioned.fill(
          child: CustomPaint(
            painter: _EqCurvePainter(bass: bass, mid: mid, treble: treble),
          ),
        ),
      ]),
    );
  }
}

class _EqCurvePainter extends CustomPainter {
  final double bass, mid, treble;

  const _EqCurvePainter({
    required this.bass,
    required this.mid,
    required this.treble,
  });

  static double _dbToY(double db, double h) {
    const pad = 7.0;
    final center = h / 2;
    return center - (db / 12) * (center - pad);
  }

  // Coseno suave entre dos valores (t ∈ [0,1]).
  static double _cosInterp(double a, double b, double t) =>
      a + (b - a) * (1 - math.cos(t * math.pi)) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    const N = 48;
    final bands = [bass, mid, treble];
    final pts = <Offset>[];

    for (int i = 0; i <= N; i++) {
      final x = i / N;
      double db;
      if (x <= 0.5) {
        db = _cosInterp(bands[0], bands[1], x / 0.5);
      } else {
        db = _cosInterp(bands[1], bands[2], (x - 0.5) / 0.5);
      }
      pts.add(Offset(x * size.width, _dbToY(db, size.height)));
    }

    final linePath = Path();
    linePath.moveTo(pts.first.dx, pts.first.dy);
    for (int i = 1; i < pts.length; i++) {
      linePath.lineTo(pts[i].dx, pts[i].dy);
    }

    // Área rellena con gradiente
    final areaPath = Path()..addPath(linePath, Offset.zero);
    areaPath.lineTo(size.width, size.height);
    areaPath.lineTo(0, size.height);
    areaPath.close();

    final areaRect = Offset.zero & size;
    final areaPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Color(0x4239FF14), Color(0x0039FF14)],
      ).createShader(areaRect)
      ..style = PaintingStyle.fill;
    canvas.drawPath(areaPath, areaPaint);

    // Línea de la curva con glow
    final glowPaint = Paint()
      ..color = const Color(0x6039FF14)
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawPath(linePath, glowPaint);

    final linePaint = Paint()
      ..color = Pal.accent
      ..strokeWidth = 1.75
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, linePaint);
  }

  @override
  bool shouldRepaint(_EqCurvePainter old) =>
      old.bass != bass || old.mid != mid || old.treble != treble;
}

// ─── _EqBand — fader vertical individual ────────────────────────────────────

class _EqBand extends StatelessWidget {
  final String label;
  final double value; // −12..+12 dB
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  const _EqBand({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final isFlat = value.abs() < 0.1;
    final sign = value > 0 ? '+' : '';
    final valStr = '$sign${value.toStringAsFixed(1)} dB';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Fader vertical (RotatedBox + Slider)
        SizedBox(
          height: 80, // área de toque cómoda
          child: RotatedBox(
            quarterTurns: 3, // de horizontal → vertical, mínimo abajo
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: isFlat ? Colors.transparent : Pal.accentDim,
                inactiveTrackColor: const Color(0xFF0F1413),
                thumbColor: Pal.accent,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                overlayColor: const Color(0x2F39FF14),
                trackShape: _CenteredTrackShape(),
              ),
              child: Slider(
                value: value,
                min: -12,
                max: 12,
                divisions: 48,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: const TextStyle(
            fontSize: 9,
            letterSpacing: 0.08,
            color: Pal.faint,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          valStr,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            color: isFlat ? Pal.comment : Pal.accent,
          ),
        ),
      ],
    );
  }
}

// Track que rellena desde el centro (0 dB) hacia el knob.
class _CenteredTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final canvas = context.canvas;
    final trackH = sliderTheme.trackHeight ?? 4;
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    // Rail completo (fondo)
    final railPaint = Paint()
      ..color = sliderTheme.inactiveTrackColor ?? const Color(0xFF0F1413)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(trackH / 2)),
      railPaint,
    );

    // Relleno desde el centro al knob
    final center = rect.center.dx;
    final fillColor = sliderTheme.activeTrackColor ?? Pal.accentDim;
    if (fillColor == Colors.transparent) return;

    final fillLeft = math.min(center, thumbCenter.dx);
    final fillRight = math.max(center, thumbCenter.dx);
    final fillRect = Rect.fromLTRB(fillLeft, rect.top, fillRight, rect.bottom);
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(fillRect, Radius.circular(trackH / 2)),
      fillPaint,
    );

    // Tick en 0 dB (centro)
    final tickPaint = Paint()
      ..color = Pal.borderStrong
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(center, rect.top - 3),
      Offset(center, rect.bottom + 3),
      tickPaint,
    );
  }
}

// ─── _PresetChip ──────────────────────────────────────────────────────────────

class _PresetChip extends StatefulWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  State<_PresetChip> createState() => _PresetChipState();
}

class _PresetChipState extends State<_PresetChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: Pal.durFast,
          curve: Pal.ease,
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: widget.active ? Pal.accent : Pal.inset,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: widget.active
                  ? Pal.accent
                  : _hovered
                      ? Pal.borderStrong
                      : Pal.borderDefault,
            ),
            boxShadow: widget.active ? Pal.glowGreenSm : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.active) ...[
                const Icon(LucideIcons.check, size: 12, color: Pal.greenInk),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: widget.active ? FontWeight.w700 : FontWeight.normal,
                  color: widget.active
                      ? Pal.greenInk
                      : _hovered
                          ? Pal.text
                          : Pal.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── _FooterBtn ───────────────────────────────────────────────────────────────

class _FooterBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _FooterBtn({required this.icon, required this.label, required this.onTap});

  @override
  State<_FooterBtn> createState() => _FooterBtnState();
}

class _FooterBtnState extends State<_FooterBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 13, color: _hovered ? Pal.text : Pal.faint),
            const SizedBox(width: 6),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 12,
                color: _hovered ? Pal.text : Pal.faint,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ─── _ScanlinesPainter — textura terminal ────────────────────────────────────

class _ScanlinesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x09390000) // casi invisible, solo textura
      ..style = PaintingStyle.fill;
    double y = 0;
    while (y < size.height) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
      y += 4;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
