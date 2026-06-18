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
    // VfxBiquadType: 0=LP 1=HP 2=BP 3=NOTCH 4=PEAK 5=LOWSHELF 6=HIGHSHELF.
    // Rango ampliado a (0,6) por el EQ paramétrico (Fase 2 del blueprint).
    'type': (0.0, 6.0),
    'freq': (20.0, 20000.0),
    'q': (0.1, 10.0),
    // Solo lo usan PEAK/LOWSHELF/HIGHSHELF (modos 4/5/6); ignorado por LP/HP/BP/NOTCH.
    'gainDb': (-15.0, 15.0),
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
    // Capa sub-octava intra-nodo (param 605): mezcla de una copia a -12 st.
    'subOctave': (0.0, 1.0),
    // Autotune / hard-tune reusando el front-end del PV (params 602..604).
    'autotune': (0.0, 1.0), // 0=off, 1=on
    'scale': (0.0, 2.0), // 0=cromática, 1=mayor, 2=menor
    'retuneMs': (0.0, 200.0),
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
  // ── Tipos nuevos (blueprint Fases 0/4/7) ───────────────────────────────────
  // NOTA: estas entradas dependen de que voice_fx.dart declare los VoiceFxType
  // correspondientes (comp, bitcrush, vibrato, flanger, freqshift) y sus params
  // en kVoiceFxParamRegistry; mientras no existan, el sanitizador descarta los
  // presets que los usen (forward-compat). El integrador reconcilia ids.
  VfxEffectType.comp: {
    'gateThresh': (-80.0, 0.0),
    'gateRel': (10.0, 300.0),
    'ratio': (1.0, 20.0),
    'compThresh': (-40.0, 0.0),
    'attack': (1.0, 50.0),
    'release': (20.0, 300.0),
    'makeup': (0.0, 24.0),
  },
  VfxEffectType.bitcrush: {
    'bits': (1.0, 16.0),
    'downsample': (1.0, 32.0),
    'mix': (0.0, 1.0),
  },
  VfxEffectType.vibrato: {
    'rate': (0.1, 12.0),
    'depthCents': (0.0, 50.0),
  },
  VfxEffectType.flanger: {
    'rate': (0.05, 2.0),
    'depth': (0.0, 1.0),
    'feedback': (0.0, 0.9),
    'mix': (0.0, 1.0),
  },
  // NOTA: freqshift aún NO está implementado (Fase 7, diferido por el crítico:
  // peor relación valor/riesgo en 16k mono). Los 2 presets alien que lo usan
  // se descartan solos en runtime (forward-compat) hasta implementarlo.
};

