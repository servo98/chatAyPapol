# VoiceFX — Contrato autoritativo (ABI + presets + API Dart)

**Single source of truth** para el motor de efectos de voz en tiempo real de ChatPapol.
Todo módulo (DSP C++, bindings FFI, engine Dart, presets, harness CLI, integración
flutter_webrtc) se construye contra ESTE documento y contra
[`include/voicefx.h`](include/voicefx.h) (ABI versión **`VOICEFX_ABI_VERSION = 1`**).

Cadena de captura prevista en runtime:

```
mic → RNNoise (fork flutter_webrtc, otro módulo) → VoiceFX (este módulo) → encoder Opus
```

VoiceFX NO toca `voice.dart` ni el plugin. Se integra en merge-time vía el hook de
post-procesado de captura que expone el fork (mismo punto donde vive RNNoise), o vía
`processFrame()` desde el bridge nativo. Este contrato define qué recibe y qué devuelve.

---

## 1. Contrato de frames (procesamiento)

| Propiedad        | Valor |
|------------------|-------|
| Sample rate      | Fijado en `vfx_create(sampleRate, maxFrames)`. **Canónico: 48000 Hz** (lo que entrega libwebrtc tras APM). Si el stream real difiere, el integrador crea el chain a esa tasa. |
| Canales          | **Mono** (1 canal). Estéreo no soportado en v1. |
| Formato          | `float32` PCM, rango nominal `[-1.0, +1.0]`. Si la fuente es `int16`, el integrador convierte (`s / 32768.0f`) antes y después. |
| Tamaño de bloque | `numFrames ≤ maxFrames`. **Canónico: 480 samples = 10 ms @ 48 kHz** (el tamaño de frame del pipeline de captura de webrtc). |
| In-place         | `vfx_process(chain, buf, buf, n)` con `in == out` DEBE funcionar. |
| Realtime-safety  | `vfx_process()` corre en el hilo de audio: **prohibido** malloc/free, locks, syscalls, I/O. Todos los buffers se pre-alocan en `vfx_create()`/`vfx_add()`. |
| Cadena vacía     | Copia `in → out` y aplica la etapa master. |
| Salida           | Soft-clamp a `[-1, +1]` al final de la etapa master. |
| Latencia         | Solo `VFX_PITCH` introduce latencia algorítmica; presupuesto máximo **30 ms**. El resto de efectos: 0 frames de latencia. |

**Etapa master** (después de toda la cadena):
`out = dry·(1 − wetMix) + processed·wetMix`, luego `· outGain`.
`wetMix ∈ [0,1]` default `1.0`; `outGain ∈ [0,4]` lineal, default `1.0`.

### Threading

- `vfx_process()` → hilo de audio (RT).
- Todo lo demás → **un único** hilo de control (isolate principal de Dart).
- `vfx_set_param` / `vfx_set_bypass` / `vfx_set_master`: seguros concurrentes con
  `vfx_process` (atomics + smoothing interno; sin clicks).
- `vfx_add` / `vfx_clear` / `vfx_destroy`: seguros frente a un `vfx_process`
  concurrente (swap lock-free del puntero de cadena), pero NO re-entrantes entre sí.
- En `vfx_destroy` el llamador garantiza que no hay ni habrá más `vfx_process`.

## 2. Resumen de la ABI C

Símbolos exportados por `voicefx.dll` (Windows) / `libvoicefx.so` (Linux).
Firmas exactas y doc por símbolo en `include/voicefx.h`.

```c
int       vfx_abi_version(void);                       // debe == VOICEFX_ABI_VERSION (1)
VfxChain* vfx_create(int sampleRate, int maxFrames);   // NULL si falla
void      vfx_destroy(VfxChain*);
void      vfx_clear(VfxChain*);                        // quita nodos; NO resetea master
int       vfx_add(VfxChain*, int effectType);          // → nodeIndex (0-based) o -1
void      vfx_set_param(VfxChain*, int nodeIndex, int paramId, float value); // clamp; ignora ids inválidos
void      vfx_set_bypass(VfxChain*, int nodeIndex, int bypass);
void      vfx_set_master(VfxChain*, float wetMix, float outGain);
void      vfx_process(VfxChain*, const float* in, float* out, int numFrames); // RT-safe, in==out ok
```

