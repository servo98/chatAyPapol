// gen_sfx.dart — BAKE final de los efectos de sonido de UI.
//
// El Sound Lab (solo en la máquina del dueño) exporta un manifest JSON con la
// RUTA ABSOLUTA del .wav elegido para cada acción:
//   { "version": 1, "sounds": { "mention": "C:\\...\\Casual_3_2.wav", ... } }
//
// Este script copia SOLO esos archivos a client/assets/sfx/<accion>.<ext>,
// escribe client/assets/sfx_manifest.json (rutas RELATIVAS para AssetSource),
// e imprime el bloque de assets que hay que pegar en pubspec.yaml. Así el build
// horneado lleva un puñado de KB en vez de los 48 MB del pack completo.
//
// USO (desde client/):
//   dart run scripts/gen_sfx.dart ../sfx_manifest.json
//   dart run scripts/gen_sfx.dart path/al/manifest.json
// Si no se pasa ruta, busca '../sfx_manifest.json' (lo que escribe el lab por
// defecto, junto a lib/sounds). Tras correrlo: pega el bloque de assets en
// pubspec.yaml, commitea client/assets/sfx/ y client/assets/sfx_manifest.json.

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final manifestPath = args.isNotEmpty ? args[0] : '../sfx_manifest.json';
  final manifestFile = File(manifestPath);
  if (!manifestFile.existsSync()) {
    stderr.writeln('No existe el manifest: $manifestPath');
    stderr.writeln('Exporta primero desde el Sound Lab.');
    exit(1);
  }

  final json = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final sounds = (json['sounds'] as Map?) ?? const {};

  final outDir = Directory('assets/sfx');
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync(recursive: true);

  final baked = <String, String>{}; // accion -> ruta relativa de asset
  var copied = 0, skipped = 0;

  sounds.forEach((accion, src) {
    if (src is! String || src.isEmpty) {
      skipped++;
      return;
    }
    final srcFile = File(src);
    if (!srcFile.existsSync()) {
      stderr.writeln('  ! fuente no encontrada para "$accion": $src');
      skipped++;
      return;
    }
    final ext = _ext(src);
    final destRel = 'sfx/$accion$ext';
    final destFile = File('assets/$destRel');
    srcFile.copySync(destFile.path);
    baked[accion] = destRel;
    copied++;
    stdout.writeln('  ✓ $accion  ←  ${src.split(RegExp(r"[\\/]")).last}');
  });

  // Manifest horneado: rutas RELATIVAS que SfxService carga con AssetSource.
  final bakedManifest = File('assets/sfx_manifest.json');
  bakedManifest.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({'version': 1, 'sounds': baked}));

  stdout.writeln('\nHorneados $copied sonido(s), $skipped sin asignar.');
  stdout.writeln('Escrito: ${bakedManifest.path}');
  stdout.writeln('\n--- Pega esto en pubspec.yaml bajo "flutter:" ---');
  stdout.writeln('  assets:');
  stdout.writeln('    - assets/sfx/');
  stdout.writeln('    - assets/sfx_manifest.json');
}

String _ext(String path) {
  final i = path.lastIndexOf('.');
  return i >= 0 ? path.substring(i) : '.wav';
}