// ─── Presets integrados (CONTRACT §5, valores exactos) ───────────────────────
// Mismos datos que assets/voicefx_presets.json: el asset es la copia editable,
// esto es el fallback compilado si el asset falta o no parsea. `master`
// omitido = {wetMix: 1.0, outGain: 1.0}.
const List<Map<String, dynamic>> _kBuiltinPresetMaps = [
  // ═══════════════════════════════════════════════════════════════════════════
  // Catálogo nivel "Voicemod" (blueprint §Catálogo de presets). Todos los
  // presets siguen el ORDEN CANÓNICO de cadena (regla §Reglas de mastering):
  //   1) gate (dentro de comp) · 2) EQ correctiva / HP de limpieza ·
  //   3) pitch/formant · 4) no-lineal SOBREMUESTREADO (distortion/ringmod) ·
  //   5) modulación (tremolo/vibrato/chorus/flanger) · 6) EQ de carácter ·
  //   7) tiempo (delay → reverb) · 8) makeup (master.outGain) · 9) limitador.
  // El limitador brickwall a -1 dBFS es IMPLÍCITO en el master del motor
  // (no es un nodo): por eso ningún preset lo lista. El loudness se iguala con
  // master.outGain para que cambiar de voz no salte de nivel.
  //
  // Modos de biquad: 0=LP 1=HP 2=BP 3=NOTCH 4=PEAK 5=LOWSHELF 6=HIGHSHELF;
  // 'gainDb' solo aplica a 4/5/6.
  // ═══════════════════════════════════════════════════════════════════════════

  // ── Personajes ──────────────────────────────────────────────────────────────
  {
    'id': 'demonio',
    'label': 'Demonio del Abismo',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      // gate antes del drive: no amplificar hiss en los silencios.
      <String, dynamic>{
        'type': 'comp',
        'params': {
          'gateThresh': -45.0, 'gateRel': 120.0, 'ratio': 4.0,
          'compThresh': -18.0, 'attack': 15.0, 'release': 120.0, 'makeup': 3.0,
        },
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 100.0, 'q': 0.707}, // HP de limpieza
      },
      // sub-octava para el growl + formant abajo para cuerpo.
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -6.0, 'formant': 0.80, 'subOctave': 0.35},
      },
      // distorsión oversampleada (anti-alias en el motor, no es un param).
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 9.0, 'mix': 0.50},
      },
      // EQ de carácter: presencia a 2.8k.
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 4.0, 'freq': 2800.0, 'q': 1.0, 'gainDb': 4.0}, // PEAK
      },
      // reverb wet bajo: profundidad sin ahogar la inteligibilidad.
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.55, 'damp': 0.50, 'wet': 0.15},
      },
    ],
  },
  {
    'id': 'senor_oscuro',
    'label': 'Señor Oscuro',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 0.95},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {
          'gateThresh': -42.0, 'ratio': 5.0, 'compThresh': -16.0, 'makeup': 4.0,
        },
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 90.0, 'q': 0.707}, // HP
      },
      // -8 st + sub-octava 0.45: apila voces (growl tipo "The Dark Lord").
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -8.0, 'formant': 0.77, 'subOctave': 0.45},
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 11.0, 'mix': 0.55},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 5.0, 'freq': 150.0, 'q': 0.707, 'gainDb': 3.0}, // LOWSHELF (pecho)
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.60, 'damp': 0.45, 'wet': 0.18},
      },
    ],
  },
  {
    'id': 'monstruo',
    'label': 'Monstruo / Ogro',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -45.0, 'ratio': 3.0, 'compThresh': -18.0},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 95.0, 'q': 0.707}, // HP
      },
      // el cuerpo viene del formant bajo + sub-octava, NO de saturar.
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -8.0, 'formant': 0.78, 'subOctave': 0.30},
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 6.0, 'mix': 0.35}, // grit suave
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.55, 'damp': 0.50, 'wet': 0.18},
      },
    ],
  },
  {
    'id': 'gigante',
    'label': 'Gigante Colosal',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 0.95},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {
          'gateThresh': -45.0, 'ratio': 4.0, 'compThresh': -16.0, 'makeup': 3.0,
        },
      },
      // tracto enorme (formant 0.72) + sub-octava = escala descomunal.
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -9.0, 'formant': 0.72, 'subOctave': 0.40},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 5.0, 'freq': 120.0, 'q': 0.707, 'gainDb': 4.0}, // LOWSHELF
      },
      // LP quita el brillo fino que delataría el truco.
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 6500.0, 'q': 0.7}, // LP
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.70, 'damp': 0.55, 'wet': 0.22},
      },
    ],
  },
  {
    'id': 'robot',
    'label': 'Robot Dalek',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      // ringmod band-limited (clamp de carrier en el motor).
      <String, dynamic>{
        'type': 'ringmod',
        'params': {'freq': 30.0, 'mix': 0.85},
      },
      // bitcrush: la pieza nueva clave para "máquina" (transmisión digital).
      <String, dynamic>{
        'type': 'bitcrush',
        'params': {'bits': 6.0, 'downsample': 3.0, 'mix': 0.7},
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 6.0, 'mix': 0.5},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 2.0, 'freq': 1500.0, 'q': 2.0}, // BP de altavoz
      },
      <String, dynamic>{
        'type': 'delay',
        'params': {'timeMs': 45.0, 'feedback': 0.35, 'mix': 0.25}, // slap corto
      },
    ],
  },
  {
    'id': 'cyborg',
    'label': 'Cyborg / IA',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -45.0, 'ratio': 3.0},
      },
      <String, dynamic>{
        'type': 'ringmod',
        'params': {'freq': 200.0, 'mix': 0.25}, // ringmod alto leve
      },
      <String, dynamic>{
        'type': 'flanger',
        'params': {'rate': 0.3, 'depth': 0.5, 'feedback': 0.6, 'mix': 0.4},
      },
      <String, dynamic>{
        'type': 'bitcrush',
        'params': {'bits': 10.0, 'downsample': 1.0, 'mix': 0.4}, // crush ligero
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 4.0, 'freq': 3000.0, 'q': 1.0, 'gainDb': 3.0}, // PEAK
      },
    ],
  },
  {
    'id': 'alien',
    'label': 'Alien Shimmering',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -45.0, 'ratio': 3.0},
      },
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': 3.0, 'formant': 1.10}, // pitch leve arriba deshumaniza
      },
      // (freqshift diferido: el ringmod aporta el carácter inarmónico)
      <String, dynamic>{
        'type': 'ringmod',
        'params': {'freq': 250.0, 'mix': 0.28},
      },
      // NOTA: en MONO el chorus es un detune/comb leve, no el ancho estéreo
      // que "shimmer" evoca (limitación reconocida en la verificación).
      <String, dynamic>{
        'type': 'chorus',
        'params': {'rate': 0.6, 'depth': 0.7, 'mix': 0.5},
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.50, 'damp': 0.50, 'wet': 0.25},
      },
    ],
  },
  {
    'id': 'alien_grave',
    'label': 'Xenomorfo',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 0.97},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -45.0, 'ratio': 4.0, 'compThresh': -16.0},
      },
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -4.0, 'formant': 0.85},
      },
      // (freqshift diferido: ringmod grave para el timbre de criatura)
      <String, dynamic>{
        'type': 'ringmod',
        'params': {'freq': 150.0, 'mix': 0.35},
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 4.0, 'mix': 0.3}, // grit leve
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.55, 'damp': 0.50, 'wet': 0.22},
      },
    ],
  },
  {
    'id': 'ardilla',
    'label': 'Ardilla / Chipmunk',
    'category': 'character',
    // LIMITADO POR BANDA (16k): chipmunk fino y algo aliaseado pese al LP;
    // sin "aire" real (vive en 8-14k, fuera de banda) hasta la Fase 8 fullband.
    'master': {'wetMix': 1.0, 'outGain': 0.95},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -48.0, 'ratio': 3.0},
      },
      // formant alto (munchkin) separado del pitch para no sonar a "cinta".
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': 7.0, 'formant': 1.30},
      },
      // LP ~6.5k OBLIGATORIO: doma el aliasing chillón del pitch-up grande.
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 6500.0, 'q': 0.7}, // LP
      },
    ],
  },
  {
    'id': 'helio',
    'label': 'Helio / Munchkin',
    'category': 'character',
    // LIMITADO POR BANDA (16k): +10 st ya no tiene agudos que subir; resultado
    // fino y aliaseado pese al LP. Techo práctico del pitch-up en 16k mono.
    'master': {'wetMix': 1.0, 'outGain': 0.92},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -48.0, 'ratio': 3.0},
      },
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': 10.0, 'formant': 1.40},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 6000.0, 'q': 0.7}, // LP obligatorio
      },
    ],
  },
  {
    'id': 'narrador',
    'label': 'Narrador de Cine',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      // compresor fuerte = el secreto del sonido de tráiler.
      <String, dynamic>{
        'type': 'comp',
        'params': {
          'gateThresh': -42.0, 'ratio': 6.0, 'compThresh': -20.0,
          'attack': 8.0, 'release': 110.0, 'makeup': 4.0,
        },
      },
      // pitch -2 + formant 0.90 da pecho sin sonar a monstruo.
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -2.0, 'formant': 0.90},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 5.0, 'freq': 110.0, 'q': 0.707, 'gainDb': 4.0}, // LOWSHELF graves
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 4.0, 'freq': 2500.0, 'q': 1.0, 'gainDb': 3.0}, // PEAK presencia
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 7000.0, 'q': 0.7}, // LP
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 2.0, 'mix': 0.25}, // calidez muy leve
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.30, 'damp': 0.6, 'wet': 0.12}, // tamaño, no eco
      },
    ],
  },
  {
    'id': 'viejo',
    'label': 'Anciano Tembloroso',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -45.0, 'ratio': 2.0},
      },
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -1.5, 'formant': 0.92},
      },
      // vibrato (ondulación de PITCH, nuevo) + tremolo (volumen) = temblor real.
      <String, dynamic>{
        'type': 'vibrato',
        'params': {'rate': 5.5, 'depthCents': 22.0},
      },
      <String, dynamic>{
        'type': 'tremolo',
        'params': {'rate': 6.5, 'depth': 0.32},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 4000.0, 'q': 0.707}, // LP voz envejecida
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 4.0, 'freq': 300.0, 'q': 1.0, 'gainDb': -3.0}, // PEAK -3: quita boxiness
      },
    ],
  },
  {
    'id': 'susurro',
    'label': 'Susurro Siniestro',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      // makeup "pega" el susurro al oído.
      <String, dynamic>{
        'type': 'comp',
        'params': {
          'gateThresh': -52.0, 'ratio': 2.5, 'compThresh': -22.0, 'makeup': 3.0,
        },
      },
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -3.0, 'formant': 0.88},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 200.0, 'q': 0.707}, // HP
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 4.0, 'freq': 4500.0, 'q': 2.0, 'gainDb': 4.0}, // PEAK aire de aliento
      },
      <String, dynamic>{
        'type': 'noise',
        'params': {'level': 0.015, 'color': 0.3}, // pizca de aliento
      },
      <String, dynamic>{
        'type': 'delay',
        'params': {'timeMs': 220.0, 'feedback': 0.30, 'mix': 0.25},
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.70, 'damp': 0.40, 'wet': 0.30},
      },
    ],
  },
  {
    'id': 'radio',
    'label': 'Radio / Walkie-Talkie',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      // gate para silencios limpios entre transmisiones.
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -45.0, 'ratio': 3.0},
      },
      // band-pass estrecho: las TRES capas juntas (HP+LP+dist+noise) = realismo.
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
        'params': {'drive': 4.0, 'mix': 0.6}, // oversampleada: sin fritura digital
      },
      <String, dynamic>{
        'type': 'noise',
        'params': {'level': 0.03, 'color': 0.2}, // estática
      },
    ],
  },
  {
    'id': 'telefono',
    'label': 'Teléfono',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      // band-pass GSM/PSTN 300-3400 estándar + grit muy leve.
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 300.0, 'q': 0.707}, // HP
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 3400.0, 'q': 0.707}, // LP
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 2.0, 'mix': 0.3}, // "línea mala"
      },
    ],
  },
  {
    'id': 'megafono',
    'label': 'Megáfono / PA',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 0.95},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -42.0, 'ratio': 4.0},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 500.0, 'q': 0.8}, // HP
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 0.0, 'freq': 4000.0, 'q': 0.8}, // LP
      },
      // distorsión FUERTE (cono saturado) oversampleada: el limitador master
      // evita que truene con drive 12.
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 12.0, 'mix': 0.85},
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.30, 'damp': 0.5, 'wet': 0.15}, // PA en estadio
      },
    ],
  },
  {
    'id': 'autotune',
    'label': 'Autotune',
    'category': 'character',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -45.0, 'ratio': 3.0, 'compThresh': -18.0},
      },
      // retune 0 = el quiebre robótico (reusa la f0 del PV ya calculada).
      <String, dynamic>{
        'type': 'pitch',
        'params': {
          'semitones': 0.0, 'formant': 1.0,
          'autotune': 1.0, 'scale': 2.0, 'retuneMs': 0.0,
        },
      },
      <String, dynamic>{
        'type': 'chorus',
        'params': {'rate': 0.4, 'depth': 0.3, 'mix': 0.3},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 4.0, 'freq': 4000.0, 'q': 1.0, 'gainDb': 3.0}, // PEAK
      },
    ],
  },

  // ── Género ──────────────────────────────────────────────────────────────────
  {
    'id': 'hombre_a_mujer',
    'label': 'Hombre → Mujer',
    'category': 'gender',
    // LIMITADO POR BANDA (16k): correcta y con presencia de medios-altos, pero
    // sin el "aire" femenino real (8-14k) hasta la Fase 8 fullband.
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {
          'gateThresh': -48.0, 'ratio': 3.0, 'compThresh': -18.0, 'makeup': 2.0,
        },
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 90.0, 'q': 0.707}, // HP
      },
      // CLAVE: formant (1.20) sube MENOS que el ratio para evitar chipmunk.
      // No pasar de +6 st a 16k. Phase-locking limpia consonantes (en el motor).
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': 5.0, 'formant': 1.20},
      },
      // PEAK a 3.5k = presencia de medios-altos (NO "aire", inexistente a 16k).
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 4.0, 'freq': 3500.0, 'q': 1.0, 'gainDb': 3.0}, // PEAK
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.20, 'damp': 0.5, 'wet': 0.10},
      },
    ],
  },
  {
    'id': 'nino',
    'label': 'Niño Travieso',
    'category': 'gender',
    // LIMITADO POR BANDA (16k): presencia, no brillo real de agudos.
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -48.0, 'ratio': 3.0},
      },
      // recortar sub-180Hz evita que suene a "cinta acelerada".
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 1.0, 'freq': 180.0, 'q': 0.707}, // HP
      },
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': 5.0, 'formant': 1.22}, // tracto pequeño
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 4.0, 'freq': 4000.0, 'q': 1.2, 'gainDb': 2.0}, // PEAK presencia
      },
    ],
  },
  {
    'id': 'mujer_a_hombre',
    'label': 'Mujer → Hombre',
    'category': 'gender',
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {
          'gateThresh': -45.0, 'ratio': 3.0, 'compThresh': -18.0, 'makeup': 2.0,
        },
      },
      // -5 st + formant bajo (tracto grande). Si suena embarrado: formant 0.88.
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -5.0, 'formant': 0.85},
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 5.0, 'freq': 180.0, 'q': 0.707, 'gainDb': 2.0}, // LOWSHELF
      },
      // drive muy leve da presencia para que no suene "sordo/hueco".
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 2.0, 'mix': 0.25},
      },
    ],
  },

  // ── Salas / ambiente ──────────────────────────────────────────────────────
  {
    'id': 'fantasma',
    'label': 'Fantasma / Espectro',
    'category': 'room',
    // Reverb largo legítimo (sala explícita): wet alto permitido por las reglas.
    // En 16k mono la cola suena algo metálica (sin difusión >8k); limitación.
    'master': {'wetMix': 1.0, 'outGain': 0.95},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {'gateThresh': -50.0, 'ratio': 2.0},
      },
      <String, dynamic>{
        'type': 'pitch',
        'params': {'semitones': -2.0, 'formant': 0.95},
      },
      <String, dynamic>{
        'type': 'vibrato',
        'params': {'rate': 4.0, 'depthCents': 15.0}, // inquietud etérea
      },
      <String, dynamic>{
        'type': 'delay',
        'params': {'timeMs': 300.0, 'feedback': 0.40, 'mix': 0.40},
      },
      <String, dynamic>{
        'type': 'reverb',
        'params': {'roomsize': 0.90, 'damp': 0.30, 'wet': 0.55},
      },
    ],
  },
  {
    'id': 'locutor_fm',
    'label': 'Locutor FM Premium',
    'category': 'room',
    // Sin pitch ni efectos raros: la receta que hace que CUALQUIER voz suene
    // profesional. Base/"pre" que demuestra el valor del comp + EQ nuevos.
    'master': {'wetMix': 1.0, 'outGain': 1.0},
    'chain': [
      <String, dynamic>{
        'type': 'comp',
        'params': {
          'gateThresh': -45.0, 'gateRel': 130.0, 'ratio': 4.0,
          'compThresh': -18.0, 'attack': 10.0, 'release': 100.0, 'makeup': 4.0,
        },
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 5.0, 'freq': 120.0, 'q': 0.707, 'gainDb': 2.0}, // LOWSHELF calidez
      },
      <String, dynamic>{
        'type': 'biquad',
        'params': {'type': 4.0, 'freq': 3500.0, 'q': 1.0, 'gainDb': 4.0}, // PEAK presencia
      },
      <String, dynamic>{
        'type': 'distortion',
        'params': {'drive': 1.8, 'mix': 0.3}, // saturación de cinta sutil
      },
    ],
  },
];

/// Presets integrados, inmutables, en el orden canónico del CONTRACT §5.
/// Es el fallback compilado: la lista efectiva (builtins + overrides del
/// manifest) es la que devuelve [loadVoiceFxPresetsFromJson].
// Tolerante: si un preset builtin no parsea (p.ej. usa un tipo aún no
// implementado), se OMITE con warning en vez de lanzar — un preset malo NO
// debe dejar la app en pantalla en blanco al arrancar (VoiceFxNode.fromJson
// lanza FormatException en tipos desconocidos, y esto corre antes de runApp).
final List<VoiceFxPreset> kVoiceFxPresets = List.unmodifiable(
  _kBuiltinPresetMaps
      .map((m) {
        try {
          return VoiceFxPreset.fromJson(m);
        } catch (e) {
          _warn('preset builtin "${m['id']}" inválido, se omite: $e');
          return null;
        }
      })
      .whereType<VoiceFxPreset>());

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