- Máximo **`VFX_MAX_NODES = 16`** nodos por cadena.
- **No hay remove/reorder en la ABI**: el engine Dart reconstruye
  (`vfx_clear` + N×`vfx_add` + params) para esas operaciones. Es barato (< 1 ms)
  y el swap lock-free evita glitches.
- `vfx_set_param` con `paramId` que no pertenece al tipo del nodo: ignorado en
  silencio. Valores fuera de rango: **clampeados**.

### Build / hooking (sin tocar los CMakeLists existentes)

La librería vive en `client/native/voicefx/` con su **propio** `CMakeLists.txt`
(autor: módulo DSP) que produce una shared lib (`voicefx.dll` / `libvoicefx.so`,
C++17 en MSVC, C++14-compatible en GCC). Los runners de `client/windows` y
`client/linux` NO se modifican: el binario se compila aparte y se copia junto al
ejecutable (mismo dir que `app.so`/dll de plugins); Dart lo carga con
`DynamicLibrary.open('voicefx.dll' | 'libvoicefx.so')` con fallback a ruta junto
a `Platform.resolvedExecutable`. La integración con el bundle (script de copia /
hook de packaging) se documenta en el módulo de build, no aquí.

## 3. Tipos de efecto y tabla de parámetros

Valores de enum **estables** (nunca renumerar, solo añadir).
Los `paramId` viven en un namespace global por bloques de 100.

| Efecto (`VfxEffectType`) | valor | nombre JSON | Uso típico |
|---|---|---|---|
| `VFX_REVERB`     | 0 | `reverb`     | cueva / iglesia / sala |
| `VFX_DELAY`      | 1 | `delay`      | eco |
| `VFX_BIQUAD`     | 2 | `biquad`     | radio / teléfono / megáfono (LP/HP/BP/notch) |
| `VFX_RINGMOD`    | 3 | `ringmod`    | robot |
| `VFX_DISTORTION` | 4 | `distortion` | megáfono / demonio |
| `VFX_PITCH`      | 5 | `pitch`      | personajes / género (pitch + formante) |
| `VFX_NOISE`      | 6 | `noise`      | siseo de radio / cama de ambiente |
| `VFX_TREMOLO`    | 7 | `tremolo`    | voz de anciano |
| `VFX_CHORUS`     | 8 | `chorus`     | sci-fi |

### Tabla de parámetros (autoritativa)

