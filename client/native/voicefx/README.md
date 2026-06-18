# voicefx — motor nativo de efectos de voz (ChatPapol)

Librería C++17 sin dependencias que implementa la ABI de
[`include/voicefx.h`](include/voicefx.h) (v1). Contrato completo (frames,
threading, presets, API Dart): [`CONTRACT.md`](CONTRACT.md).

Posición en runtime: `mic → RNNoise (fork flutter_webrtc) → voicefx → encoder`.
Bloques mono float32 de 10 ms (480 samples @ 48 kHz), `vfx_process` es
realtime-safe (cero allocs/locks/syscalls; denormals flusheados vía FTZ/DAZ).

## Layout

```
include/voicefx.h   ABI C pública (estable, versionada)
src/voicefx.cpp     VfxChain + dispatch + master + swap lock-free de cadena
src/effects.{hpp,cpp}  primitivas DSP (reverb, delay, biquad, ringmod,
                       distortion, noise, tremolo, chorus)
src/pitch.{hpp,cpp} pitch shifter (phase vocoder) con formante independiente
                    (latencia fija: 768 samples = 16 ms @ 48 kHz, < 30 ms)
src/voicefx_cli.cpp harness de prueba standalone (WAV in/out)
```

## Build

### Linux (también WSL)

```bash
cd client/native/voicefx
cmake -B build
cmake --build build -j
# -> build/libvoicefx.so  +  build/voicefx_cli
```

### Windows (MSVC)

```powershell
cd client\native\voicefx
cmake -B build -G "Visual Studio 17 2022"
cmake --build build --config Release
# -> build\Release\voicefx.dll  +  build\Release\voicefx_cli.exe
```

## Probar sin la app (CLI)

```bash
./build/voicefx_cli --list                              # presets y params
./build/voicefx_cli --preset cueva                      # sweep generado
./build/voicefx_cli --preset robot --in voz.wav --out robot.wav
./build/voicefx_cli --fx reverb:roomsize=0.9,wet=0.5 --fx delay:timeMs=200 \
    --in voz.wav --out test.wav
```

Sin `--in` genera un sweep de 3 s @ 48 kHz (+1 s de cola para oír las colas de
reverb/delay). Acepta WAV PCM 16-bit o float32, mono/estéreo (se mezcla a mono).
La CLI valida `vfx_abi_version()`, procesa en bloques de 10 ms in-place (igual
que el hook de captura) y aborta si detecta NaN o salida fuera de rango.

## Integración con el cliente Flutter (merge-time, NO hecha aquí)

**No se modifican** los CMakeLists de `client/windows` ni `client/linux`. La
lib se compila aparte con este proyecto y el binario se copia junto al
ejecutable; Dart la carga con `DynamicLibrary.open(...)` (con fallback a la
ruta de `Platform.resolvedExecutable`) y valida `vfx_abi_version() == 1`.

Si más adelante se prefiere integrarla al build del runner, las líneas exactas
(documentadas aquí, **no aplicadas**) serían:

```cmake
# client/linux/CMakeLists.txt — después de add_subdirectory(flutter):
add_subdirectory(../native/voicefx voicefx_build)
# y añadir $<TARGET_FILE:voicefx> a la lista de bundle/install, p. ej.:
install(FILES $<TARGET_FILE:voicefx> DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
        COMPONENT Runtime)
```

```cmake
# client/windows/CMakeLists.txt — ídem:
add_subdirectory(../native/voicefx voicefx_build)
install(FILES $<TARGET_FILE:voicefx> DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/.."
        COMPONENT Runtime)
```

Mientras tanto, para desarrollo basta copiar `libvoicefx.so` / `voicefx.dll` al
directorio del ejecutable (`build/linux/x64/*/bundle/lib/` o
`build/windows/x64/runner/Release/`).

## Notas DSP

- **Reverb**: Freeverb mono (8 combs lowpass-feedback + 4 allpasses), tunings
  clásicos escalados al sample rate real.
- **Pitch**: phase vocoder (FFT 1024, hop 256) con envolvente espectral por
  liftering cepstral; la excitación blanqueada se desplaza en pitch y se
  recolorea con la envolvente warpeada → pitch y formante independientes.
  Calidad "compacta": Signalsmith Stretch (MIT) o Rubber Band pueden
  sustituirlo detrás de la misma interfaz sin tocar la ABI.
- **Parámetros**: targets atómicos + smoothing por bloque (sin zipper noise);
  el tiempo de delay hace glide tipo cinta.
- **Bypass**: el nodo bypasseado sigue procesando una copia descartable para
  mantener su estado caliente (sin click al reactivar).
- **Swap de cadena**: `vfx_add`/`vfx_clear` publican un snapshot inmutable por
  puntero atómico; el hilo de audio nunca bloquea (el de control espera).
