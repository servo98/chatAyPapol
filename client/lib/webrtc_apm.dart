import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Puente al código nativo del fork de flutter_webrtc para el post-procesado de
/// captura (RNNoise vía RTCAudioProcessing::SetCapturePostProcessing). El APM es
/// GLOBAL del factory, así que un solo set sobrevive a reinicios de track.
class WebrtcApm {
  static const _ch = MethodChannel('FlutterWebRTC.Method');

  /// Activa/desactiva RNNoise como supresor de ruido del micro. No-op si el
  /// nativo no soporta el método (build sin el fork).
  static Future<void> setRnnoise(bool enabled) async {
    try {
      await _ch.invokeMethod('setCapturePostProcessing', {'enabled': enabled});
    } catch (_) {/* build viejo / plataforma sin soporte */}
  }

  /// Aplica/actualiza la cadena de efectos de voz (voicefx) en el mismo capture
  /// post-processing. [spec] es la serialización compacta de VoiceFxEngine
  /// ("wet;gain;type,bypass,pid=val&...|..."). No-op si el nativo no lo soporta.
  static Future<void> setVoiceFx(bool enabled, String spec) async {
    try {
      await _ch.invokeMethod('setVoiceFx', {'enabled': enabled, 'spec': spec});
    } catch (_) {/* build sin voicefx / plataforma sin soporte */}
  }

  /// Monitor local ("escucharme"): reproduce el micro YA PROCESADO (RNNoise +
  /// efectos) en los altavoces locales, para probar los efectos uno mismo. Solo
  /// suena mientras hay captura activa (p.ej. dentro de un canal de voz) y solo
  /// en Windows por ahora. Usar AURICULARES (si no, eco). No-op si no soportado.
  static Future<void> setVoiceMonitor(bool enabled) async {
    try {
      await _ch.invokeMethod('setVoiceMonitor', {'enabled': enabled});
    } catch (_) {/* build sin soporte de monitor */}
  }

  /// Boost de captura (volumen de entrada) del path 48k: multiplicador lineal
  /// 0..3 (1.0 = sin cambio). Reemplaza al AGC siempre-on. No-op si no soportado.
  static Future<void> setInputGain(double gain) async {
    try {
      await _ch.invokeMethod('setInputGain', {'gain': gain});
    } catch (_) {/* build sin soporte */}
  }

  /// Nivel del supresor de ruido ESPECTRAL propio (Wiener+MCRA) del path 48k:
  /// 0=off, 1=estándar, 2=fuerte. Limpia el ruido durante el habla sin agachar
  /// la voz (a diferencia del viejo gate). No-op si no soportado.
  static Future<void> setNsLevel(int level) async {
    try {
      await _ch.invokeMethod('setNsLevel', {'level': level});
    } catch (_) {/* build sin soporte */}
  }

  // === [chatpapol 48k] micro kCustom fullband (sin APM → sin downsample 16k) ===

  /// Crea una pista de audio kCustom (Stage 1) a la que el capturador nativo
  /// inyecta PCM a 48k. Devuelve el trackId (o null si el build no lo soporta).
  static Future<String?> createCustomAudioTrack() async {
    try {
      final res = await _ch.invokeMethod('createCustomAudioTrack');
      if (res is Map) {
        final tracks = res['audioTracks'];
        if (tracks is List && tracks.isNotEmpty) {
          final t = tracks.first;
          if (t is Map && t['id'] is String) return t['id'] as String;
        }
        if (res['id'] is String) return res['id'] as String;
      }
    } catch (_) {/* build viejo / sin soporte */}
    return null;
  }

  /// Arranca el capturador de micro a 48k (Stage 2) ligado a [trackId].
  /// [deviceId] vacío = micro por defecto. Sin AEC → AURICULARES.
  static Future<void> startCustomMicCapture(String trackId,
      {String deviceId = ''}) async {
    await _ch.invokeMethod(
        'startCustomMicCapture', {'trackId': trackId, 'deviceId': deviceId});
  }

  static Future<void> stopCustomMicCapture(String trackId) async {
    try {
      await _ch.invokeMethod('stopCustomMicCapture', {'trackId': trackId});
    } catch (_) {}
  }

  // === [chatpapol per-user-eq] EQ individual por track remoto ===

  /// Instala (o actualiza) el sink de EQ en [trackId].
  /// El nativo hace AddSink + SetVolume(0) en esa pista la primera vez, y
  /// solo actualiza los parámetros del biquad en llamadas sucesivas.
  /// [gain] = outputVolume * userVolume, ya calculado en Dart.
  ///
  /// SEGURIDAD: Dart solo llama esto cuando el EQ NO es plano (isFlat == false).
  /// Si el nativo no soporta el método (build sin el fork), el catch es silencioso
  /// y la pista sigue sonando por el playout normal de WebRTC sin cambios.
  ///
  /// INCIERTO: si SetVolume(0) mata el PCM que ve AddSink en m144. Verificar
  /// en el primer test (riesgo bloqueante #1 del blueprint).
  static Future<void> setUserEq(
    String? trackId,
    double bassDb,
    double midDb,
    double trebleDb,
    double gain,
  ) async {
    if (trackId == null || trackId.isEmpty) return; // sin pista → no-op
    try {
      await _ch.invokeMethod('setUserEq', {
        'trackId': trackId,
        'bassDb': bassDb,
        'midDb': midDb,
        'trebleDb': trebleDb,
        'gain': gain,
      });
    } catch (_) {/* build sin soporte */}
  }

  /// Quita el sink de EQ de [trackId] y restaura el playout normal de WebRTC
  /// con el volumen previo [restoreVolume] (= outputVolume * userVolume).
  /// ORDEN nativo: RemoveSink → SetVolume(restoreVolume) → destruir sink.
  static Future<void> clearUserEq(
    String? trackId,
    double restoreVolume,
  ) async {
    if (trackId == null || trackId.isEmpty) return; // sin pista → no-op
    try {
      await _ch.invokeMethod('clearUserEq', {
        'trackId': trackId,
        'restoreVolume': restoreVolume,
      });
    } catch (_) {/* build sin soporte */}
  }
}

/// Estado observable del monitor local ("escucharme"). Singleton para que la UI
/// lo refleje aunque el popover de efectos se cierre y reabra. Solo suena
/// mientras hay captura de micro activa (p.ej. dentro de un canal de voz).
class VoiceMonitor extends ChangeNotifier {
  VoiceMonitor._();
  static final VoiceMonitor instance = VoiceMonitor._();

  bool _on = false;
  bool get on => _on;

  Future<void> set(bool v) async {
    if (_on == v) return;
    _on = v;
    notifyListeners();
    await WebrtcApm.setVoiceMonitor(v);
  }

  Future<void> toggle() => set(!_on);
}
