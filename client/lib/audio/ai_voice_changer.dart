import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:shared_preferences/shared_preferences.dart';

/// ============================================================================
/// AiVoiceChanger — orquestador del cambiador de voz por IA (RVC), OPCIONAL.
///
/// Esto NO es inferencia en tiempo real dentro de la app. La conversión de voz
/// con IA (RVC / w-okada VC Client) corre como proceso EXTERNO (sidecar) que el
/// usuario instala aparte; su salida se enruta a un dispositivo de audio
/// VIRTUAL (VB-Cable en Windows, loopback de PipeWire/Pulse en Linux) y
/// ChatPapol simplemente selecciona ese dispositivo como micrófono
/// (VoiceManager.micDeviceId). Es decir:
///
///   mic físico → [VC Client (proceso externo, modelo RVC)] → cable virtual
///              → ChatPapol (mic = cable virtual) → RNNoise → VoiceFX → encode
///
/// Conclusiones de la investigación que esta clase respeta:
///  - La conversión RVC en tiempo real cuesta cientos de ms; SOLO es usable
///    en hardware capaz: NVIDIA (CUDA) o, en Windows, AMD/Intel vía DirectML.
///  - En CPU puro ronda 200–300 ms de latencia: inutilizable para conversación.
///  - En Linux con AMD (ROCm) el soporte es inestable: se degrada con honestidad.
///  - No se incluye ningún modelo ni binario: rutas configuradas por el usuario
///    y persistidas en SharedPreferences.
///
/// Sin UI aquí: la pantalla de ajustes (fase de diseño) observa este
/// ChangeNotifier y se gatea con [isAvailableOnThisMachine]/[unavailableReason].
/// Guía de instalación para el usuario final: docs/voice-fx-ai-setup.md.
/// ============================================================================

/// Backend de inferencia detectado en esta máquina.
enum AiBackend {
  /// Plataforma sin ruta viable (p. ej. sin GPU y SO no soportado).
  none,

  /// Solo CPU: técnicamente corre, pero ~200–300 ms de latencia. No recomendado.
  cpu,

  /// GPU NVIDIA (CUDA): el caso bueno, latencia más baja.
  cuda,

  /// Windows con GPU AMD/Intel vía DirectML: latencia media, usable.
  directml,

  /// Linux con AMD (ROCm): soporte frágil para RVC en tiempo real. No recomendado.
  rocm,
}

/// Resultado de la detección de hardware. Las latencias son ESTIMACIONES
/// honestas extremo-a-extremo del sidecar (captura+inferencia+salida), según
/// la investigación; el valor real depende de GPU, modelo y chunk size.
class AiCapability {
  const AiCapability({
    required this.backend,
    required this.expectedLatencyMs,
    required this.isRecommended,
  });

  final AiBackend backend;

  /// Latencia añadida estimada en ms (0 si [backend] == none: no aplica).
  final int expectedLatencyMs;

  /// true solo cuando la experiencia es razonable (cuda / directml).
  final bool isRecommended;

  @override
  String toString() =>
      'AiCapability(${backend.name}, ~${expectedLatencyMs}ms, recommended=$isRecommended)';
}

/// Estado del proceso sidecar.
enum AiVcStatus { stopped, starting, running, error }

/// Dispositivo de entrada de audio candidato (para que la UI liste cables
/// virtuales sin depender directamente de flutter_webrtc).
class AiAudioDevice {
  const AiAudioDevice(this.deviceId, this.label);
  final String deviceId;
  final String label;
}

class AiVoiceChanger extends ChangeNotifier {
  AiVoiceChanger._();

  /// Singleton (mismo patrón que SfxService/VoiceManager).
  static final AiVoiceChanger instance = AiVoiceChanger._();

  // --- Claves de persistencia (SharedPreferences, patrón de voice.dart) -----
  static const _kExe = 'ai_vc_exe';
  static const _kArgs = 'ai_vc_args';
  static const _kInputDevice = 'ai_vc_input_device';
  static const _kOutputDevice = 'ai_vc_output_device';
  static const _kModel = 'ai_vc_model';

  bool _inited = false;
  SharedPreferences? _prefs;

  // --- Capacidad / gating ---------------------------------------------------

  AiCapability _capability = const AiCapability(
    backend: AiBackend.none,
    expectedLatencyMs: 0,
    isRecommended: false,
  );

  AiCapability get capability => _capability;

  /// true si en esta máquina tiene sentido OFRECER la función (experimental).
  /// La UI debe ocultar la sección de IA por completo cuando es false.
  bool get isAvailableOnThisMachine =>
      _capability.backend == AiBackend.cuda ||
      _capability.backend == AiBackend.directml;

