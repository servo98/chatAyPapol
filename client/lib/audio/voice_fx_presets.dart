// voice_fx_presets.dart — biblioteca de presets de VoiceFX (data-driven).
//
// Módulo de DATOS del motor de efectos de voz (native/voicefx/CONTRACT.md es
// autoritativo, §3–§5). Aquí NO hay DSP ni FFI: solo los presets integrados
// como datos Dart y la carga/mezcla del manifest JSON editable, espejando el
// patrón de assets/sfx_manifest.json (asset horneado, editable sin recompilar).
//
// ─── ESQUEMA JSON (assets/voicefx_presets.json, version 1) ──────────────────
//
//   {
//     "version": 1,
//     "presets": [
//       {
//         "id": "cueva",          // estable, snake_case; clave de persistencia
//         "label": "Cueva",       // etiqueta humana en español (la UI la muestra tal cual)
//         "category": "room",     // "room" | "character" | "gender" (agrupación en la UI)
//         "master": {             // opcional; defaults wetMix 1.0 / outGain 1.0
//           "wetMix": 1.0,        //   0.0–1.0  mezcla dry/wet global
//           "outGain": 1.0        //   0.0–4.0  ganancia lineal de salida
//         },
//         "chain": [              // orden del array == orden de procesado (máx 16 nodos)
//           {
//             "type": "reverb",   // nombre JSON del efecto (tabla CONTRACT §3)
//             "bypass": false,    // opcional, default false
//             "params": {         // claves JSON de la tabla §3; omitidas → default
//               "roomsize": 0.92, "damp": 0.25, "wet": 0.55
//             }
//           }
//         ]
//       }
//     ]
//   }
//
// Reglas de parseo (CONTRACT §4):
//   - `type` desconocido            → se descarta el preset ENTERO con warning
//     (forward-compat: un manifest nuevo no rompe un cliente viejo).
//   - param desconocido para el type → se ignora SOLO ese param, con warning.
//   - valores fuera de rango         → clamp (mismo comportamiento que la ABI).
//   - más de 16 nodos (VFX_MAX_NODES) → los extra se ignoran con warning.
//
// Mezcla manifest ↔ builtins: por `id`. Un preset del JSON con el mismo id
// REEMPLAZA al builtin (conservando su posición en la lista); ids nuevos se
// añaden al final en el orden del JSON. En desktop los assets se instalan como
// archivos planos (data/flutter_assets/assets/voicefx_presets.json), así que
// añadir o retocar presets NO requiere recompilar. Ver docs/voice-fx-presets.md.
//
// NOTA pubspec: `assets/voicefx_presets.json` debe estar registrado en la
// sección `flutter: → assets:` de pubspec.yaml (lo añade el paso de verify;
// si falta, loadVoiceFxPresetsFromJson() cae a los builtins sin romper nada).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'voice_fx.dart';

/// Ruta del manifest de presets dentro del bundle de assets.
const String kVoiceFxPresetsAsset = 'assets/voicefx_presets.json';

/// VFX_MAX_NODES de la ABI nativa: nodos extra en un preset se ignoran.
const int _kMaxNodes = 16;

/// Categorías conocidas por la UI (CONTRACT §4). Otras pasan con warning.
const Set<String> _kKnownCategories = {'room', 'character', 'gender'};

