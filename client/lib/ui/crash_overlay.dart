import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../crash_log.dart';
import '../theme.dart';

/// Envuelve el contenido de la app y muestra, ENCIMA de todo, un banner rojo
/// copiable cuando:
///   • salta un error a nivel Dart en vivo (CrashLog.fatal), o
///   • al arrancar se detecta que la sesión anterior se cerró sin avisar
///     (probable crash nativo — el log de esa sesión sigue en disco).
///
/// El banner es compacto y descartable: no bloquea la app. "Copiar logs" copia
/// el volcado completo (sesión anterior + actual) al portapapeles para pasarlo.
class CrashOverlay extends StatefulWidget {
  final Widget child;
  const CrashOverlay({super.key, required this.child});

  @override
  State<CrashOverlay> createState() => _CrashOverlayState();
}

class _CrashOverlayState extends State<CrashOverlay> {
  late bool _showPrev = CrashLog.instance.previousCrashed;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CrashReport?>(
      valueListenable: CrashLog.instance.fatal,
      builder: (ctx, live, _) {
        final show = live != null || _showPrev;
        return Stack(
          children: [
            widget.child,
            if (show)
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: _CrashBanner(
                  report: live,
                  // título distinto según el origen del aviso.
                  fromPreviousSession: live == null,
                  onClose: () {
                    if (live != null) CrashLog.instance.dismiss();
                    setState(() => _showPrev = false);
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CrashBanner extends StatefulWidget {
  final CrashReport? report;
  final bool fromPreviousSession;
  final VoidCallback onClose;
  const _CrashBanner({
    required this.report,
    required this.fromPreviousSession,
    required this.onClose,
  });

  @override
  State<_CrashBanner> createState() => _CrashBannerState();
}

class _CrashBannerState extends State<_CrashBanner> {
  bool _expanded = false;
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: CrashLog.instance.dumpText()));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final title = widget.fromPreviousSession
        ? 'la sesión anterior se cerró de golpe'
        : 'algo crasheó';
    final detail = r != null
        ? '${r.message}\n\n${r.stack}'.trim()
        : CrashLog.instance.dumpText();

    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        decoration: BoxDecoration(
          color: Pal.bg0,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Pal.red),
          boxShadow: const [
            BoxShadow(color: Color(0x66FF4D4D), blurRadius: 16, spreadRadius: -4),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(LucideIcons.triangleAlert, color: Pal.red, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Pal.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFamily: Pal.fontMono,
                      fontFamilyFallback: Pal.monoFallback,
                    ),
                  ),
                ),
                IconButton(
                  // SIN tooltip: este banner se monta FUERA del Overlay del
                  // Navigator (envuelve toda la app), y Tooltip/SelectableText
                  // necesitan un Overlay ancestro → lanzarían "No Overlay widget
                  // found" cada frame (llenó el log a 5GB). Por eso aquí no se
                  // usan widgets que requieran Overlay.
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(LucideIcons.x, color: Pal.muted),
                  onPressed: widget.onClose,
                ),
              ],
            ),
            if (r != null && !_expanded)
              Padding(
                padding: const EdgeInsets.only(left: 24, top: 2, right: 8),
                child: Text(
                  r.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Pal.muted,
                    fontSize: 12,
                    fontFamily: Pal.fontMono,
                    fontFamilyFallback: Pal.monoFallback,
                  ),
                ),
              ),
            if (_expanded)
              Container(
                margin: const EdgeInsets.only(top: 8),
                constraints: const BoxConstraints(maxHeight: 280),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Pal.inset,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Pal.borderDefault),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    detail,
                    style: const TextStyle(
                      color: Pal.faint,
                      fontSize: 11.5,
                      height: 1.4,
                      fontFamily: Pal.fontMono,
                      fontFamilyFallback: Pal.monoFallback,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _copy,
                    icon: Icon(_copied ? LucideIcons.check : LucideIcons.copy,
                        size: 14),
                    label: Text(_copied ? 'copiado ✓' : 'copiar logs'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(_expanded ? 'ocultar' : 'detalles'),
                  ),
                  const Spacer(),
                  if (CrashLog.instance.filePath != null && _expanded)
                    Flexible(
                      child: Text(
                        CrashLog.instance.filePath!,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Pal.comment,
                          fontSize: 10.5,
                          fontFamily: Pal.fontMono,
                          fontFamilyFallback: Pal.monoFallback,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
