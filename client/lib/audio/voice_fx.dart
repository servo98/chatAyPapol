// voice_fx.dart — motor de efectos de voz en tiempo real (capa Dart).
//
// Capa pública sobre voicefx_bindings.dart (FFI → voicefx.dll/libvoicefx.so).
// Contrato autoritativo: native/voicefx/CONTRACT.md + include/voicefx.h.
//
// Posición en runtime:  mic → RNNoise (fork flutter_webrtc) → VoiceFX → encode.
// Este módulo NO toca voice.dart ni el plugin: el bridge de captura llamará a
// VoiceFxEngine.instance.processFrame() cuando se cablee en el merge.
//
// Sin widgets. ChangeNotifier-style: la UI (fase posterior) solo observa
// getters y llama métodos de mutación. Si la dynlib no está disponible todo
// degrada a no-op seguro (available == false) y el cliente sigue funcionando.

import 'dart:async';
import 'dart:convert';

// Float32List llega vía flutter/foundation (re-exporta dart:typed_data).
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voicefx_bindings.dart';
import 'voice_fx_presets.dart';

// ---------------------------------------------------------------------------
// Tipos de efecto — espejo 1:1 de VfxEffectType: .index == valor de la ABI C.
// NUNCA reordenar ni insertar en medio; solo añadir al final.
// El .name coincide con el "nombre JSON" del contrato (§3).
// ---------------------------------------------------------------------------
enum VoiceFxType {
  reverb, //     0 — reverb tipo Freeverb (cueva/iglesia/sala)
  delay, //      1 — delay con feedback / eco
  biquad, //     2 — filtro 2º orden LP/HP/BP/notch (radio/teléfono)
  ringmod, //    3 — modulador en anillo (robot)
  distortion, // 4 — waveshaper tanh (megáfono/demonio)
  pitch, //      5 — pitch shift + formantes
  noise, //      6 — cama de ruido aditivo (siseo de radio)
  tremolo, //    7 — LFO de amplitud (voz de anciano)
  chorus, //     8 — chorus (sci-fi)
  comp, //       9 — compresor + noise gate (gate thresh/release, ratio, attack, makeup)
  bitcrush, //  10 — cuantización de bits + sample&hold (8-bit / digital)
  vibrato, //   11 — delay corto modulado, sin dry (ondulación de PITCH)
  flanger, //   12 — comb corto + LFO + feedback (jet / robot resonante)
}

/// Alias con el nombre que usa el contrato (§6). MISMO tipo que [VoiceFxType]:
/// ambos nombres son válidos (`VfxEffectType.pitch == VoiceFxType.pitch`).
typedef VfxEffectType = VoiceFxType;

/// Etiquetas humanas (es) por tipo, para que la UI las pinte tal cual.
extension VoiceFxTypeLabel on VoiceFxType {
  String get labelEs => switch (this) {
        VoiceFxType.reverb => 'Reverb',
        VoiceFxType.delay => 'Eco / Delay',
        VoiceFxType.biquad => 'Filtro',
        VoiceFxType.ringmod => 'Ring Mod',
        VoiceFxType.distortion => 'Distorsión',
        VoiceFxType.pitch => 'Tono / Formantes',
        VoiceFxType.noise => 'Ruido',
        VoiceFxType.tremolo => 'Trémolo',
        VoiceFxType.chorus => 'Chorus',
        VoiceFxType.comp => 'Compresor',
        VoiceFxType.bitcrush => 'Bitcrush',
        VoiceFxType.vibrato => 'Vibrato',
        VoiceFxType.flanger => 'Flanger',
      };

  /// Params que expone este efecto (metadatos para render genérico de sliders).
  List<VoiceFxParam> get params => kVoiceFxParamRegistry[this]!;
}