/// Claves JSON válidas y rango (min, max) por tipo de efecto — copia literal
/// de la tabla §3 del CONTRACT. (El mapeo clave→VfxParamId numérico vive en el
/// módulo de bindings; aquí solo se valida y clampea el manifest.)
const Map<VfxEffectType, Map<String, (double, double)>> _kParamRanges = {
  VfxEffectType.reverb: {
    'roomsize': (0.0, 1.0),
    'damp': (0.0, 1.0),
    'wet': (0.0, 1.0),
  },
  VfxEffectType.delay: {
    'timeMs': (1.0, 2000.0),
    'feedback': (0.0, 0.95),
    'mix': (0.0, 1.0),
  },
  VfxEffectType.biquad: {
    'type': (0.0, 3.0), // VfxBiquadType: 0=LP 1=HP 2=BP 3=NOTCH
    'freq': (20.0, 20000.0),
    'q': (0.1, 10.0),
  },
  VfxEffectType.ringmod: {
    'freq': (1.0, 2000.0),
    'mix': (0.0, 1.0),
  },
  VfxEffectType.distortion: {
    'drive': (1.0, 50.0),
    'mix': (0.0, 1.0),
  },
  VfxEffectType.pitch: {
    'semitones': (-12.0, 12.0),
    'formant': (0.5, 2.0),
  },
  VfxEffectType.noise: {
    'level': (0.0, 1.0),
    'color': (0.0, 1.0),
  },
  VfxEffectType.tremolo: {
    'rate': (0.1, 20.0),
    'depth': (0.0, 1.0),
  },
  VfxEffectType.chorus: {
    'rate': (0.05, 5.0),
    'depth': (0.0, 1.0),
    'mix': (0.0, 1.0),
  },
};

// ─── Presets integrados (CONTRACT §5, valores exactos) ───────────────────────
// Mismos datos que assets/voicefx_presets.json: el asset es la copia editable,
// esto es el fallback compilado si el asset falta o no parsea. `master`
// omitido = {wetMix: 1.0, outGain: 1.0}.
const List<Map<String, dynamic>> _kBuiltinPresetMaps = [
  // ── Salas / ambiente ──
  {
    'id': 'cueva',
    'label': 'Cueva',
    'category': 'room',
    'chain': [
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.92, 'damp': 0.25, 'wet': 0.55},
      },
      <String, dynamic>{
        'type': 'delay',
        'params': {'timeMs': 180.0, 'feedback': 0.45, 'mix': 0.30},
      },
    ],
  },
  {
    'id': 'iglesia',
    'label': 'Iglesia',
    'category': 'room',
    'chain': [
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.85, 'damp': 0.60, 'wet': 0.45},
      },
    ],
  },
  {
    'id': 'sala',
    'label': 'Sala pequeña',
    'category': 'room',
    'chain': [
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.25, 'damp': 0.70, 'wet': 0.22},
      },
    ],
  },
  {
    'id': 'eco',
    'label': 'Eco',
    'category': 'room',
    'chain': [
      <String, dynamic>{
        'type': 'delay',
        'params': {'timeMs': 400.0, 'feedback': 0.50, 'mix': 0.45},
      },
    ],
  },
  {
    'id': 'radio',
    'label': 'Radio / Walkie',
    'category': 'room',
    'chain': [
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 400.0, 'q': 0.9}, // HP
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 3000.0, 'q': 0.9}, // LP
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 4.0, 'mix': 0.6},
      },
      <String, dynamic>{
        'type': 'noise',
        'params': {'level': 0.03, 'color': 0.2},
      },
    ],
  },
  {
    'id': 'telefono',
    'label': 'Teléfono',
    'category': 'room',
    'chain': [
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 300.0, 'q': 0.707}, // HP
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 3400.0, 'q': 0.707}, // LP
      },
    ],
  },
  {
    'id': 'megafono',
    'label': 'Megáfono',
    'category': 'room',
    'chain': [
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 500.0, 'q': 0.8}, // HP
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 4000.0, 'q': 0.8}, // LP
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 12.0, 'mix': 0.85},
      },
    ],
  },
  {
    'id': 'robot',
    'label': 'Robot',
    'category': 'room',
    'chain': [
      <String, dynamic>{
        'type': 'ringmod',
        'params': {'freq': 35.0, 'mix': 0.8},
      },
      <String, dynamic>{
        'type': 'delay',
        'params': {'timeMs': 50.0, 'feedback': 0.40, 'mix': 0.30},
      },
    ],
  },
  {
    'id': 'scifi',
    'label': 'Sci-Fi',
    'category': 'room',
    'chain': [
      <String, dynamic>{
        'type': 'chorus',
        'params': {'rate': 0.6, 'depth': 0.7, 'mix': 0.6},
      },
      <String, dynamic>{
        'type': 'ringmod',
        'params': {'freq': 200.0, 'mix': 0.2},
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.5, 'damp': 0.5, 'wet': 0.25},
      },
    ],
  },
  // ── Personajes ──
  {
    'id': 'troll',
    'label': 'Troll',
    'category': 'character',
    'chain': [
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -8.0, 'formant': 0.78},
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 5.0, 'mix': 0.35},
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.90, 'damp': 0.30, 'wet': 0.40},
      },
    ],
  },
  {
    'id': 'demonio',
    'label': 'Demonio',
    'category': 'character',
    'chain': [
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -6.0, 'formant': 0.80},
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 9.0, 'mix': 0.50},
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.80, 'damp': 0.40, 'wet': 0.35},
      },
    ],
  },
  {
    'id': 'viejo',
    'label': 'Anciano',
    'category': 'character',
    'chain': [
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -1.5, 'formant': 0.92},
      },
      <String, dynamic>{
        'type': 'tremolo',
        'params': {'rate': 6.5, 'depth': 0.35},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 4000.0, 'q': 0.707}, // LP
      },
    ],
  },
  {
    'id': 'ardilla',
    'label': 'Ardilla',
    'category': 'character',
    'chain': [
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': 10.0, 'formant': 1.30},
      },
    ],
  },
  {
    'id': 'nino',
    'label': 'Niño',
    'category': 'character',
    'chain': [
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': 4.0, 'formant': 1.20},
      },
    ],
  },
  // ── Género ──
  {
    'id': 'hombre_a_mujer',
    'label': 'Hombre → Mujer',
    'category': 'gender',
    'chain': [
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': 4.0, 'formant': 1.20},
      },
    ],
  },
  {
    'id': 'mujer_a_hombre',
    'label': 'Mujer → Hombre',
    'category': 'gender',
    'chain': [
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -5.0, 'formant': 0.85},
      },
    ],
  },
];

