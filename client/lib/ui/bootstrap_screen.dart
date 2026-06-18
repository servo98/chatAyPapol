import 'package:flutter/material.dart';
import '../theme.dart';
import '../version.dart';

/// Pantalla de carga branded estilo Discord, compartida por la primera
/// instalación y por las actualizaciones. Muestra logo, estado y progreso.
class BootstrapScreen extends StatelessWidget {
  final String title; // "Instalando ChatPapol" / "Actualizando ChatPapol"
  final String status; // "Descargando…", "Instalando…", "Casi listo…"
  final double? progress; // 0..1, o null = indeterminado
  final String? error;
  final VoidCallback? onRetry;

  const BootstrapScreen({
    super.key,
    required this.title,
    required this.status,
    this.progress,
    this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.1,
            colors: [Pal.bg2, Pal.bg0],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _Logo(),
              const SizedBox(height: 24),
              Text(title,
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800, color: Pal.text)),
              const SizedBox(height: 8),
              if (error == null)
                Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '❯ ',
                        style: TextStyle(color: Pal.accent, fontWeight: FontWeight.w700)),
                    TextSpan(text: status),
                  ]),
                  style: TextStyle(fontSize: 13.5, color: Pal.muted),
                )
              else
                Text('! $error',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Pal.red)),
              const SizedBox(height: 28),
              SizedBox(
                width: 320,
                child: error == null
                    ? Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: progress == null || progress! > 0
                              ? Pal.glowGreenSm
                              : null,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 6,
                            backgroundColor: Pal.inset,
                            valueColor: AlwaysStoppedAnimation(Pal.accent),
                          ),
                        ),
                      )
                    : Center(
                        child: ElevatedButton(
                          onPressed: onRetry,
                          child: const Text('Reintentar'),
                        ),
                      ),
              ),
              if (error == null && progress != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${(progress! * 100).round()}%',
                      style: TextStyle(fontSize: 11.5, color: Pal.faint)),
                ),
              const SizedBox(height: 40),
              Text('ChatPapol',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Pal.faint,
                      letterSpacing: 1)),
              Text('v$appVersion',
                  style: TextStyle(fontSize: 11, color: Pal.faint)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatefulWidget {
  const _Logo();
  @override
  State<_Logo> createState() => _LogoState();
}

class _LogoState extends State<_Logo> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final glow = 0.3 + 0.5 * _c.value;
        return Container(
          width: 92,
          height: 92,
          decoration: BoxDecoration(
            color: Pal.inset,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Pal.borderStrong),
            boxShadow: [
              BoxShadow(
                  color: Pal.accent.withValues(alpha: glow),
                  blurRadius: 32,
                  spreadRadius: 2),
            ],
          ),
          // logomark de la marca: prompt ❯ + cursor parpadeante ▮
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('❯',
                  style: TextStyle(
                      color: Pal.accent, fontSize: 40, height: 1,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 4),
              Opacity(
                opacity: _c.value < 0.5 ? 1 : 0,
                child: Text('▮',
                    style: TextStyle(
                        color: Pal.accent, fontSize: 34, height: 1.05,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        );
      },
    );
  }
}