  /// Motivo legible (es) de por qué no está disponible; '' si sí lo está.
  String get unavailableReason {
    switch (_capability.backend) {
      case AiBackend.cuda:
      case AiBackend.directml:
        return '';
      case AiBackend.cpu:
        return 'Sin GPU compatible: en CPU la conversión de voz por IA añade '
            '~${_capability.expectedLatencyMs} ms de latencia y no sirve para '
            'conversar en tiempo real.';
      case AiBackend.rocm:
        return 'GPU AMD en Linux (ROCm): el soporte de RVC en tiempo real es '
            'inestable hoy; la función está deshabilitada para evitar una '
            'mala experiencia.';
      case AiBackend.none:
        return 'Esta plataforma no tiene una ruta de aceleración soportada '
            'para conversión de voz por IA.';
    }
  }

  // --- Configuración del sidecar (persistida) -------------------------------

  String _exePath = '';
  String _args = '';
  String _inputDevice = '';
  String _outputDevice = '';
  String _modelPath = '';

  /// Ruta al ejecutable del servidor de conversión (w-okada VC Client o
  /// compatible). El usuario la instala y configura; NUNCA se incluye en la app.
  String get exePath => _exePath;

  /// Argumentos extra (una sola línea; se tokeniza respetando comillas dobles).
  String get args => _args;

  /// Dispositivo de ENTRADA del sidecar = micrófono físico del usuario.
  String get inputDevice => _inputDevice;

  /// Dispositivo de SALIDA del sidecar = cable virtual. ChatPapol debe apuntar
  /// su micrófono (VoiceManager.micDeviceId) al extremo de captura del cable.
  String get outputDevice => _outputDevice;

  /// Ruta al modelo RVC (.pth/.onnx) elegido por el usuario.
  String get modelPath => _modelPath;

  Future<void> setExePath(String v) => _setPref(_kExe, v, () => _exePath = v);
  Future<void> setArgs(String v) => _setPref(_kArgs, v, () => _args = v);
  Future<void> setInputDevice(String v) =>
      _setPref(_kInputDevice, v, () => _inputDevice = v);
  Future<void> setOutputDevice(String v) =>
      _setPref(_kOutputDevice, v, () => _outputDevice = v);
  Future<void> setModelPath(String v) =>
      _setPref(_kModel, v, () => _modelPath = v);

  Future<void> _setPref(String key, String value, void Function() apply) async {
    apply();
    notifyListeners();
    try {
      final p = _prefs ?? await SharedPreferences.getInstance();
      _prefs = p;
      if (value.isEmpty) {
        await p.remove(key);
      } else {
        await p.setString(key, value);
      }
    } catch (_) {/* persistencia best-effort; el estado en memoria ya cambió */}
  }

  // --- Estado del proceso ----------------------------------------------------

  Process? _proc;
  AiVcStatus _status = AiVcStatus.stopped;
  String _lastError = '';
  final List<String> _log = <String>[];
  static const _maxLogLines = 400;

  AiVcStatus get status => _status;
  bool get isRunning => _status == AiVcStatus.running;

  /// Último error de arranque/ejecución ('' si no hay).
  String get lastError => _lastError;

  /// Últimas líneas de stdout/stderr del sidecar (para una vista de log).
  List<String> get log => List.unmodifiable(_log);

  // --- Ciclo de vida ----------------------------------------------------------

  /// Idempotente. Carga configuración persistida y detecta hardware.
  /// Nunca lanza: si algo falla, queda backend=none (función oculta).
  Future<void> init() async {
    if (_inited) return;
    _inited = true;

    try {
      final p = await SharedPreferences.getInstance();
      _prefs = p;
      _exePath = p.getString(_kExe) ?? '';
      _args = p.getString(_kArgs) ?? '';
      _inputDevice = p.getString(_kInputDevice) ?? '';
      _outputDevice = p.getString(_kOutputDevice) ?? '';
      _modelPath = p.getString(_kModel) ?? '';
    } catch (_) {/* sin prefs: defaults vacíos */}

    _capability = await _detectCapability();
    notifyListeners();
  }

  /// Vuelve a detectar hardware (p. ej. tras instalar drivers).
  Future<void> redetect() async {
    _capability = await _detectCapability();
    notifyListeners();
  }