/// Presets integrados, inmutables, en el orden canónico del CONTRACT §5.
/// Es el fallback compilado: la lista efectiva (builtins + overrides del
/// manifest) es la que devuelve [loadVoiceFxPresetsFromJson].
final List<VoiceFxPreset> kVoiceFxPresets =
    List.unmodifiable(_kBuiltinPresetMaps.map(VoiceFxPreset.fromJson));

/// Carga assets/voicefx_presets.json y lo mezcla con [kVoiceFxPresets] por id
/// (el JSON gana; ids nuevos se añaden al final). Si el asset no existe o no
/// parsea, devuelve solo los builtins: nunca lanza.
Future<List<VoiceFxPreset>> loadVoiceFxPresetsFromJson() async {
  List<dynamic> rawPresets;
  try {
    final raw = await rootBundle.loadString(kVoiceFxPresetsAsset);
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      _warn('manifest no es un objeto JSON → uso solo builtins');
      return List.unmodifiable(kVoiceFxPresets);
    }
    final version = decoded['version'];
    if (version != 1) {
      _warn('version $version desconocida (esperaba 1); intento parsear igual');
    }
    final list = decoded['presets'];
    rawPresets = list is List ? list : const [];
  } catch (e) {
    _warn('no se pudo leer $kVoiceFxPresetsAsset: $e → uso solo builtins');
    return List.unmodifiable(kVoiceFxPresets);
  }

  // Mezcla por id conservando el orden: builtins primero, overrides in-place,
  // presets nuevos del manifest al final.
  final byId = <String, VoiceFxPreset>{
    for (final p in kVoiceFxPresets) p.id: p,
  };
  final order = <String>[for (final p in kVoiceFxPresets) p.id];
  for (final entry in rawPresets) {
    if (entry is! Map) {
      _warn('entrada de preset no es un objeto → ignorada');
      continue;
    }
    final sane = _sanitizePresetMap(Map<String, dynamic>.from(entry));
    if (sane == null) continue; // ya avisó el sanitizador
    final preset = VoiceFxPreset.fromJson(sane);
    if (!byId.containsKey(preset.id)) order.add(preset.id);
    byId[preset.id] = preset;
  }
  return List.unmodifiable(order.map((id) => byId[id]!));
}

