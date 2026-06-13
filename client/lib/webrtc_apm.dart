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
