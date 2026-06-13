import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'version.dart';

/// Un error capturado, listo para mostrar en el overlay.
class CrashReport {
  final String message;
  final String stack;
  const CrashReport(this.message, this.stack);
}

/// Captura TODO el log de la app (debugPrint) + los errores no atrapados y los
/// persiste a disco línea a línea. La clave: la escritura es síncrona con flush,
/// así que aunque un crash NATIVO mate el proceso de golpe (p. ej. el plugin de
/// WebRTC), la última línea escrita dice dónde murió. Y un error a nivel Dart
/// dispara un banner copiable encima de la app.
///
/// Layout en disco (junto a los datos de la app, carpeta `logs/`):
///   session.log       → la sesión EN CURSO.
///   session-prev.log  → la sesión anterior (si no cerró limpio, ahí está el crash).
class CrashLog {
  CrashLog._();
  static final CrashLog instance = CrashLog._();

  static const _maxLines = 1200;
  static const _cleanMarker = '=== cierre limpio ===';
  // Tope DURO del log en disco: si un error se repite cada frame (p.ej. un
  // "No Overlay widget found" en un build persistente), sin esto el archivo
  // crece sin límite (llegó a 5GB y llenó el disco). Al alcanzarlo, deja de
  // escribir a disco (el ring en memoria sigue para el banner).
  static const _maxDiskBytes = 16 * 1024 * 1024; // 16 MB

  final Queue<String> _lines = Queue<String>();
  int _diskBytes = 0;
  bool _diskCapped = false;
  // Dedupe de errores de framework idénticos consecutivos (no re-loguear el
  // mismo stack cada frame).
  String? _lastFlutterErr;
  int _flutterErrRepeat = 0;
  String _header = 'ChatPapol';
  String _prevSession = '';

  RandomAccessFile? _raf;
  File? _file;
  bool _installed = false;

  /// true si la sesión anterior NO terminó con el marcador de cierre limpio
  /// (probable crash). Se consulta al arrancar para ofrecer copiar esos logs.
  bool previousCrashed = false;

  /// Último error fatal a nivel Dart → dispara el overlay. null = sin crash.
  final ValueNotifier<CrashReport?> fatal = ValueNotifier(null);

  String get _ts {
    final n = DateTime.now();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(n.hour)}:${p(n.minute)}:${p(n.second)}.${p(n.millisecond, 3)}';
  }

  /// Abre el archivo de log, rota la sesión anterior y detecta si crasheó.
  /// Best-effort: si no hay disco, seguimos solo en memoria.
  Future<void> init() async {
    _header =
        'ChatPapol v$appVersion · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    try {
      final dir = await getApplicationSupportDirectory();
      final sep = Platform.pathSeparator;
      final logsDir = Directory('${dir.path}${sep}logs');
      if (!logsDir.existsSync()) logsDir.createSync(recursive: true);
      final cur = File('${logsDir.path}${sep}session.log');
      final prev = File('${logsDir.path}${sep}session-prev.log');
      if (cur.existsSync()) {
        try {
          _prevSession = cur.readAsStringSync();
          // ¿la sesión anterior tenía más que la cabecera y NO cerró limpio?
          final body = _prevSession.trim();
          previousCrashed = body.isNotEmpty &&
              body.split('\n').length > 1 &&
              !_prevSession.contains(_cleanMarker);
          cur.copySync(prev.path);
        } catch (_) {}
      }
      cur.writeAsStringSync('=== $_header ===\n');
      _raf = cur.openSync(mode: FileMode.writeOnlyAppend);
      _file = cur;
    } catch (_) {
      // sin disco: el ring en memoria sigue sirviendo para copiar en caliente.
    }
  }

  /// Añade una línea al log (memoria + disco con flush inmediato).
  void record(String line) {
    final entry = '$_ts $line';
    _lines.addLast(entry);
    while (_lines.length > _maxLines) {
      _lines.removeFirst();
    }
    final raf = _raf;
    if (raf != null && !_diskCapped) {
      try {
        final data = '$entry\n';
        raf.writeStringSync(data);
        raf.flushSync();
        _diskBytes += data.length;
        if (_diskBytes >= _maxDiskBytes) {
          _diskCapped = true;
          raf.writeStringSync(
              '=== log truncado: tope de ${_maxDiskBytes ~/ (1024 * 1024)}MB '
              'alcanzado (probable error en bucle) ===\n');
          raf.flushSync();
        }
      } catch (_) {}
    }
  }

  /// Engancha debugPrint y los manejadores globales de error. Idempotente.
  /// Llamar UNA vez, temprano en main(), dentro del mismo runZonedGuarded.
  void install() {
    if (_installed) return;
    _installed = true;

    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) record(message);
      original(message, wrapWidth: wrapWidth);
    };

    // Errores del framework (build/layout/gestos). Se registran SIEMPRE y se
    // muestran en consola; además levantan el banner para que se vean en vivo.
    FlutterError.onError = (FlutterErrorDetails details) {
      final msg = details.exceptionAsString();
      // Dedupe: si es el MISMO error que el anterior (error de build persistente
      // que se repite cada frame), no re-loguear su stack en bucle. Cada 200
      // repeticiones deja una nota, y nada más.
      if (msg == _lastFlutterErr) {
        _flutterErrRepeat++;
        if (_flutterErrRepeat % 200 == 0) {
          record('FLUTTER ERROR (repetido ${_flutterErrRepeat}x): $msg');
        }
        return;
      }
      _lastFlutterErr = msg;
      _flutterErrRepeat = 0;
      record('FLUTTER ERROR: $msg');
      final st = details.stack;
      if (st != null) record(st.toString());
      FlutterError.presentError(details);
      _raise(msg, st);
    };

    // Errores asíncronos no atrapados que escapan del árbol de widgets.
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      reportError(error, stack, fatal: true);
      return true; // manejado: no tumbar el isolate
    };
  }

  /// Registra un error y, si [fatal], levanta el banner copiable.
  void reportError(Object error, StackTrace? stack, {bool fatal = false}) {
    record('ERROR: $error');
    if (stack != null) record(stack.toString());
    if (fatal) _raise(error.toString(), stack);
  }

  void _raise(String message, StackTrace? stack) {
    fatal.value = CrashReport(message, stack?.toString() ?? '');
  }

  /// Cierra el banner (no borra los logs).
  void dismiss() => fatal.value = null;

  /// Marca esta sesión como cerrada limpiamente: si la próxima vez NO aparece
  /// este marcador, sabremos que crasheó. Llamar al cerrar la ventana.
  void markCleanShutdown() {
    record(_cleanMarker);
    try {
      _raf?.flushSync();
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
  }

  /// Volcado completo y copiable: cabecera + sesión anterior (si crasheó) +
  /// sesión actual. Esto es lo que va al portapapeles.
  String dumpText() {
    final b = StringBuffer()..writeln('=== $_header ===');
    if (previousCrashed) {
      b
        ..writeln()
        ..writeln('--- SESIÓN ANTERIOR (cierre inesperado / posible crash) ---')
        ..writeln(_prevSession.trimRight())
        ..writeln('--- fin sesión anterior ---');
    }
    b
      ..writeln()
      ..writeln('--- SESIÓN ACTUAL ---')
      ..writeln(_lines.join('\n'));
    return b.toString();
  }

  /// Ruta del archivo de log (para mostrarla en la UI). null si no hay disco.
  String? get filePath => _file?.path;
}