  /// Arranca el sidecar. Devuelve true si quedó corriendo.
  /// No-op (true) si ya corre. No gatea por capability a propósito: si el
  /// usuario fuerza el arranque desde fuera de la UI, es su decisión; la UI
  /// normal solo llega aquí cuando isAvailableOnThisMachine.
  Future<bool> start() async {
    if (_proc != null) return true;

    if (_exePath.isEmpty) {
      _fail('No hay ejecutable configurado (ai_vc_exe). '
          'Ver docs/voice-fx-ai-setup.md.');
      return false;
    }
    if (!File(_exePath).existsSync()) {
      _fail('El ejecutable no existe: $_exePath');
      return false;
    }

    _status = AiVcStatus.starting;
    _lastError = '';
    _log.clear();
    notifyListeners();

    try {
      final argv = _tokenizeArgs(_args);
      // El working dir es la carpeta del exe: los VC Client suelen resolver
      // modelos/configs relativos a sí mismos.
      final proc = await Process.start(
        _exePath,
        argv,
        workingDirectory: File(_exePath).parent.path,
      );
      _proc = proc;

      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => _appendLog('[out] $l'));
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => _appendLog('[err] $l'));

      // Cuando el proceso muere (por stop() o por sí solo), reflejarlo.
      unawaited(proc.exitCode.then((code) {
        final wasRunning = _status == AiVcStatus.running;
        _proc = null;
        if (wasRunning && code != 0) {
          _lastError = 'El proceso terminó con código $code.';
          _status = AiVcStatus.error;
        } else {
          _status = AiVcStatus.stopped;
        }
        _appendLog('[sys] proceso terminado (exit $code)');
        notifyListeners();
      }));

