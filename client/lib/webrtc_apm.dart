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
}