/// Valida y normaliza un preset crudo del manifest según las reglas del
/// CONTRACT §4. Devuelve un mapa listo para VoiceFxPreset.fromJson, o null si
/// el preset entero debe descartarse (id inválido, chain malformada o un
/// `type` de efecto desconocido).
Map<String, dynamic>? _sanitizePresetMap(Map<String, dynamic> raw) {
  final id = raw['id'];
  if (id is! String || id.isEmpty) {
    _warn('preset sin "id" válido → descartado');
    return null;
  }
  final rawLabel = raw['label'];
  final label = (rawLabel is String && rawLabel.isNotEmpty) ? rawLabel : id;
  final rawCategory = raw['category'];
  final category =
      (rawCategory is String && rawCategory.isNotEmpty) ? rawCategory : 'room';
  if (!_kKnownCategories.contains(category)) {
    _warn('preset "$id": category "$category" no es room/character/gender');
  }

  final rawChain = raw['chain'];
  if (rawChain is! List) {
    _warn('preset "$id": falta el array "chain" → descartado');
    return null;
  }
  final typeByName = VfxEffectType.values.asNameMap();
  final chain = <Map<String, dynamic>>[];
  for (final rawNode in rawChain) {
    if (chain.length >= _kMaxNodes) {
      _warn('preset "$id": más de $_kMaxNodes nodos; los extra se ignoran');
      break;
    }
    if (rawNode is! Map) {
      _warn('preset "$id": nodo de la chain no es un objeto → preset descartado');
      return null;
    }
    final typeName = rawNode['type'];
    final type = typeName is String ? typeByName[typeName] : null;
    if (type == null) {
      // Forward-compat: efecto que esta versión no conoce → fuera el preset.
      _warn('preset "$id": tipo de efecto desconocido "$typeName" → descartado');
      return null;
    }
    final ranges = _kParamRanges[type]!;
    final params = <String, double>{};
    final rawParams = rawNode['params'];
    if (rawParams is Map) {
      for (final e in rawParams.entries) {
        final key = e.key;
        if (key is! String) continue;
        final range = ranges[key];
        if (range == null) {
          _warn('preset "$id" [$typeName]: param desconocido "$key" ignorado');
        } else if (e.value is num) {
          final v = (e.value as num).toDouble();
          params[key] = v.clamp(range.$1, range.$2).toDouble();
        } else {
          _warn('preset "$id" [$typeName]: param "$key" no numérico → ignorado');
        }
      }
    }
    chain.add(<String, dynamic>{
      'type': typeName,
      'bypass': rawNode['bypass'] == true,
      'params': params,
    });
  }

  final out = <String, dynamic>{
    'id': id,
    'label': label,
    'category': category,
    'chain': chain,
  };
  final rawMaster = raw['master'];
  if (rawMaster is Map) {
    out['master'] = <String, dynamic>{
      'wetMix': _clampNum(rawMaster['wetMix'], 0.0, 1.0, 1.0),
      'outGain': _clampNum(rawMaster['outGain'], 0.0, 4.0, 1.0),
    };
  }
  return out;
}

double _clampNum(dynamic v, double min, double max, double def) =>
    v is num ? v.toDouble().clamp(min, max).toDouble() : def;

void _warn(String msg) {
  if (kDebugMode) debugPrint('voicefx presets: $msg');
}
