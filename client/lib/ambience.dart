import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// Un ambiente del catálogo (bundleado en assets/ambience/).
class AmbienceDef {
  final String id, name, file, category;
  final String? emoji;
  const AmbienceDef(this.id, this.name, this.file, this.category, this.emoji);
}

/// Reproductor de AMBIENTE de sala: una cama de sonido compartida por todo el
/// canal de voz, reproducida LOCALMENTE (NO por WebRTC) y sincronizada vía el
/// timestamp del server (ver [AmbienceState] y server/src/gateway.ts).
///
/// El clip vive bundleado (AssetSource) o, si el dueño dejó un pack distinto, se
/// sustituye con los mismos nombres. La sincronía es aproximada (usa el reloj
/// local como proxy del reloj del server): para una cama de fondo en loop es de
/// sobra; no buscamos sample-accuracy.
class AmbienceService extends ChangeNotifier {
  AmbienceService._();
  static final AmbienceService instance = AmbienceService._();

  // Reproductor propio en loop, independiente de SFX y de la voz.
  final AudioPlayer _player = AudioPlayer(playerId: 'chatpapol-ambience');

  final List<AmbienceDef> _catalog = [];
  static const _volumeKey = 'ambience_volume';
  double _volume = 0.6; // canal de volumen PROPIO (no toca la voz)

  // Estado actualmente aplicado al reproductor (para no reiniciar en cada notify).
  String? _curId;
  int _curStartedAt = 0;
  bool _curPaused = false;
  bool _curLoop = true;
  bool _playing = false;
  int _gen = 0; // token anti-carrera entre apply() concurrentes

  bool _inited = false;

  List<AmbienceDef> get catalog => List.unmodifiable(_catalog);
  double get volume => _volume;
  bool get isPlaying => _playing;
  String? get currentId => _playing ? _curId : null;

  AmbienceDef? def(String id) {
    for (final a in _catalog) {
      if (a.id == id) return a;
    }
    return null;
  }

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
    } catch (_) {/* alguna plataforma podría no soportarlo: no es crítico */}

    // Catálogo horneado.
    try {
      final raw = await rootBundle.loadString('assets/ambience_manifest.json');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final ambs = (json['ambiences'] as Map?) ?? const {};
      _catalog.clear();
      ambs.forEach((id, v) {
        if (v is Map && v['file'] is String) {
          _catalog.add(AmbienceDef(
            id as String,
            (v['name'] as String?) ?? id,
            v['file'] as String,
            (v['category'] as String?) ?? '',
            v['emoji'] as String?,
          ));
        }
      });
    } catch (_) {/* sin manifest: catálogo vacío (la feature queda muda) */}

    // Volumen propio persistido.
    try {
      final prefs = await SharedPreferences.getInstance();
      _volume = (prefs.getDouble(_volumeKey) ?? 0.6).clamp(0.0, 1.0);
    } catch (_) {}
  }

  /// Aplica el estado de ambiente del canal al reproductor local.
  ///  - [state] null o [active] false  → silencio (no estoy en el canal, estoy
  ///    ensordecido, o no hay ambiente).
  ///  - reinicia el clip SOLO si cambió el id o el origen del loop (started_at);
  ///    un simple pausar/reanudar no recarga.
  Future<void> apply(AmbienceState? state, {required bool active}) async {
    final gen = ++_gen;
    if (state == null || !active) {
      await _stopInternal();
      return;
    }
    final d = def(state.ambienceId);
    if (d == null) {
      await _stopInternal(); // id desconocido (pack distinto): mejor callar
      return;
    }

    final sameClip = _playing &&
        _curId == state.ambienceId &&
        _curStartedAt == state.startedAt;
    if (sameClip) {
      // mismo clip y mismo origen: solo puede haber cambiado el pausado o el loop.
      if (_curLoop != state.loop) {
        _curLoop = state.loop;
        try {
          await _player
              .setReleaseMode(state.loop ? ReleaseMode.loop : ReleaseMode.release);
        } catch (_) {}
      }
      if (_curPaused != state.paused) {
        _curPaused = state.paused;
        try {
          state.paused ? await _player.pause() : await _player.resume();
        } catch (_) {}
        notifyListeners();
      }
      return;
    }

    // (re)carga: nuevo ambiente o nuevo origen de loop (incluye el resume, que
    // el server marca avanzando started_at).
    try {
      await _player
          .setReleaseMode(state.loop ? ReleaseMode.loop : ReleaseMode.release);
      await _player.setSource(AssetSource(d.file));
      if (gen != _gen) return; // otra llamada nos adelantó
      final dur = (await _player.getDuration()) ?? const Duration(seconds: 10);
      if (gen != _gen) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final refMs = state.paused ? (state.pausedAt ?? state.startedAt) : now;
      final elapsed = (refMs - state.startedAt);
      final lenMs = dur.inMilliseconds <= 0 ? 10000 : dur.inMilliseconds;
      final posMs = ((elapsed % lenMs) + lenMs) % lenMs; // siempre >= 0
      await _player.seek(Duration(milliseconds: posMs));
      await _player.setVolume(_volume);
      await _player.resume();
      if (gen != _gen) return;
      if (state.paused) await _player.pause();
      _curId = state.ambienceId;
      _curStartedAt = state.startedAt;
      _curPaused = state.paused;
      _curLoop = state.loop;
      _playing = true;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('ambience apply(${state.ambienceId}) falló: $e');
    }
  }

  /// Volumen del ambiente (0..1), canal propio. Persistido; se aplica en vivo.
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    notifyListeners();
    try {
      await _player.setVolume(_volume);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_volumeKey, _volume);
    } catch (_) {}
  }

  Future<void> stop() => _stopInternal();

  Future<void> _stopInternal() async {
    if (!_playing && _curId == null) return;
    _playing = false;
    _curId = null;
    _curStartedAt = 0;
    _curPaused = false;
    try {
      await _player.stop();
    } catch (_) {}
    notifyListeners();
  }
}
