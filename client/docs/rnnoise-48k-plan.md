# RNNoise espectral real en el path fullband 48k — plan

## Problema
El micro de un usuario mete **mucho ruido cuando habla** (en silencio limpio).
Causa: un *noise gate* solo silencia bajo el umbral; al hablar abre y deja pasar
voz+ruido. Lo que limpia **durante** el habla es supresión espectral (RNNoise).

En ChatPapol hay dos rutas de captura:

- **16k (APM)**: el toggle "RNNoise (IA)" corre RNNoise real
  (`rnnoise_processor.cc` → `Process()` → `engines_[c]->ProcessInPlace`).
  ✅ Ya **ON por defecto** (commit en `voice.dart`).
- **fullband 48k (kCustom, sin APM)**: el toggle "RNNoise (IA)" **NO** corre
  RNNoise; corre un **gate adaptativo** (`ProcessCustom48`, ~líneas 216-255 del
  fork), porque "RNNoise a 48k fullband agacha la voz". → ruido al hablar **por
  diseño**.

## Mitigación inmediata (ya disponible, sin build)
- En modo fullband 48k: **apagar** "Micro fullband 48 kHz" + **encender**
  "RNNoise (IA)" → cae al path 16k con supresión espectral real.
- RNNoise ya viene ON de fábrica para el path 16k.

## Fix de fondo (este plan) — requiere build nativo Windows
Correr RNNoise **de verdad** en el path 48k sin agachar la voz.

RNNoise es nativamente 48 kHz (frames de 480 muestras), así que NO hace falta
resamplear: se puede alimentar el frame de 48k directo al `RnnoiseEngine`.

### Cambios
1. **Fork** `github.com/servo98/flutter-webrtc` (ref actual en
   `client/pubspec.yaml`: `ef70bf3...`):
   - `common/cpp/src/rnnoise_processor.cc` → `ProcessCustom48`:
     - Detrás de un flag NUEVO e independiente del gate (p.ej.
       `spectral_on_`), correr `engines_[c]->ProcessInPlace(frame480)` sobre el
       bloque de 480 muestras a 48k, ANTES (o en vez) del gate.
     - Mantener el gate actual como opción aparte (el "agache" reportado
       sugiere mezclar wet/dry o aplicar make-up gain; exponer un mix 0..1 para
       ear-QC en vez de 100% wet).
   - Exponer el flag por el method channel ya existente (paralelo a
     `setRnnoise`), p.ej. `setSpectral48(bool)`.
2. **Cliente**:
   - `webrtc_apm.dart`: método `setSpectral48`.
   - `voice.dart`: pref + aplicar al publicar el micro 48k.
   - `settings.dart` (pestaña Voz): sub-toggle "Supresión durante el habla
     (48k)" + nota de que en 48k el "RNNoise (IA)" clásico actúa como gate.
3. **pubspec.yaml**: bumpear `flutter_webrtc.ref` al nuevo commit del fork.

### Build / verificación (memoria: build-windows-wsl-trampas, flujo-releases)
- `flutter clean` (cambió webrtc) + build con **flutter.bat de Windows**.
- `client/scripts/publish-windows.sh <ver>` (build+firma+sube).
- **Ear-QC con el hermano**: ventilador/teclado de fondo; confirmar que el
  ruido al hablar baja SIN que la voz se agache. Ajustar el mix wet/dry.

### Riesgos
- C++ no verificable sin toolchain Windows → no hacer a ciegas.
- El "agache de voz" que motivó el gate puede reaparecer; por eso el mix wet/dry.
- RNNoise añade CPU/latencia; aceptable en la mayoría de equipos.