/// Modos de filtro para el param `type` de [VoiceFxType.biquad] (VfxBiquadType).
/// Se pasan como float al nativo: 0=LP, 1=HP, 2=BP, 3=NOTCH, 4=PEAKING,
/// 5=LOWSHELF, 6=HIGHSHELF. Los modos 4/5/6 (EQ) usan además `gainDb`.
enum VoiceFxBiquadType { lowpass, highpass, bandpass, notch, peaking, lowshelf, highshelf }

// ---------------------------------------------------------------------------
// Ids de parámetro — copiados literales de voicefx.h (bloques de 100 por
// efecto, namespace global estable).
// ---------------------------------------------------------------------------
const int kVfxPReverbRoomsize = 100;
const int kVfxPReverbDamp = 101;
const int kVfxPReverbWet = 102;
const int kVfxPDelayTimeMs = 200;
const int kVfxPDelayFeedback = 201;
const int kVfxPDelayMix = 202;
const int kVfxPBiquadType = 300;
const int kVfxPBiquadFreq = 301;
const int kVfxPBiquadQ = 302;
const int kVfxPBiquadGainDb = 303;
const int kVfxPRingmodFreq = 400;
const int kVfxPRingmodMix = 401;
const int kVfxPDistDrive = 500;
const int kVfxPDistMix = 501;
const int kVfxPPitchSemitones = 600;
const int kVfxPPitchFormant = 601;
const int kVfxPNoiseLevel = 700;
const int kVfxPNoiseColor = 701;
const int kVfxPTremoloRate = 800;
const int kVfxPTremoloDepth = 801;
const int kVfxPChorusRate = 900;
const int kVfxPChorusDepth = 901;
const int kVfxPChorusMix = 902;
const int kVfxPCompGateThresh = 1000;
const int kVfxPCompGateRel = 1001;
const int kVfxPCompRatio = 1002;
const int kVfxPCompThresh = 1003;
const int kVfxPCompAttack = 1004;
const int kVfxPCompRelease = 1005;
const int kVfxPCompMakeup = 1006;
const int kVfxPCrushBits = 1100;
const int kVfxPCrushDownsample = 1101;
const int kVfxPCrushMix = 1102;
const int kVfxPVibratoRate = 1200;
const int kVfxPVibratoDepthCents = 1201;
const int kVfxPFlangerRate = 1300;
const int kVfxPFlangerDepth = 1301;
const int kVfxPFlangerFeedback = 1302;
const int kVfxPFlangerMix = 1303;

/// Metadatos de un parámetro: suficientes para que una UI futura pinte un
/// slider genérico sin conocer el efecto (label es + rango + default + unidad).
class VoiceFxParam {
  const VoiceFxParam(
    this.id,
    this.jsonKey,
    this.labelEs, {
    required this.min,
    required this.max,
    required this.defaultValue,
    this.unit = '',
  });

  /// VfxParamId de la ABI C (tabla §3 del contrato).
  final int id;

  /// Clave del schema JSON de presets/persistencia (p.ej. 'roomsize', 'timeMs').
  final String jsonKey;

  final String labelEs;
  final double min;
  final double max;
  final double defaultValue;

  /// Unidad para mostrar ('Hz', 'ms', 'st', '' = adimensional 0..1).
  final String unit;

  double clamp(double v) => v.clamp(min, max).toDouble();
}