| Efecto | `VfxParamId` | id | clave JSON | Rango | Default | Unidad / semántica |
|---|---|---|---|---|---|---|
| reverb | `VFX_P_REVERB_ROOMSIZE` | 100 | `roomsize` | 0.0–1.0 | 0.50 | tamaño normalizado (1.0 ≈ catedral/cueva) |
| reverb | `VFX_P_REVERB_DAMP`     | 101 | `damp`     | 0.0–1.0 | 0.50 | amortiguación de agudos en la cola (1 = más oscura) |
| reverb | `VFX_P_REVERB_WET`      | 102 | `wet`      | 0.0–1.0 | 0.33 | nivel wet vs dry |
| delay  | `VFX_P_DELAY_TIME_MS`   | 200 | `timeMs`   | 1.0–2000.0 | 350.0 | ms de retardo |
| delay  | `VFX_P_DELAY_FEEDBACK`  | 201 | `feedback` | 0.0–0.95 | 0.35 | ganancia de realimentación |
| delay  | `VFX_P_DELAY_MIX`       | 202 | `mix`      | 0.0–1.0 | 0.50 | mezcla wet |
| biquad | `VFX_P_BIQUAD_TYPE`     | 300 | `type`     | 0,1,2,3 | 0 | `VfxBiquadType`: 0=LP, 1=HP, 2=BP, 3=NOTCH |
| biquad | `VFX_P_BIQUAD_FREQ`     | 301 | `freq`     | 20.0–20000.0 | 1000.0 | Hz (corte/centro) |
| biquad | `VFX_P_BIQUAD_Q`        | 302 | `q`        | 0.1–10.0 | 0.707 | resonancia |
| ringmod | `VFX_P_RINGMOD_FREQ`   | 400 | `freq`     | 1.0–2000.0 | 30.0 | Hz de la portadora seno |
| ringmod | `VFX_P_RINGMOD_MIX`    | 401 | `mix`      | 0.0–1.0 | 1.0 | mezcla wet |
| distortion | `VFX_P_DIST_DRIVE`  | 500 | `drive`    | 1.0–50.0 | 8.0 | pre-ganancia lineal a tanh() |
| distortion | `VFX_P_DIST_MIX`    | 501 | `mix`      | 0.0–1.0 | 1.0 | mezcla wet |
| pitch  | `VFX_P_PITCH_SEMITONES` | 600 | `semitones`| −12.0–+12.0 | 0.0 | semitonos |
| pitch  | `VFX_P_PITCH_FORMANT`   | 601 | `formant`  | 0.5–2.0 | 1.0 | ratio de formantes (<1 voz "grande", >1 voz "pequeña") |
| noise  | `VFX_P_NOISE_LEVEL`     | 700 | `level`    | 0.0–1.0 | 0.05 | amplitud lineal añadida |
| noise  | `VFX_P_NOISE_COLOR`     | 701 | `color`    | 0.0–1.0 | 0.50 | tilt espectral: 0=blanco, 1=oscuro (pink/brown) |
| tremolo | `VFX_P_TREMOLO_RATE`   | 800 | `rate`     | 0.1–20.0 | 5.0 | Hz del LFO |
| tremolo | `VFX_P_TREMOLO_DEPTH`  | 801 | `depth`    | 0.0–1.0 | 0.5 | profundidad (1 = gating total) |
| chorus | `VFX_P_CHORUS_RATE`     | 900 | `rate`     | 0.05–5.0 | 0.8 | Hz del LFO |
| chorus | `VFX_P_CHORUS_DEPTH`    | 901 | `depth`    | 0.0–1.0 | 0.4 | profundidad normalizada (0–~8 ms de barrido) |
| chorus | `VFX_P_CHORUS_MIX`      | 902 | `mix`      | 0.0–1.0 | 0.5 | mezcla wet |

Master (no es un nodo): `wetMix` 0–1 default 1.0; `outGain` 0–4 lineal default 1.0.

## 4. Schema JSON de presets (data-driven)

Espeja el patrón de `assets/sfx_manifest.json` (asset horneado + overrides en
SharedPreferences). Archivo: **`assets/voicefx_presets.json`**, cargado con
`rootBundle.loadString`. Añadir un preset = editar JSON, **sin recompilar**.

```jsonc
{
  "version": 1,
  "presets": [
    {
      "id": "cueva",              // estable, snake_case, clave de persistencia
      "label": "Cueva",           // etiqueta humana en español (la UI la muestra tal cual)
      "category": "room",         // "room" | "character" | "gender"
      "master": { "wetMix": 1.0, "outGain": 1.0 },   // opcional; defaults 1.0/1.0
      "chain": [                  // orden del array == orden de procesado
        {
          "type": "reverb",       // nombre JSON del efecto (tabla §3)
          "bypass": false,        // opcional, default false
          "params": { "roomsize": 0.92, "damp": 0.25, "wet": 0.55 }  // claves JSON de §3; omitidas → default
        }
      ]
    }
  ]
}
```

Reglas de parseo (engine Dart):
- `type` desconocido → se descarta el preset entero con warning (forward-compat).
- Param desconocido para ese `type` → se ignora ese param.
- Valores fuera de rango → clamp (igual que la ABI).
- Máx. `VFX_MAX_NODES = 16` nodos; extras se ignoran con warning.

## 5. Presets canónicos (v1)

Estos valores exactos van en `assets/voicefx_presets.json`. `master` omitido =
`{wetMix: 1.0, outGain: 1.0}` salvo que se indique.

### Salas / ambiente (`category: "room"`)

