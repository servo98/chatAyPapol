import 'dart:io';
import 'package:flutter/material.dart';
import '../api.dart';
import '../installer.dart';
import '../updater.dart';
import 'bootstrap_screen.dart';

/// Lanza la actualización: en Windows muestra la pantalla branded (descarga +
/// swap); en Linux/macOS usa el reemplazo de AppImage existente.
Future<void> startUpdate(BuildContext context, Api api, UpdateInfo update) async {
  if (Platform.isWindows) {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => BootstrapRunner(install: false, api: api, update: update),
    ));
  } else {
    await Updater.apply(api, update);
  }
}

/// Corre la instalación o la actualización mostrando [BootstrapScreen].
class BootstrapRunner extends StatefulWidget {
  final bool install; // true = primera instalación, false = actualización
  final Api? api; // requerido para actualizar
  final UpdateInfo? update;
  const BootstrapRunner({super.key, required this.install, this.api, this.update});

  @override
  State<BootstrapRunner> createState() => _BootstrapRunnerState();
}

class _BootstrapRunnerState extends State<BootstrapRunner> {
  String _status = 'Preparando…';
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  void _set(String status, double? progress) {
    if (mounted) setState(() { _status = status; _progress = progress; });
  }

  Future<void> _run() async {
    if (mounted) setState(() => _error = null);
    try {
      if (widget.install) {
        await Bootstrap.install(onProgress: _set);
        await Future.delayed(const Duration(milliseconds: 400));
        exit(0); // la instancia instalada ya se abrió
      } else {
        // re-chequea contra el server en cada intento: si el manifiesto cambió
        // desde que salió el banner (o tras un Reintentar), usa la URL fresca
        final u = await Updater.check(widget.api!) ?? widget.update!;
        final dir = await Bootstrap.downloadAndExtract(
            widget.api!.fileUrl(u.url), u.sha256, onProgress: _set);
        _set('Reiniciando…', 1);
        await Future.delayed(const Duration(milliseconds: 500));
        await Bootstrap.applyAndRestart(dir); // hace exit(0)
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return BootstrapScreen(
      title: widget.install ? 'Instalando ChatPapol' : 'Actualizando ChatPapol',
      status: _status,
      progress: _progress,
      error: _error,
      onRetry: _run,
    );
  }
}