/// Registro autoritativo de params por efecto (rangos/defaults de voicefx.h).
const Map<VoiceFxType, List<VoiceFxParam>> kVoiceFxParamRegistry = {
  VoiceFxType.reverb: [
    VoiceFxParam(kVfxPReverbRoomsize, 'roomsize', 'Tamaño', min: 0.0, max: 1.0, defaultValue: 0.50),
    VoiceFxParam(kVfxPReverbDamp, 'damp', 'Amortiguación', min: 0.0, max: 1.0, defaultValue: 0.50),
    VoiceFxParam(kVfxPReverbWet, 'wet', 'Mezcla', min: 0.0, max: 1.0, defaultValue: 0.33),
  ],
  VoiceFxType.delay: [
    VoiceFxParam(kVfxPDelayTimeMs, 'timeMs', 'Tiempo', min: 1.0, max: 2000.0, defaultValue: 350.0, unit: 'ms'),
    VoiceFxParam(kVfxPDelayFeedback, 'feedback', 'Repetición', min: 0.0, max: 0.95, defaultValue: 0.35),
    VoiceFxParam(kVfxPDelayMix, 'mix', 'Mezcla', min: 0.0, max: 1.0, defaultValue: 0.50),
  ],
  VoiceFxType.biquad: [
    VoiceFxParam(kVfxPBiquadType, 'type', 'Tipo (LP/HP/BP/Notch/Peak/Shelf)', min: 0.0, max: 6.0, defaultValue: 0.0),
    VoiceFxParam(kVfxPBiquadFreq, 'freq', 'Frecuencia', min: 20.0, max: 20000.0, defaultValue: 1000.0, unit: 'Hz'),
    VoiceFxParam(kVfxPBiquadQ, 'q', 'Resonancia', min: 0.1, max: 10.0, defaultValue: 0.707),
    VoiceFxParam(kVfxPBiquadGainDb, 'gainDb', 'Ganancia (Peak/Shelf)', min: -15.0, max: 15.0, defaultValue: 0.0, unit: 'dB'),
  ],
  VoiceFxType.ringmod: [
    VoiceFxParam(kVfxPRingmodFreq, 'freq', 'Portadora', min: 1.0, max: 2000.0, defaultValue: 30.0, unit: 'Hz'),
    VoiceFxParam(kVfxPRingmodMix, 'mix', 'Mezcla', min: 0.0, max: 1.0, defaultValue: 1.0),
  ],
  VoiceFxType.distortion: [
    VoiceFxParam(kVfxPDistDrive, 'drive', 'Drive', min: 1.0, max: 50.0, defaultValue: 8.0),
    VoiceFxParam(kVfxPDistMix, 'mix', 'Mezcla', min: 0.0, max: 1.0, defaultValue: 1.0),
  ],
  VoiceFxType.pitch: [
    VoiceFxParam(kVfxPPitchSemitones, 'semitones', 'Semitonos', min: -12.0, max: 12.0, defaultValue: 0.0, unit: 'st'),
    VoiceFxParam(kVfxPPitchFormant, 'formant', 'Formantes', min: 0.5, max: 2.0, defaultValue: 1.0, unit: '×'),
  ],
  VoiceFxType.noise: [
    VoiceFxParam(kVfxPNoiseLevel, 'level', 'Nivel', min: 0.0, max: 1.0, defaultValue: 0.05),
    VoiceFxParam(kVfxPNoiseColor, 'color', 'Color', min: 0.0, max: 1.0, defaultValue: 0.50),
  ],
  VoiceFxType.tremolo: [
    VoiceFxParam(kVfxPTremoloRate, 'rate', 'Velocidad', min: 0.1, max: 20.0, defaultValue: 5.0, unit: 'Hz'),
    VoiceFxParam(kVfxPTremoloDepth, 'depth', 'Profundidad', min: 0.0, max: 1.0, defaultValue: 0.5),
  ],
  VoiceFxType.chorus: [
    VoiceFxParam(kVfxPChorusRate, 'rate', 'Velocidad', min: 0.05, max: 5.0, defaultValue: 0.8, unit: 'Hz'),
    VoiceFxParam(kVfxPChorusDepth, 'depth', 'Profundidad', min: 0.0, max: 1.0, defaultValue: 0.4),
    VoiceFxParam(kVfxPChorusMix, 'mix', 'Mezcla', min: 0.0, max: 1.0, defaultValue: 0.5),
  ],
  // Reservado: sin params expuestos hasta que exista la impl nativa (type 9).
  VoiceFxType.comp: [
    VoiceFxParam(kVfxPCompGateThresh, 'gateThresh', 'Umbral gate', min: -80.0, max: 0.0, defaultValue: -45.0, unit: 'dB'),
    VoiceFxParam(kVfxPCompGateRel, 'gateRel', 'Release gate', min: 10.0, max: 300.0, defaultValue: 120.0, unit: 'ms'),
    VoiceFxParam(kVfxPCompRatio, 'ratio', 'Ratio', min: 1.0, max: 20.0, defaultValue: 3.0),
    VoiceFxParam(kVfxPCompThresh, 'compThresh', 'Umbral comp', min: -40.0, max: 0.0, defaultValue: -18.0, unit: 'dB'),
    VoiceFxParam(kVfxPCompAttack, 'attack', 'Attack', min: 1.0, max: 50.0, defaultValue: 10.0, unit: 'ms'),
    VoiceFxParam(kVfxPCompRelease, 'release', 'Release', min: 20.0, max: 300.0, defaultValue: 100.0, unit: 'ms'),
    VoiceFxParam(kVfxPCompMakeup, 'makeup', 'Makeup', min: 0.0, max: 24.0, defaultValue: 0.0, unit: 'dB'),
  ],
  VoiceFxType.bitcrush: [
    VoiceFxParam(kVfxPCrushBits, 'bits', 'Bits', min: 1.0, max: 16.0, defaultValue: 8.0),
    VoiceFxParam(kVfxPCrushDownsample, 'downsample', 'Decimación', min: 1.0, max: 32.0, defaultValue: 1.0),
    VoiceFxParam(kVfxPCrushMix, 'mix', 'Mezcla', min: 0.0, max: 1.0, defaultValue: 1.0),
  ],
  VoiceFxType.vibrato: [
    VoiceFxParam(kVfxPVibratoRate, 'rate', 'Velocidad', min: 0.1, max: 12.0, defaultValue: 5.5, unit: 'Hz'),
    VoiceFxParam(kVfxPVibratoDepthCents, 'depthCents', 'Profundidad', min: 0.0, max: 50.0, defaultValue: 20.0, unit: 'ct'),
  ],
  VoiceFxType.flanger: [
    VoiceFxParam(kVfxPFlangerRate, 'rate', 'Velocidad', min: 0.05, max: 2.0, defaultValue: 0.4, unit: 'Hz'),
    VoiceFxParam(kVfxPFlangerDepth, 'depth', 'Profundidad', min: 0.0, max: 1.0, defaultValue: 0.6),
    VoiceFxParam(kVfxPFlangerFeedback, 'feedback', 'Realimentación', min: 0.0, max: 0.9, defaultValue: 0.5),
    VoiceFxParam(kVfxPFlangerMix, 'mix', 'Mezcla', min: 0.0, max: 1.0, defaultValue: 0.5),
  ],
};