| id | label | cadena (en orden) |
|---|---|---|
| `cueva` | Cueva | reverb(roomsize 0.92, damp 0.25, wet 0.55) → delay(timeMs 180, feedback 0.45, mix 0.30) |
| `iglesia` | Iglesia | reverb(roomsize 0.85, damp 0.60, wet 0.45) |
| `sala` | Sala pequeña | reverb(roomsize 0.25, damp 0.70, wet 0.22) |
| `eco` | Eco | delay(timeMs 400, feedback 0.50, mix 0.45) |
| `radio` | Radio / Walkie | biquad(type 1 HP, freq 400, q 0.9) → biquad(type 0 LP, freq 3000, q 0.9) → distortion(drive 4, mix 0.6) → noise(level 0.03, color 0.2) |
| `telefono` | Teléfono | biquad(type 1 HP, freq 300, q 0.707) → biquad(type 0 LP, freq 3400, q 0.707) |
| `megafono` | Megáfono | biquad(type 1 HP, freq 500, q 0.8) → biquad(type 0 LP, freq 4000, q 0.8) → distortion(drive 12, mix 0.85) |
| `robot` | Robot | ringmod(freq 35, mix 0.8) → delay(timeMs 50, feedback 0.40, mix 0.30) |
| `scifi` | Sci-Fi | chorus(rate 0.6, depth 0.7, mix 0.6) → ringmod(freq 200, mix 0.2) → reverb(roomsize 0.5, damp 0.5, wet 0.25) |

### Personajes (`category: "character"`)

| id | label | cadena (en orden) |
|---|---|---|
| `troll` | Trol | pitch(semitones −8.0, formant 0.78) → distortion(drive 5, mix 0.35) → reverb(roomsize 0.90, damp 0.30, wet 0.40) |
| `demonio` | Demonio | pitch(semitones −6.0, formant 0.80) → distortion(drive 9, mix 0.50) → reverb(roomsize 0.80, damp 0.40, wet 0.35) |
| `viejo` | Anciano | pitch(semitones −1.5, formant 0.92) → tremolo(rate 6.5, depth 0.35) → biquad(type 0 LP, freq 4000, q 0.707) |
| `ardilla` | Ardilla | pitch(semitones +10.0, formant 1.30) |
| `nino` | Niño | pitch(semitones +4.0, formant 1.20) |

### Género (`category: "gender"`)

| id | label | cadena |
|---|---|---|
| `hombre_a_mujer` | Hombre → Mujer | pitch(semitones +4.0, formant 1.20) |
| `mujer_a_hombre` | Mujer → Hombre | pitch(semitones −5.0, formant 0.85) |

(El estado "sin efecto" no es un preset: es el engine deshabilitado o cadena vacía;
`activePresetId == null`.)

## 6. API pública Dart (especificación — implementa el módulo engine/FFI)

Archivos previstos: `client/lib/voicefx/voicefx_engine.dart` (engine + modelos) y
`client/lib/voicefx/voicefx_bindings.dart` (FFI crudo, privado del paquete).
Sin widgets. `ChangeNotifier`-style para que la UI (diseñador, fase posterior)
solo observe.

