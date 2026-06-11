import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// Acciones de la app con sonido asociado. El nombre del enum (.name) es la
/// CLAVE estable que se usa en el manifest horneado y en los overrides locales.
enum UiSound {
  messageReceived,
  mention,
  voiceUserJoin,
  voiceUserLeave,
  selfMute,
  selfUnmute,
  selfDeafen,
  selfUndeafen,
  connected,
  disconnected,
}

/// Servicio de efectos de sonido de UI (independiente del audio de voz/LiveKit).
///
/// Dos orígenes de sonido, en este orden de prioridad al reproducir:
///  1. override LOCAL del dueño (ruta absoluta a disco, vía Sound Lab) →
///     [DeviceFileSource]. Solo existe en la máquina del dueño.
///  2. sonido HORNEADO en el build (assets/sfx/...) declarado en
///     assets/sfx_manifest.json → [AssetSource].
/// Si no hay ninguno, la acción es muda (no-op).
class SfxService {
  SfxService._();
  static final SfxService instance = SfxService._();

  /// Si true (p.ej. estás ensordecido), [play] no suena.
  bool muted = false;

  // Reproductor propio, distinto del de voice.dart.
  final AudioPlayer _player = AudioPlayer(playerId: 'chatpapol-sfx');
  // Reproductor del botón ▶ de preview del lab (no pisa el de play()).
  final AudioPlayer _previewPlayer = AudioPlayer(playerId: 'chatpapol-sfx-preview');

  // accionNombre -> ruta relativa de asset horneado (p.ej. 'sfx/mention.wav').
  final Map<String, String> _baked = {};
  // accionNombre -> ruta ABSOLUTA en disco (override local del dueño).
  final Map<String, String> _overrides = {};

  static const _overridesKey = 'sfx_overrides';

  bool _inited = false;

  Future<void> init() async {
    if (_inited) return;
    _inited = true;

    // SFX cortos: baja latencia, y al terminar libera el recurso (no loop).
    try {
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setPlayerMode(PlayerMode.lowLatency);
      await _previewPlayer.setReleaseMode(ReleaseMode.stop);
      await _previewPlayer.setPlayerMode(PlayerMode.lowLatency);
    } catch (_) {/* algunas plataformas no soportan lowLatency: no es crítico */}

    // (a) manifest horneado, si el build lo incluye.
    try {
      final raw = await rootBundle.loadString('assets/sfx_manifest.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final sounds = (json['sounds'] as Map?) ?? const {};
      _baked.clear();
      sounds.forEach((k, v) {
        if (v is String && v.isNotEmpty) _baked[k] = v;
      });
    } catch (_) {/* no horneado: queda vacío */}

    // (b) overrides locales del dueño.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_overridesKey);
      if (raw != null && raw.isNotEmpty) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _overrides.clear();
        json.forEach((k, v) {
          if (v is String && v.isNotEmpty) _overrides[k] = v;
        });
      }
    } catch (_) {/* sin overrides: queda vacío */}
  }

  /// Fire-and-forget: resuelve la fuente y reproduce sin await; traga errores.
  void play(UiSound s) {
    if (muted) return;
    final name = s.name;
    final abs = _overrides[name];
    final baked = _baked[name];
    Source? source;
    if (abs != null && abs.isNotEmpty) {
      source = DeviceFileSource(abs);
    } else if (baked != null && baked.isNotEmpty) {
      source = AssetSource(baked);
    } else {
      return; // acción sin sonido asignado
    }
    // sin await: no bloquea el hilo de UI ni propaga errores.
    _player.stop().then((_) => _player.play(source!)).catchError((e, st) {
      if (kDebugMode) debugPrint('sfx play($name) falló: $e');
    });
  }

  // ───────── API del Sound Lab (solo dueño) ─────────

  /// Ruta asignada a la acción (override local o, si no, baked) o null.
  String? pathFor(UiSound s) {
    final name = s.name;
    return _overrides[name] ?? _baked[name];
  }

  /// Asigna un archivo del disco a la acción y persiste el override.
  Future<void> assign(UiSound s, String absolutePath) async {
    _overrides[s.name] = absolutePath;
    await _persistOverrides();
  }

  /// Quita el override local de la acción.
  Future<void> clear(UiSound s) async {
    _overrides.remove(s.name);
    await _persistOverrides();
  }

  /// Reproduce un archivo suelto del disco (botón ▶ del lab).
  Future<void> preview(String absolutePath) async {
    try {
      await _previewPlayer.stop();
      await _previewPlayer.play(DeviceFileSource(absolutePath));
    } catch (e) {
      if (kDebugMode) debugPrint('sfx preview($absolutePath) falló: $e');
    }
  }

  /// Serializa el manifest a JSON con indentación: para cada UiSound, la ruta
  /// elegida (override o baked) o null. Esto es lo que el dueño commiteará.
  Future<String> exportManifestJson() async {
    final sounds = <String, String?>{};
    for (final s in UiSound.values) {
      sounds[s.name] = _overrides[s.name] ?? _baked[s.name];
    }
    final manifest = {'version': 1, 'sounds': sounds};
    return const JsonEncoder.withIndent('  ').convert(manifest);
  }

  Future<void> _persistOverrides() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_overridesKey, jsonEncode(_overrides));
    } catch (e) {
      if (kDebugMode) debugPrint('sfx persistir overrides falló: $e');
    }
  }
}