      _status = AiVcStatus.running;
      notifyListeners();
      return true;
    } catch (e) {
      _proc = null;
      _fail('No se pudo lanzar el sidecar: $e');
      return false;
    }
  }

  /// Detiene el sidecar (SIGTERM; SIGKILL si no muere en ~3 s).
  Future<void> stop() async {
    final proc = _proc;
    if (proc == null) {
      if (_status != AiVcStatus.stopped) {
        _status = AiVcStatus.stopped;
        notifyListeners();
      }
      return;
    }
    _appendLog('[sys] deteniendo proceso...');
    proc.kill(ProcessSignal.sigterm);
    try {
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
      try {
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {/* nos rendimos; el listener de exitCode limpiará */}
    } catch (_) {/* ya muerto */}
    // El then() de exitCode pone _proc=null y status=stopped y notifica.
  }

  void _fail(String msg) {
    _lastError = msg;
    _status = AiVcStatus.error;
    _appendLog('[sys] ERROR: $msg');
    notifyListeners();
  }

  void _appendLog(String line) {
    _log.add(line);
    if (_log.length > _maxLogLines) {
      _log.removeRange(0, _log.length - _maxLogLines);
    }
    // No notificamos por cada línea de log para no spamear rebuilds: la UI de
    // log (si existe) puede refrescar con un Timer o al cambiar status.
  }

  @override
  void dispose() {
    // Best-effort: matar el sidecar al cerrar (no esperamos el Future).
    _proc?.kill(ProcessSignal.sigkill);
    _proc = null;
    super.dispose();
  }

  // --- Simulación / etiquetas (para el selector "simula otro backend") --------

  /// Capacidad CANÓNICA de un backend dado (latencias/recomendación honestas,
  /// mismas que usa la detección). No toca el estado real: la UI la usa para
  /// previsualizar "¿y si tuviera este otro backend?".
  static AiCapability capabilityFor(AiBackend b) {
    switch (b) {
      case AiBackend.cuda:
        return const AiCapability(
            backend: AiBackend.cuda, expectedLatencyMs: 120, isRecommended: true);
      case AiBackend.directml:
        return const AiCapability(
            backend: AiBackend.directml, expectedLatencyMs: 200, isRecommended: true);
      case AiBackend.rocm:
        return const AiCapability(
            backend: AiBackend.rocm, expectedLatencyMs: 250, isRecommended: false);
      case AiBackend.cpu:
        return const AiCapability(
            backend: AiBackend.cpu, expectedLatencyMs: 300, isRecommended: false);
      case AiBackend.none:
        return const AiCapability(
            backend: AiBackend.none, expectedLatencyMs: 0, isRecommended: false);
    }
  }

  /// Nombre legible del backend (como en el diseño).
  static String backendLabel(AiBackend b) => switch (b) {
        AiBackend.none => 'Ninguno',
        AiBackend.cpu => 'CPU',
        AiBackend.cuda => 'NVIDIA CUDA',
        AiBackend.directml => 'DirectML (AMD)',
        AiBackend.rocm => 'ROCm (AMD)',
      };

  // --- Detección de hardware ---------------------------------------------------

  Future<AiCapability> _detectCapability() async {
    // 1) NVIDIA en cualquier plataforma: nvidia-smi presente y con exit 0
    //    implica driver funcional → CUDA. El mejor caso (~90–150 ms e2e).
    if (await _commandSucceeds('nvidia-smi', const ['-L'])) {
      return const AiCapability(
        backend: AiBackend.cuda,
        expectedLatencyMs: 120,
        isRecommended: true,
      );
    }

    if (Platform.isWindows) {
      // 2) Windows sin NVIDIA: DirectML viene con DX12, disponible en
      //    cualquier GPU AMD/Intel razonable. Latencia media (~180–250 ms),
      //    usable pero notoria; lo ofrecemos como experimental.
      return const AiCapability(
        backend: AiBackend.directml,
        expectedLatencyMs: 200,
        isRecommended: true,
      );
    }

    if (Platform.isLinux) {
      // 3) Linux AMD: ROCm existe pero el stack RVC en tiempo real sobre ROCm
      //    es frágil (según la investigación). Lo detectamos para informar,
      //    pero NO lo recomendamos ni lo habilitamos.
      if (await _commandSucceeds('rocminfo', const [])) {
        return const AiCapability(
          backend: AiBackend.rocm,
          expectedLatencyMs: 250,
          isRecommended: false,
        );
      }
      // 4) Linux CPU puro: 200–300 ms, inviable para conversación.
      return const AiCapability(
        backend: AiBackend.cpu,
        expectedLatencyMs: 300,
        isRecommended: false,
      );
    }

    // Otras plataformas (macOS pendiente, móvil): sin ruta soportada en v1.
    return const AiCapability(
      backend: AiBackend.none,
      expectedLatencyMs: 0,
      isRecommended: false,
    );
  }

  Future<bool> _commandSucceeds(String exe, List<String> args) async {
    try {
      final r = await Process.run(exe, args).timeout(const Duration(seconds: 5));
      return r.exitCode == 0;
    } catch (_) {
      // ProcessException (no existe), TimeoutException, etc.
      return false;
    }
  }

  // --- Dispositivos de audio virtuales --------------------------------------

  /// Nombre típico del extremo de CAPTURA del cable virtual que el usuario
  /// debe elegir como micrófono de ChatPapol (ajustes de voz → micrófono).
  String get virtualMicHint => Platform.isWindows
      ? 'CABLE Output (VB-Audio Virtual Cable)'
      : 'Monitor de "VoiceFX-AI" (sink virtual de PipeWire/PulseAudio)';

  /// Resumen de la ruta de audio para mostrar en la UI / docs.
  String get routingSummary => Platform.isWindows
      ? 'VC Client: entrada = tu micrófono físico, salida = "CABLE Input '
          '(VB-Audio Virtual Cable)". ChatPapol: micrófono = "CABLE Output '
          '(VB-Audio Virtual Cable)".'
      : 'Crea un sink virtual (pactl load-module module-null-sink '
          'sink_name=voicefx_ai). VC Client: salida = voicefx_ai. ChatPapol: '
          'micrófono = "Monitor of voicefx_ai".';

  /// Lista los dispositivos de ENTRADA visibles para la app, para que la UI
  /// ayude a localizar el cable virtual. Usa flutter_webrtc (ya es dependencia
  /// del cliente por LiveKit); si la enumeración falla en alguna plataforma,
  /// devuelve lista vacía sin romper.
  Future<List<AiAudioDevice>> listInputDevices() async {
    try {
      final devs = await rtc.Helper.enumerateDevices('audioinput');
      return devs
          .map((d) => AiAudioDevice(d.deviceId, d.label))
          .toList(growable: false);
    } catch (_) {
      // TODO(integración): si en algún runner de escritorio enumerateDevices
      // no está implementado, exponer aquí la lista vía el bridge nativo.
      return const [];
    }
  }

  /// Heurística: de [listInputDevices], devuelve el primer dispositivo que
  /// parece un cable virtual, o null si no se encuentra ninguno.
  Future<AiAudioDevice?> findVirtualCableInput() async {
    final devs = await listInputDevices();
    const needles = ['cable output', 'vb-audio', 'monitor of', 'voicefx_ai'];
    for (final d in devs) {
      final l = d.label.toLowerCase();
      if (needles.any(l.contains)) return d;
    }
    return null;
  }

  // --- Utilidades --------------------------------------------------------------

  /// Tokeniza una línea de argumentos respetando comillas dobles:
  ///   `--model "C:\mis modelos\voz.pth" --port 18888`
  ///   → [--model, C:\mis modelos\voz.pth, --port, 18888]
  static List<String> _tokenizeArgs(String line) {
    final out = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ' ' && !inQuotes) {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }
}