```dart
/// Tipos de efecto, espejo 1:1 de VfxEffectType (mismo orden => mismo .index).
enum VfxEffectType { reverb, delay, biquad, ringmod, distortion, pitch, noise, tremolo, chorus }

/// Un nodo de la cadena: tipo + params (claves JSON de la tabla §3) + bypass.
class VoiceFxNode {
  VoiceFxNode(this.type, {Map<String, double>? params, this.bypass = false});
  final VfxEffectType type;
  final Map<String, double> params; // mutar SOLO vía VoiceFxEngine.setParam
  bool bypass;

  factory VoiceFxNode.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();
}

/// Preset inmutable cargado del manifest JSON.
class VoiceFxPreset {
  final String id;            // p.ej. 'cueva'
  final String label;         // etiqueta es, p.ej. 'Cueva'
  final String category;      // 'room' | 'character' | 'gender'
  final double wetMix;        // master, default 1.0
  final double outGain;       // master, default 1.0
  final List<VoiceFxNode> chain;

  factory VoiceFxPreset.fromJson(Map<String, dynamic> json);
  Map<String, dynamic> toJson();
}

/// Motor singleton. Posee el VfxChain* nativo y la cadena espejo en Dart.
/// Cada mutación: aplica al nativo, actualiza el espejo, notifyListeners(),
/// y agenda persistencia (debounced) a SharedPreferences.
class VoiceFxEngine extends ChangeNotifier {
  static final VoiceFxEngine instance = VoiceFxEngine._();

  /// Carga la dynlib (voicefx.dll / libvoicefx.so), valida vfx_abi_version(),
  /// crea el chain (48000, 480), carga assets/voicefx_presets.json y restaura
  /// el estado persistido. Idempotente. Si la lib no está: `available == false`
  /// y todo lo demás es no-op seguro (el cliente sigue funcionando sin FX).
  Future<void> init({int sampleRate = 48000, int maxFrames = 480});

  /// false si la dynlib no cargó o la ABI no coincide.
  bool get available;

  /// Encendido global. Apagado => vfx_process es passthrough puro (la cadena
  /// se conserva). Persistido.
  bool get enabled;
  Future<void> setEnabled(bool v);

  /// Cadena actual (vista de solo lectura, orden == orden de procesado).
  List<VoiceFxNode> get nodes;

  /// Master.
  double get wetMix;
  double get outGain;
  void setMaster({double? wetMix, double? outGain});

  /// Edición de cadena. remove/reorder reconstruyen el chain nativo
  /// (vfx_clear + vfx_add* + params) — ver §2. Cualquier edición manual pone
  /// activePresetId = null. Devuelve el índice del nodo nuevo, o -1 si lleno.
  int addEffect(VfxEffectType type);
  void removeEffect(int index);
  void reorderEffect(int from, int to);
  void clearChain();

  /// `param` usa las claves JSON de §3 (p.ej. 'roomsize', 'timeMs'). Clamp al
  /// rango documentado antes de llegar al nativo.
  void setParam(int index, String param, double value);
  void setBypass(int index, bool bypass);

  /// Presets del manifest (inmutables, en orden del JSON).
  List<VoiceFxPreset> get presets;

  /// null si la cadena fue editada a mano o está vacía.
  String? get activePresetId;

  /// Reemplaza la cadena + master por los del preset. Lanza ArgumentError si
  /// el id no existe. Persiste.
  Future<void> loadPreset(String id);

  /// Punto de entrada de audio: lo llama el bridge de integración (o el
  /// harness CLI) con un frame mono float32. In-place. RT-safe del lado
  /// nativo; en Dart NO alocar aquí. No-op si !available o !enabled.
  void processFrame(Float32List inOut);

  /// Libera el chain nativo. Tras dispose() el singleton puede re-init().
  @override
  Future<void> dispose();
}
```

### Persistencia (SharedPreferences, patrón de sfx.dart)

| Clave | Tipo | Contenido |
|---|---|---|
| `voicefx.enabled` | bool | encendido global (default `false`) |
| `voicefx.state` | String (JSON) | `{ "version": 1, "activePresetId": "cueva"\|null, "master": {"wetMix":1.0,"outGain":1.0}, "chain": [VoiceFxNode.toJson()...] }` |

Restauración en `init()`: si `voicefx.state` parsea, reconstruir cadena + master +
`activePresetId`; si no, cadena vacía. Escritura debounced (~300 ms) tras cada mutación.

### Reglas de consistencia entre módulos

1. El orden del enum Dart `VfxEffectType` ES el valor C (`.index` == valor ABI). No reordenar jamás.
2. El mapeo clave-JSON → `VfxParamId` vive en una única tabla del módulo bindings, copiada literal de §3.
3. El harness CLI (`client/tool/voicefx_harness.dart` o similar) usa exactamente esta API: lee WAV mono 48 kHz, trocea en frames de 480, `processFrame`, escribe WAV. Sirve para validar presets de oído.
4. La integración final (merge con el fork RNNoise) solo necesita: crear el engine, y llamar `processFrame` (o el equivalente nativo `vfx_process` desde C++ si el hook vive en el plugin) DESPUÉS de RNNoise y ANTES del encoder.
