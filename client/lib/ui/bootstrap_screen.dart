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
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF13111F), Color(0xFF0D0E13), Color(0xFF101726)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _Logo(),
              const SizedBox(height: 24),
              Text(title,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800, color: Pal.text)),
              const SizedBox(height: 8),
              if (error == null)
                Text(status,
                    style: const TextStyle(fontSize: 13.5, color: Pal.muted))
              else
                Text(error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Pal.red)),
              const SizedBox(height: 28),
              SizedBox(
                width: 320,
                child: error == null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 7,
                          backgroundColor: Pal.bg3,
                          valueColor: const AlwaysStoppedAnimation(Pal.accent),
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
                      style: const TextStyle(fontSize: 11.5, color: Pal.faint)),
                ),
              const SizedBox(height: 40),
              const Text('ChatPapol',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Pal.faint,
                      letterSpacing: 1)),
              Text('v$appVersion',
                  style: const TextStyle(fontSize: 11, color: Pal.faint)),
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
            color: Pal.bg1,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                  color: Pal.accent.withValues(alpha: glow),
                  blurRadius: 32,
                  spreadRadius: 2),
            ],
          ),
          child: const Icon(Icons.forum_rounded, color: Pal.accent, size: 48),
        );
      },
    );
  }
}
