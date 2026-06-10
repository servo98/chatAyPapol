import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Instalación y actualización propias (sin Inno), estilo Discord.
///
/// Modelo en Windows:
///  - Primera instalación: el Setup.exe (SFX 7-zip) extrae la app a una carpeta
///    temporal y lanza `chatpapol.exe --setup`. Esa instancia copia los archivos
///    a %LocalAppData%\ChatPapol, crea accesos directos y abre la app instalada.
///  - Actualización: la app descarga el .zip de la versión nueva (mostrando la
///    pantalla de carga), lo extrae a una temporal y deja un .bat que, tras
///    cerrarse la app, reemplaza los archivos y la relanza.
class Bootstrap {
  static const appName = 'ChatPapol';

  static bool isSetupArg(List<String> args) => args.contains('--setup');

  static String get installDir {
    final local = Platform.environment['LOCALAPPDATA'] ??
        p.join(Platform.environment['USERPROFILE'] ?? 'C:\\', 'AppData', 'Local');
    return p.join(local, appName);
  }

  /// True si la app se está ejecutando FUERA de su carpeta de instalación
  /// (p.ej. recién extraída del .zip en Descargas): toca instalar.
  static bool needsInstall() {
    if (!Platform.isWindows) return false;
    final here = p.canonicalize(_exeDir);
    final installed = p.canonicalize(installDir);
    return here != installed;
  }

  static String get _exeDir => p.dirname(Platform.resolvedExecutable);
  static String get _exeName => p.basename(Platform.resolvedExecutable);

  // ---------------- primera instalación ----------------
  static Future<void> install({
    required void Function(String status, double? progress) onProgress,
  }) async {
    final src = Directory(_exeDir);
    final dst = Directory(installDir);
    onProgress('Preparando…', null);
    if (await dst.exists()) {
      try { await dst.delete(recursive: true); } catch (_) {}
    }
    await dst.create(recursive: true);

    final entries = src.list(recursive: true).where((e) => e is File).cast<File>();
    final files = await entries.toList();
    var done = 0;
    for (final f in files) {
      final rel = p.relative(f.path, from: src.path);
      final out = File(p.join(dst.path, rel));
      await out.parent.create(recursive: true);
      await f.copy(out.path);
      done++;
      onProgress('Instalando…', files.isEmpty ? null : done / files.length);
    }

    onProgress('Creando accesos directos…', 1);
    await _createShortcuts(p.join(dst.path, _exeName));

    onProgress('Abriendo ChatPapol…', 1);
    await Process.start(p.join(dst.path, _exeName), const [],
        mode: ProcessStartMode.detached, workingDirectory: dst.path);
  }

  static Future<void> _createShortcuts(String exePath) async {
    final desktop = p.join(
        Platform.environment['USERPROFILE'] ?? 'C:\\', 'Desktop', '$appName.lnk');
    final startMenu = p.join(
        Platform.environment['APPDATA'] ?? 'C:\\',
        'Microsoft', 'Windows', 'Start Menu', 'Programs', '$appName.lnk');
    final ps = '''
\$ws = New-Object -ComObject WScript.Shell
foreach (\$lnk in @('$desktop','$startMenu')) {
  \$s = \$ws.CreateShortcut(\$lnk)
  \$s.TargetPath = '$exePath'
  \$s.WorkingDirectory = '${p.dirname(exePath)}'
  \$s.IconLocation = '$exePath,0'
  \$s.Save()
}
''';
    try {
      await Process.run('powershell.exe',
          ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps]);
    } catch (_) {/* accesos directos son best-effort */}
  }

  // ---------------- actualización ----------------
  /// Descarga el zip de la versión nueva con progreso, lo verifica y lo extrae
  /// a una carpeta temporal. Devuelve esa carpeta.
  static Future<Directory> downloadAndExtract(
    String url,
    String sha256hex, {
    required void Function(String status, double? progress) onProgress,
  }) async {
    onProgress('Descargando actualización…', 0);
    final req = http.Request('GET', Uri.parse(url));
    final res = await req.send();
    if (res.statusCode != 200) {
      throw Exception('Descarga fallida (${res.statusCode})');
    }
    final total = res.contentLength ?? 0;
    final bytes = <int>[];
    var received = 0;
    await for (final chunk in res.stream) {
      bytes.addAll(chunk);
      received += chunk.length;
      onProgress('Descargando actualización…',
          total > 0 ? received / total : null);
    }
    if (sha256hex.isNotEmpty &&
        sha256.convert(bytes).toString() != sha256hex) {
      throw Exception('Checksum inválido: descarga corrupta');
    }

    onProgress('Instalando…', null);
    final tmp = await Directory.systemTemp.createTemp('chatpapol-update-');
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive) {
      final outPath = p.join(tmp.path, entry.name);
      if (entry.isFile) {
        final f = File(outPath);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    return tmp;
  }

  /// Borra restos `*.old` de actualizaciones anteriores. Mejor esfuerzo:
  /// si la instancia vieja sigue cerrándose, lo que quede se borra en el
  /// siguiente arranque o update.
  static Future<void> cleanupOldFiles() async {
    if (!Platform.isWindows) return;
    try {
      final files = await Directory(_exeDir)
          .list(recursive: true)
          .where((e) => e is File && e.path.endsWith('.old'))
          .cast<File>()
          .toList();
      for (final f in files) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Reemplaza la instalación actual con [newFiles] y relanza la app, todo
  /// dentro del proceso (sin bat ni ayudantes, estilo Discord/Squirrel):
  /// Windows no deja SOBRESCRIBIR binarios en uso, pero sí RENOMBRARLOS.
  /// Apartamos lo actual a `*.old`, copiamos lo nuevo encima y relanzamos;
  /// la instancia nueva limpia los `.old` al arrancar ([cleanupOldFiles]).
  static Future<void> applyAndRestart(Directory newFiles) async {
    final target = _exeDir;
    final exe = Platform.resolvedExecutable;
    if (Platform.isWindows) {
      final current = await Directory(target)
          .list(recursive: true)
          .where((e) => e is File && !e.path.endsWith('.old'))
          .cast<File>()
          .toList();
      for (final f in current) {
        try {
          await f.delete(); // los que no están en uso salen directo
        } catch (_) {
          final old = File('${f.path}.old');
          try {
            if (await old.exists()) await old.delete();
          } catch (_) {}
          await f.rename(old.path);
        }
      }
      final incoming = await newFiles
          .list(recursive: true)
          .where((e) => e is File)
          .cast<File>()
          .toList();
      for (final f in incoming) {
        final out = File(p.join(target, p.relative(f.path, from: newFiles.path)));
        await out.parent.create(recursive: true);
        await f.copy(out.path);
      }
      try {
        await newFiles.delete(recursive: true);
      } catch (_) {}
      await Process.start(exe, const [],
          mode: ProcessStartMode.detached, workingDirectory: target);
      exit(0);
    } else {
      // Linux/macOS: el AppImage se reemplaza a sí mismo (ver Updater).
      throw UnsupportedError('applyAndRestart solo Windows');
    }
  }
}
