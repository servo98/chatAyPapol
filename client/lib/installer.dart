import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'crash_log.dart';
import 'version.dart';

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
  static const publisher = 'aypapol';

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

  static String get _desktopLnk => p.join(
      Platform.environment['USERPROFILE'] ?? 'C:\\', 'Desktop', '$appName.lnk');
  static String get _startMenuLnk => p.join(
      Platform.environment['APPDATA'] ?? 'C:\\',
      'Microsoft', 'Windows', 'Start Menu', 'Programs', '$appName.lnk');

  // ---------------- primera instalación ----------------
  static Future<void> install({
    required void Function(String status, double? progress) onProgress,
  }) async {
    final src = Directory(_exeDir);
    final dst = Directory(installDir);
    onProgress('preparando…', null);
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

    onProgress('creando accesos directos…', 1);
    final installedExe = p.join(dst.path, _exeName);
    await _createShortcuts(installedExe);
    // Registra "Desinstalar" apuntando al exe YA instalado (aquí
    // resolvedExecutable es el binario temporal del Setup, no sirve).
    await ensureUninstallEntry(exePath: installedExe);

    onProgress('abriendo ChatPapol…', 1);
    await Process.start(p.join(dst.path, _exeName), const [],
        mode: ProcessStartMode.detached, workingDirectory: dst.path);
  }

  static Future<void> _createShortcuts(String exePath) async {
    final desktop = _desktopLnk;
    final startMenu = _startMenuLnk;
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

  // ---------------- registro de desinstalación ----------------
  /// Escribe (o actualiza) la entrada "Desinstalar" por-usuario para que
  /// ChatPapol salga en *Aplicaciones y características* con un uninstaller.
  /// Idempotente y barato: se llama en CADA arranque de la app INSTALADA, así
  /// las instalaciones viejas (sin esta clave) se auto-reparan al actualizar.
  ///
  /// Vía PowerShell (Set-ItemProperty): `reg import` reporta éxito pero NO
  /// escribe nada de forma fiable, y `reg add` se traba con las comillas de la
  /// UninstallString. PowerShell con strings de comilla simple es literal y
  /// robusto (mismo mecanismo que [_createShortcuts]). [exePath] permite apuntar
  /// al exe YA instalado durante la instalación (cuando resolvedExecutable aún
  /// es el binario temporal). Best-effort: nunca lanza.
  static Future<void> ensureUninstallEntry({String? exePath}) async {
    if (!Platform.isWindows) return;
    try {
      final exe = exePath ?? Platform.resolvedExecutable;
      String q(String s) => s.replaceAll("'", "''"); // escape comilla simple PS
      final ps = '''
\$k = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$appName'
New-Item -Path \$k -Force | Out-Null
Set-ItemProperty -Path \$k -Name DisplayName -Value '${q(appName)}'
Set-ItemProperty -Path \$k -Name DisplayVersion -Value '${q(appVersion)}'
Set-ItemProperty -Path \$k -Name DisplayIcon -Value '${q(exe)}'
Set-ItemProperty -Path \$k -Name Publisher -Value '${q(publisher)}'
Set-ItemProperty -Path \$k -Name InstallLocation -Value '${q(installDir)}'
Set-ItemProperty -Path \$k -Name UninstallString -Value '"${q(exe)}" --uninstall'
Set-ItemProperty -Path \$k -Name NoModify -Type DWord -Value 1
Set-ItemProperty -Path \$k -Name NoRepair -Type DWord -Value 1
''';
      await Process.run('powershell.exe',
          ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', ps]);
    } catch (_) {/* registrar es best-effort: la app funciona igual */}
  }

  /// Desinstala ChatPapol (lo invoca Windows con la UninstallString
  /// `"<exe>" --uninstall`): borra la clave de registro y los accesos directos,
  /// y programa el borrado de la carpeta de instalación tras salir (un exe en
  /// uso no puede autoborrarse). NO toca los datos de usuario (ajustes/logs en
  /// %APPDATA%\dev.papol). Hace exit(0) al final.
  static Future<void> uninstall() async {
    if (!Platform.isWindows) {
      exit(0);
    }
    // 1) clave de registro (PowerShell: consistente con el registro)
    try {
      await Process.run('powershell.exe', [
        '-NoProfile', '-WindowStyle', 'Hidden', '-Command',
        "Remove-Item -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$appName' -Recurse -Force -ErrorAction SilentlyContinue"
      ]);
    } catch (_) {}
    // 2) accesos directos
    for (final lnk in [_desktopLnk, _startMenuLnk]) {
      try {
        final f = File(lnk);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    // 3) carpeta de instalación: la borra un PowerShell OCULTO y desligado que
    //    espera ~3s a que este proceso cierre (un exe en uso no se autoborra).
    //    Antes usaba `cmd /c ping ...` como sleep, pero abría una ventana de
    //    consola visible con el ping. -WindowStyle Hidden no muestra nada. CWD
    //    fuera de la carpeta para no bloquearla.
    try {
      final dir = installDir;
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile', '-WindowStyle', 'Hidden', '-Command',
          "Start-Sleep -Seconds 3; "
              "Remove-Item -LiteralPath '$dir' -Recurse -Force -ErrorAction SilentlyContinue"
        ],
        mode: ProcessStartMode.detached,
        workingDirectory: Platform.environment['TEMP'] ?? 'C:\\',
      );
    } catch (_) {}
    exit(0);
  }

  // ---------------- actualización ----------------
  /// Descarga el zip de la versión nueva con progreso, lo verifica y lo extrae
  /// a una carpeta temporal. Devuelve esa carpeta.
  static Future<Directory> downloadAndExtract(
    String url,
    String sha256hex, {
    required void Function(String status, double? progress) onProgress,
  }) async {
    onProgress('descargando actualización…', 0);
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
      onProgress('descargando actualización…',
          total > 0 ? received / total : null);
    }
    if (sha256hex.isNotEmpty &&
        sha256.convert(bytes).toString() != sha256hex) {
      throw Exception('Checksum inválido: descarga corrupta');
    }

    onProgress('instalando…', null);
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
      // Cierre INTENCIONAL por update: marca el log como limpio para que el
      // detector de crashes NO muestre el banner de error al reabrir.
      CrashLog.instance.markCleanShutdown();
      await Process.start(exe, const [],
          mode: ProcessStartMode.detached, workingDirectory: target);
      exit(0);
    } else {
      // Linux/macOS: el AppImage se reemplaza a sí mismo (ver Updater).
      throw UnsupportedError('applyAndRestart solo Windows');
    }
  }
}
