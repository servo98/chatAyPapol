# VoiceFX × RNNoise — contrato de integración (merge-time)

Cómo se conecta el motor de efectos de voz de este branch (`feature/voice-fx`,
lib nativa en `client/native/voicefx`) con el fork de `flutter_webrtc` que añade
RNNoise (otro desarrollador). **Nada de este branch toca `voice.dart`, el plugin
ni el path de captura de RNNoise**: el cableado descrito aquí se hace EN EL
MERGE, dentro del fork. La ABI autoritativa es
[`client/native/voicefx/CONTRACT.md`](../native/voicefx/CONTRACT.md) +
[`client/native/voicefx/include/voicefx.h`](../native/voicefx/include/voicefx.h)
(`vfx_abi_version() == 1`).

## 1. Cadena de audio en runtime

```
                       ┌────────────── fork flutter_webrtc (nativo, C++) ──────────────┐
 mic ── ADM/APM ──►  RNNoise (capture post-processing, otro dev) ──►  vfx_process()  ──►  encoder Opus ──► LiveKit
                       └──────────────────────────────────────────────────▲────────────┘
                                                                          │ VfxChain* (mismo proceso)
       Dart (isolate principal): VoiceFxEngine ── FFI (voicefx_bindings) ─┘
                                 crea/posee el chain, empuja presets/params
```

- Frames: **mono float32 [-1,1], 48000 Hz, bloques de ≤480 samples (10 ms)** —
  lo que entrega el pipeline de captura de libwebrtc tras APM. Si el hook
  recibe `int16`, convertir `s / 32768.0f` antes y `* 32768` después.
- VoiceFX va **después** de RNNoise (denoise sobre voz limpia, FX al final) y
  **antes** del encoder.
- Flutter desktop = un solo proceso: el `VfxChain*` que crea Dart por FFI es
  directamente usable desde el C++ del plugin. No hay IPC.

## 2. Quién llama qué

**Propiedad del chain: el lado Dart.** `VoiceFxEngine.init()`
(`client/lib/audio/voice_fx.dart`) usa `VoicefxNative.open()`
(`client/lib/audio/voicefx_bindings.dart`): `DynamicLibrary.open`, valida
`vfx_abi_version() == 1`, llama `vfx_create(48000, 480)` y aplica
presets/params vía `vfx_set_*` (mutaciones seguras concurrentes con
`vfx_process`; ver threading en CONTRACT.md §1). El hook nativo SOLO procesa.

El handoff del puntero es **una** llamada de plataforma (añadir junto al toggle
de RNNoise del fork, p. ej. método `voiceFxAttach` en el mismo channel):

- Al iniciar la pista de mic, Dart manda la dirección del chain (int64) al
  plugin. `VoicefxNative` guarda el `Pointer<VfxChain>` en `_chain`; en el
  merge se añade el getter de 1 línea `int get chainAddress => _chain.address`.
- El hook lo guarda en un `std::atomic<VfxChain*>`.
- Al parar/disponer, Dart manda `voiceFxAttach(0)`, **espera el ack**, y solo
  entonces llama `vfx_destroy` (garantía del contrato: no hay `vfx_process` en
  vuelo al destruir).

### Las líneas que necesita el hook de captura (C++ del fork)

```cpp
#include "voicefx.h"                       // client/native/voicefx/include
std::atomic<VfxChain*> g_vfx{nullptr};     // seteado por voiceFxAttach(address)

// En el mismo callback de post-procesado donde corre RNNoise, DESPUÉS de él:
if (VfxChain* fx = g_vfx.load(std::memory_order_acquire))
  vfx_process(fx, buf, buf, num_frames);   // in-place ok; RT-safe; passthrough si cadena vacía
```

Eso es todo. Sin locks, sin allocs: `vfx_process` cumple el contrato realtime.

**Caveat de sample rate:** el chain se crea a 48 kHz / 480 frames (canónico).
Si el APM del fork entregara otra tasa o bloques mayores, el hook debe saltarse
`vfx_process` (passthrough) y reportarlo; el integrador recrea el chain desde
Dart con `VoiceFxEngine.init(sampleRate:, maxFrames:)`.

**Alternativa sin tocar C++ (solo pruebas/harness):**
`VoiceFxEngine.instance.processFrame(Float32List)` desde Dart. NO es el camino
de producción — el PCM de captura vive en nativo y nunca llega a Dart.

## 3. Build: enganchar la lib en los runners (aplicar EN EL MERGE)

`client/native/voicefx/CMakeLists.txt` es autónomo y produce `voicefx.dll` /
`libvoicefx.so`. **No editamos** `client/windows/**` ni `client/linux/**` en
este branch para no chocar con el fork de RNNoise. Quien mergea añade:

**`client/windows/CMakeLists.txt`** (tras `add_subdirectory("runner")`, línea 53):

```cmake
add_subdirectory("../native/voicefx" "voicefx_build")
add_dependencies(${BINARY_NAME} voicefx)
# No hace falta target_link_libraries: Dart la carga con DynamicLibrary.open.
install(FILES "$<TARGET_FILE:voicefx>" DESTINATION "${CMAKE_INSTALL_PREFIX}"
        COMPONENT Runtime)   # voicefx.dll junto a chatpapol.exe
```

**`client/linux/CMakeLists.txt`** (tras `set(INSTALL_BUNDLE_LIB_DIR ...)`,
línea 92 — el `add_subdirectory` puede ir antes, el `install` necesita la var):

```cmake
add_subdirectory("../native/voicefx" "voicefx_build")
add_dependencies(${BINARY_NAME} voicefx)
install(FILES "$<TARGET_FILE:voicefx>" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
        COMPONENT Runtime)   # libvoicefx.so en bundle/lib/ (mismo dir que los plugins)
```

El loader Dart (`client/lib/audio/voicefx_bindings.dart`) intenta en orden:
nombre pelado (`voicefx.dll`/`libvoicefx.so`), junto a
`Platform.resolvedExecutable`, y `<exe>/lib/`. Si nada carga o la ABI no es 1,
`VoiceFxEngine.available == false` y el cliente funciona igual (no-op seguro).

El fork solo necesita el header:
`target_include_directories(... PRIVATE "<repo>/client/native/voicefx/include")`
en su propio CMake. No linkea contra la lib: recibe el puntero ya creado y los
símbolos viven en la dll/so ya cargada en el proceso (en Windows, si prefiere
linkear directo, usar el import lib que genera `voicefx_build`).

## 4. Cambios en pubspec (los aplica el agente Verify)

En `client/pubspec.yaml` (único archivo compartido que toca este branch):

```yaml
dependencies:
  ffi: ^2.1.0          # ya aplicado en este branch — primer uso de dart:ffi en el repo

flutter:
  assets:
    - assets/voicefx_presets.json   # manifest de presets data-driven (patrón sfx_manifest.json)
```

Si el asset falta del bundle, `loadVoiceFxPresetsFromJson()`
(`client/lib/audio/voice_fx_presets.dart`) cae a los presets builtin sin romper
nada — pero el objetivo es el manifest, para añadir presets sin recompilar.

## 5. Seguridad de merge (superficie de conflicto)

**Archivos NUEVOS de este branch** (cero solape con el fork de RNNoise):

- `client/native/voicefx/` — todo el dir: `include/voicefx.h`, `CONTRACT.md`,
  `CMakeLists.txt`, `src/` (DSP C++: `effects.{hpp,cpp}`, `pitch.{hpp,cpp}`, ...)
- `client/lib/audio/` — todo el dir:
  - `voicefx_bindings.dart` — FFI crudo (`VoicefxNative`, loader, ABI check)
  - `voice_fx.dart` — `VoiceFxEngine` (ChangeNotifier: cadena, presets,
    persistencia SharedPreferences `voicefx.enabled` / `voicefx.state`)
  - `voice_fx_presets.dart` — schema/parseo del manifest + builtins de respaldo
  - `ai_voice_changer.dart` — `AiVoiceChanger` (orquestación de conversión de
    voz IA: proceso externo + dispositivos; sin modelo bundleado)
- `client/assets/voicefx_presets.json` — presets canónicos (CONTRACT.md §5)
- `client/tool/voicefx_harness.dart` — harness CLI (WAV mono 48 kHz in →
  frames de 480 → `processFrame` → WAV out), para validar presets de oído
- `client/docs/voice-fx-integration.md` — este documento
- `client/docs/voice-fx-presets.md`, `client/docs/voice-fx-ai-setup.md` — docs
  de presets y del flujo IA
- `VOICEFX_PLAN.md` — plan del feature (raíz del repo)

**Único archivo compartido tocado:** `client/pubspec.yaml` (dep `ffi` + entrada
de asset, §4; `pubspec.lock` se regenera). Si el fork también toca pubspec
(override git de `flutter_webrtc` → su fork), el conflicto es trivial: ambas
ediciones conviven en secciones distintas.

**Explícitamente NO tocados:** `client/lib/voice.dart`,
`client/windows/**`, `client/linux/**`, `client/macos/**`, el plugin
`flutter_webrtc` y todo el path de captura de RNNoise.
