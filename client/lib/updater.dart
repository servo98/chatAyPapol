import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'api.dart';
import 'version.dart';

class UpdateInfo {
  final String version, url, notes, sha256;
  UpdateInfo.fromJson(Map<String, dynamic> j)
      : version = j['version'],
        url = j['url'],
        notes = j['notes'] ?? '',
        sha256 = j['sha256'] ?? '';
}

bool _newer(String a, String b) {
  // a > b en semver simple x.y.z
  final pa = a.split('.').map(int.parse).toList();
  final pb = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i] > pb[i];
  }
  return false;
}

class Updater {
  /// Devuelve info si hay una versión más nueva publicada en el server.
  static Future<UpdateInfo?> check(Api api) async {
    final platform = Platform.isWindows
        ? 'windows'
        : Platform.isLinux
            ? 'linux'
            : 'macos';
    try {
      final r = await api.get('/api/updates/$platform');
      final info = UpdateInfo.fromJson(r);
      return _newer(info.version, appVersion) ? info : null;
    } catch (_) {
      return null; // sin releases o sin red: silencio
    }
  }

  /// Descarga, verifica SHA-256 y aplica la actualización (relanza la app).
  static Future<void> apply(Api api, UpdateInfo info) async {
    final res = await http.get(Uri.parse(api.fileUrl(info.url)));
    if (res.statusCode != 200) throw Exception('Descarga fallida (${res.statusCode})');
    final bytes = res.bodyBytes;
    if (info.sha256.isNotEmpty && sha256.convert(bytes).toString() != info.sha256) {
      throw Exception('Checksum inválido: descarga corrupta');
    }

    if (Platform.isWindows) {
      final tmp = await getTemporaryDirectory();
      final f = File('${tmp.path}\\chatpapol-update.exe');
      await f.writeAsBytes(bytes);
      await Process.start(f.path, ['/SILENT', '/CLOSEAPPLICATIONS'],
          mode: ProcessStartMode.detached);
      exit(0);
    }

    if (Platform.isLinux) {
      final appImage = Platform.environment['APPIMAGE'];
      if (appImage != null && appImage.isNotEmpty) {
        // reemplaza el AppImage actual de forma atómica y relanza
        final next = File('$appImage.new');
        await next.writeAsBytes(bytes);
        await Process.run('chmod', ['+x', next.path]);
        await next.rename(appImage);
        await Process.start(appImage, [], mode: ProcessStartMode.detached);
        exit(0);
      }
      // fuera de AppImage: deja el archivo en Descargas y avisa
      final home = Platform.environment['HOME'] ?? '/tmp';
      final f = File('$home/chatpapol-${info.version}.AppImage');
      await f.writeAsBytes(bytes);
      await Process.run('chmod', ['+x', f.path]);
      throw Exception('Descargado en ${f.path} — ejecútalo para actualizar');
    }

    throw Exception('Actualización automática no soportada en esta plataforma');
  }
}
