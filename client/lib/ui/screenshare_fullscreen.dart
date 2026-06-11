import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart'
    show VideoTrack, VideoTrackRenderer, VideoViewFit;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

import '../theme.dart';
import '../voice.dart';

/// Slider de volumen reutilizable (0..2.0). Mismo cuerpo que el menú de
/// volumen del panel de voz, extraído para reusarlo en el modo pantalla
/// completa del screenshare.
class VolumeSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final Color color;
  final double width;
  const VolumeSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.color = Pal.accent,
    this.width = 200,
  });

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(value == 0 ? LucideIcons.volumeX : LucideIcons.volume2,
          size: 18, color: Pal.muted),
      SizedBox(
        width: width,
        child: Slider(
          value: value.clamp(0.0, 2.0),
          max: 2.0,
          divisions: 40,
          activeColor: color,
          label: '${(value * 100).round()}%',
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 44,
        child: Text('${(value * 100).round()}%',
            style: const TextStyle(fontSize: 12, color: Pal.muted)),
      ),
    ]);
  }
}

/// Pantalla completa de un screenshare remoto. Fondo negro, video a tamaño
/// completo (contain). Barra superior auto-ocultable con el nombre del que
/// comparte, el volumen del audio del screenshare de ese identity y un botón
/// para salir. Sale con X, doble-clic sobre el video o tecla Esc.
class ScreenShareFullscreen extends StatefulWidget {
  final VideoTrack track;
  final String identity;
  final String? name;
  final VoiceManager voice;
  const ScreenShareFullscreen({
    super.key,
    required this.track,
    required this.identity,
    this.name,
    required this.voice,
  });

  @override
  State<ScreenShareFullscreen> createState() => _ScreenShareFullscreenState();
}

class _ScreenShareFullscreenState extends State<ScreenShareFullscreen> {
  bool _barVisible = true;

  @override
  void initState() {
    super.initState();
    // ocultar la titlebar y ocupar toda la ventana
    windowManager.setFullScreen(true);
  }

  Future<void> _exit() async {
    // restaurar la ventana ANTES de volver para que no quede en fullscreen
    await windowManager.setFullScreen(false);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    // por si se sale por gesto de sistema sin pasar por _exit
    windowManager.setFullScreen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.name ?? widget.identity;
    return Focus(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _exit,
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            onHover: (_) {
              if (!_barVisible) setState(() => _barVisible = true);
            },
            child: Stack(children: [
              // video a pantalla completa; doble-clic = salir
              Positioned.fill(
                child: GestureDetector(
                  onDoubleTap: _exit,
                  onTap: () => setState(() => _barVisible = !_barVisible),
                  child: ColoredBox(
                    color: Colors.black,
                    child: VideoTrackRenderer(widget.track,
                        fit: VideoViewFit.contain),
                  ),
                ),
              ),
              // barra superior auto-ocultable
              AnimatedPositioned(
                duration: const Duration(milliseconds: 150),
                left: 0,
                right: 0,
                top: _barVisible ? 0 : -72,
                child: ListenableBuilder(
                  listenable: widget.voice,
                  builder: (ctx, _) => Container(
                    height: 64,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.85),
                          Colors.black.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                    child: Row(children: [
                      const Icon(LucideIcons.monitor,
                          size: 18, color: Pal.green),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Compartiendo: $who',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                      ),
                      VolumeSlider(
                        value: widget.voice.shareVolume(widget.identity),
                        onChanged: (v) =>
                            widget.voice.setShareVolume(widget.identity, v),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Salir de pantalla completa (Esc)',
                        icon: const Icon(LucideIcons.x, size: 20),
                        onPressed: _exit,
                      ),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