VoiceFxParam? _paramById(VoiceFxType type, int paramId) {
  for (final p in kVoiceFxParamRegistry[type]!) {
    if (p.id == paramId) return p;
  }
  return null;
}

VoiceFxParam? _paramByJsonKey(VoiceFxType type, String jsonKey) {
  for (final p in kVoiceFxParamRegistry[type]!) {
    if (p.jsonKey == jsonKey) return p;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Modelos
// ---------------------------------------------------------------------------

/// Un nodo de la cadena: efecto + valores de sus params + bypass.
/// `params` va keyed por VfxParamId (int de la ABI); para JSON se traduce a
/// las claves del contrato ('roomsize', 'timeMs', ...) vía el registro.
class VoiceFxNode {
  VoiceFxNode(this.type, {Map<int, double>? params, this.bypass = false})
      : params = {
          // siempre completo: defaults del registro + overrides clampeados
          for (final p in kVoiceFxParamRegistry[type]!)
            p.id: params != null && params.containsKey(p.id)
                ? p.clamp(params[p.id]!)
                : p.defaultValue,
        };

  final VoiceFxType type;

  /// Valores actuales keyed por param id de la ABI.
  /// Mutar SOLO vía VoiceFxEngine.setParam (si no, nativo y espejo divergen).
  final Map<int, double> params;

  bool bypass;

  VoiceFxNode copy() => VoiceFxNode(type, params: Map.of(params), bypass: bypass);

  /// Parsea el schema del contrato (§4):
  /// `{"type":"reverb","bypass":false,"params":{"roomsize":0.92}}`.
  /// Tipo desconocido → FormatException (el caller descarta preset/nodo con
  /// warning, forward-compat). Params desconocidos se ignoran; valores fuera
  /// de rango se clampean.
  factory VoiceFxNode.fromJson(Map<String, dynamic> json) {
    final typeName = json['type'] as String?;
    VoiceFxType? type;
    for (final t in VoiceFxType.values) {
      if (t.name == typeName) {
        type = t;
        break;
      }
    }
    if (type == null) {
      throw FormatException('voicefx: tipo de efecto desconocido "$typeName"');
    }
    final params = <int, double>{};
    final rawParams = json['params'];
    if (rawParams is Map) {
      rawParams.forEach((key, value) {
        final meta = _paramByJsonKey(type!, key.toString());
        if (meta == null || value is! num) return; // param desconocido: ignorar
        params[meta.id] = meta.clamp(value.toDouble());
      });
    }
    return VoiceFxNode(type, params: params, bypass: json['bypass'] == true);
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        if (bypass) 'bypass': true,
        'params': {
          for (final entry in params.entries)
            _paramById(type, entry.key)!.jsonKey: entry.value,
        },
      };
}

/// Preset inmutable (manifest assets/voicefx_presets.json, patrón sfx_manifest).
class VoiceFxPreset {
  const VoiceFxPreset({
    required this.id,
    required this.labelEs,
    this.category = 'room',
    this.wetMix = 1.0,
    this.outGain = 1.0,
    required this.chain,
  });

  /// Id estable snake_case ('cueva', 'robot', ...). Clave de persistencia.
  final String id;

  /// Etiqueta humana en español ('Cueva').
  final String labelEs;

  /// 'room' | 'character' | 'gender'.
  final String category;

  // Etapa master del preset.
  final double wetMix;
  final double outGain;

  /// Orden del array == orden de procesado.
  final List<VoiceFxNode> chain;

  /// Parsea una entrada de `presets[]` del manifest (§4 del contrato).
  /// Nodo con tipo desconocido → FormatException (se descarta el preset
  /// entero, forward-compat). Nodos extra sobre VFX_MAX_NODES se ignoran.
  factory VoiceFxPreset.fromJson(Map<String, dynamic> json) {
    final master = json['master'];
    final rawChain = (json['chain'] as List?) ?? const [];
    final chain = <VoiceFxNode>[];
    for (final raw in rawChain) {
      if (chain.length >= kVfxMaxNodes) {
        debugPrint('[voicefx] preset "${json['id']}": más de $kVfxMaxNodes nodos, extras ignorados');
        break;
      }
      chain.add(VoiceFxNode.fromJson(Map<String, dynamic>.from(raw as Map)));
    }
    return VoiceFxPreset(
      id: json['id'] as String,
      labelEs: (json['label'] ?? json['id']) as String,
      category: (json['category'] as String?) ?? 'room',
      wetMix: master is Map ? ((master['wetMix'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0).toDouble() : 1.0,
      outGain: master is Map ? ((master['outGain'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 4.0).toDouble() : 1.0,
      chain: List.unmodifiable(chain),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': labelEs,
        'category': category,
        'master': {'wetMix': wetMix, 'outGain': outGain},
        'chain': [for (final n in chain) n.toJson()],
      };
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// Motor singleton de efectos de voz. Posee el VfxChain nativo y una cadena
/// espejo en Dart. Cada mutación: (a) aplica al nativo, (b) notifyListeners(),
/// (c) persiste (debounced) a SharedPreferences.
///
/// Patrón de uso (mismo estilo que SfxService/VoiceManager):
///   await VoiceFxEngine.instance.init();
///   VoiceFxEngine.instance.addListener(...);   // la UI observa
///   engine.processFrame(frame);                 // lo llama el bridge de captura
class VoiceFxEngine extends ChangeNotifier {
  VoiceFxEngine._();

  /// Singleton lazy (se construye al primer acceso; init() es aparte).
  static final VoiceFxEngine instance = VoiceFxEngine._();

  static const String _prefsKey = 'voicefx_state';
  static const Duration _saveDebounce = Duration(milliseconds: 300);

  VoicefxNative? _native;
  bool _available = false;
  bool _inited = false;

  bool _enabled = false;
  final List<VoiceFxNode> _nodes = [];
  double _wetMix = 1.0;
  double _outGain = 1.0;
  String? _activePresetId;

  List<VoiceFxPreset> _presets = const [];

  SharedPreferences? _prefs;
  Timer? _saveTimer;

  // -- getters (vista de solo lectura para la UI) -----------------------------

  /// false si la dynlib no cargó o la ABI no coincide. El resto de la API
  /// sigue funcionando (estado Dart + persistencia) pero sin audio procesado.
  bool get available => _available;

  /// Encendido global. Apagado => processFrame es passthrough (la cadena se
  /// conserva, tanto en Dart como en el nativo).
  bool get enabled => _enabled;

  /// Cadena actual, orden == orden de procesado. NO mutar los nodos a mano.
  List<VoiceFxNode> get nodes => List.unmodifiable(_nodes);

  double get wetMix => _wetMix;
  double get outGain => _outGain;

  /// Presets del manifest, en el orden del JSON.
  List<VoiceFxPreset> get presets => List.unmodifiable(_presets);

  /// null si la cadena está vacía o fue editada a mano tras cargar un preset.
  String? get activePresetId => _activePresetId;

  VoiceFxPreset? presetById(String id) {
    for (final p in _presets) {
      if (p.id == id) return p;
    }
    return null;
  }

  // -- init / shutdown ----------------------------------------------------------

  /// Carga dynlib + valida ABI + crea el chain (canónico 48000/480), carga el
  /// manifest de presets y restaura el estado persistido. Idempotente.
  Future<void> init({int sampleRate = 48000, int maxFrames = 480}) async {
    if (_inited) return;
    _inited = true;

    // 1. (FFI standalone retirado) El DSP del canal EN VIVO va por el fork
    //    flutter_webrtc vía WebrtcApm.setVoiceFx(nativeChainSpec()). La antigua
    //    dynlib voicefx.dll/libvoicefx.so era una ruta de PREVIEW nunca cableada
    //    (processFrame) y su único efecto visible era el warning ruidoso
    //    "voicefx.dll no encontrado". Se deja _native en null → todas sus
    //    llamadas (null-safe) son no-op; la cadena se publica por nativeChainSpec.
    _native = null;
    _available = false;

    // 2. presets data-driven (assets/voicefx_presets.json, patrón sfx_manifest);
    //    fallback a los horneados en código si el asset falta o no parsea
    try {
      _presets = await loadVoiceFxPresetsFromJson();
    } catch (e) {
      debugPrint('[voicefx] manifest de presets ilegible, usando horneados: $e');
      _presets = kVoiceFxPresets;
    }
    if (_presets.isEmpty) _presets = kVoiceFxPresets;

    // 3. estado persistido
    _prefs = await SharedPreferences.getInstance();
    _restoreState(_prefs!.getString(_prefsKey));

    _rebuildNativeChain();
    _pushMasterToNative();
    notifyListeners();
  }

  /// Libera el chain nativo y para la persistencia pendiente (con flush).
  /// Tras shutdown() el singleton puede volver a init() — por eso NO se usa
  /// ChangeNotifier.dispose(), que es terminal.
  Future<void> shutdown() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _saveNow();
    _native?.destroy();
    _native = null;
    _available = false;
    _inited = false;
  }

  // -- mutaciones ---------------------------------------------------------------

  Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    _afterMutation();
  }

  /// Añade un efecto al final de la cadena con sus defaults.
  /// Devuelve el índice del nodo nuevo, o -1 si la cadena está llena.
  int add(VoiceFxType type) {
    if (_nodes.length >= kVfxMaxNodes) return -1;
    final node = VoiceFxNode(type);
    _nodes.add(node);
    // append incremental al nativo (mismo orden ⇒ mismo índice)
    final n = _native;
    if (n != null && n.hasChain) {
      final idx = n.add(type.index);
      if (idx >= 0) {
        node.params.forEach((id, v) => n.setParam(idx, id, v));
      }
    }
    _activePresetId = null;
    // Añadir un efecto = querer oírlo: enciende el master (mismo criterio que
    // aplicar un preset). Si no, la cadena manual quedaba inerte con FX en OFF
    // y parecía "no aplicarse".
    _enabled = true;
    _afterMutation();
    return _nodes.length - 1;
  }

  /// Quita el nodo [index]. La ABI no tiene remove: se reconstruye la cadena
  /// nativa (vfx_clear + vfx_add*) — barato y sin glitches (swap lock-free).
  void removeAt(int index) {
    if (index < 0 || index >= _nodes.length) return;
    _nodes.removeAt(index);
    _activePresetId = null;
    _rebuildNativeChain();
    _afterMutation();
  }

  /// Mueve el nodo [from] a la posición [to]. Índices 0-based ya normalizados
  /// sobre la lista actual (NO la semántica cruda de ReorderableListView).
  void reorder(int from, int to) {
    if (from < 0 || from >= _nodes.length || to < 0 || to >= _nodes.length || from == to) {
      return;
    }
    final node = _nodes.removeAt(from);
    _nodes.insert(to, node);
    _activePresetId = null;
    _rebuildNativeChain();
    _afterMutation();
  }

  /// Vacía la cadena (master se conserva, igual que vfx_clear).
  void clear() {
    if (_nodes.isEmpty) return;
    _nodes.clear();
    _activePresetId = null;
    _native?.clear();
    _afterMutation();
  }

  /// Fija un parámetro del nodo [index]. [paramId] es el id de la ABI
  /// (constantes kVfxP*); el valor se clampea al rango documentado.
  void setParam(int index, int paramId, double value) {
    if (index < 0 || index >= _nodes.length) return;
    final node = _nodes[index];
    final meta = _paramById(node.type, paramId);
    if (meta == null) return; // param no pertenece a este efecto: ignorar
    final v = meta.clamp(value);
    node.params[paramId] = v;
    _native?.setParam(index, paramId, v);
    _activePresetId = null;
    _afterMutation();
  }

  void setBypass(int index, bool bypass) {
    if (index < 0 || index >= _nodes.length) return;
    if (_nodes[index].bypass == bypass) return;
    _nodes[index].bypass = bypass;
    _native?.setBypass(index, bypass);
    _activePresetId = null;
    _afterMutation();
  }

  /// Etapa master (después de toda la cadena): wetMix 0..1, outGain 0..4.
  /// No anula activePresetId (es un ajuste de salida, no de la cadena).
  void setMaster({double? wetMix, double? outGain}) {
    if (wetMix == null && outGain == null) return;
    if (wetMix != null) _wetMix = wetMix.clamp(0.0, 1.0).toDouble();
    if (outGain != null) _outGain = outGain.clamp(0.0, 4.0).toDouble();
    _pushMasterToNative();
    _afterMutation();
  }

  /// Reemplaza cadena + master por los del preset (copia profunda: editar
  /// después no muta el preset). Marca activePresetId.
  void loadPreset(VoiceFxPreset preset) {
    _nodes
      ..clear()
      ..addAll(preset.chain.map((n) => n.copy()));
    _wetMix = preset.wetMix;
    _outGain = preset.outGain;
    _activePresetId = preset.id;
    _rebuildNativeChain();
    _pushMasterToNative();
    _afterMutation();
  }

  // -- audio (hilo de captura / harness) ---------------------------------------

  /// Procesa un frame mono float32 [-1,1] IN-PLACE y lo devuelve (misma
  /// instancia, cero allocs). Seam para el bridge de integración: se llama
  /// DESPUÉS de RNNoise y ANTES del encoder. No-op si !available o !enabled.
  /// length debe ser <= maxFrames del init (canónico 480 = 10 ms @ 48 kHz).
  Float32List processFrame(Float32List frame) {
    if (!_available || !_enabled) return frame;
    _native?.process(frame);
    return frame;
  }

  /// Serialización COMPACTA de la cadena para el procesador nativo del fork
  /// flutter_webrtc (capture post-processing). Formato:
  ///   "wet;gain;type,bypass,pid=val&pid=val|type,bypass,..."
  /// donde type = VoiceFxType.index y pid = id de param de la ABI. La parsea
  /// rnnoise_processor.cc (ParseSpec). El `enabled` viaja aparte (setVoiceFx).
  String nativeChainSpec() {
    final sb = StringBuffer()
      ..write(_wetMix.toStringAsFixed(4))
      ..write(';')
      ..write(_outGain.toStringAsFixed(4))
      ..write(';');
    for (var i = 0; i < _nodes.length; i++) {
      if (i > 0) sb.write('|');
      final n = _nodes[i];
      sb
        ..write(n.type.index)
        ..write(',')
        ..write(n.bypass ? 1 : 0)
        ..write(',');
      var first = true;
      n.params.forEach((id, v) {
        if (!first) sb.write('&');
        first = false;
        sb
          ..write(id)
          ..write('=')
          ..write(v.toStringAsFixed(4));
      });
    }
    return sb.toString();
  }

  // -- internas -----------------------------------------------------------------

  /// Reconstruye la cadena nativa completa desde el espejo Dart
  /// (vfx_clear + N×vfx_add + params + bypass). Ver CONTRACT.md §2.
  void _rebuildNativeChain() {
    final n = _native;
    if (n == null || !n.hasChain) return;
    n.clear();
    for (final node in _nodes) {
      final idx = n.add(node.type.index);
      if (idx < 0) continue; // no debería pasar: ambos lados topan en 16
      node.params.forEach((id, v) => n.setParam(idx, id, v));
      if (node.bypass) n.setBypass(idx, true);
    }
  }

  void _pushMasterToNative() => _native?.setMaster(_wetMix, _outGain);

  /// Toda mutación termina aquí: notifica a la UI y agenda persistencia.
  void _afterMutation() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () {
      _saveNow();
    });
  }

  Future<void> _saveNow() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final state = <String, dynamic>{
      'version': 1,
      'enabled': _enabled,
      'activePresetId': _activePresetId,
      'master': {'wetMix': _wetMix, 'outGain': _outGain},
      'chain': [for (final n in _nodes) n.toJson()],
    };
    await prefs.setString(_prefsKey, jsonEncode(state));
  }

  /// Restaura el JSON de [_prefsKey]; si no parsea, cadena vacía (defaults).
  void _restoreState(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final state = jsonDecode(raw) as Map<String, dynamic>;
      _enabled = state['enabled'] == true;
      _activePresetId = state['activePresetId'] as String?;
      final master = state['master'];
      if (master is Map) {
        _wetMix = ((master['wetMix'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0).toDouble();
        _outGain = ((master['outGain'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 4.0).toDouble();
      }
      _nodes.clear();
      for (final rawNode in (state['chain'] as List? ?? const [])) {
        if (_nodes.length >= kVfxMaxNodes) break;
        try {
          _nodes.add(VoiceFxNode.fromJson(Map<String, dynamic>.from(rawNode as Map)));
        } catch (e) {
          // nodo de una versión futura: se descarta solo ese nodo
          debugPrint('[voicefx] nodo persistido ignorado: $e');
        }
      }
    } catch (e) {
      debugPrint('[voicefx] estado persistido ilegible, empezando limpio: $e');
      _nodes.clear();
      _enabled = false;
      _wetMix = 1.0;
      _outGain = 1.0;
      _activePresetId = null;
    }
  }
}
